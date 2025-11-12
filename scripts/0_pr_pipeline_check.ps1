# Bitbucket Server/DC "pipeline" readiness check
# Flags [BLOCKER] for:
# - OPEN PRs
# - INPROGRESS builds on latest default-branch commit
# - Archived repo
# - Missing default branch / latest commit
# Outputs: bbs_pipeline_validation_output-<timestamp>.csv

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "repos.csv",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ""
)

$ErrorActionPreference = 'Stop'

# ---- Output path ----
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputCsvPath = "bbs_pipeline_validation_output-$timestamp.csv"
} else {
    $outputCsvPath = $OutputPath
}

# ---- Read CSV & validate header ----
if (-not (Test-Path -Path $CsvPath)) { Write-Host "[ERROR] CSV not found: $CsvPath" -ForegroundColor Red; exit 1 }
$rows = Import-Csv -Path $CsvPath
if ($rows.Count -eq 0) { Write-Host "[ERROR] CSV is empty: $CsvPath" -ForegroundColor Red; exit 1 }

$required = @(
 'project-key','project-name','repo','url',
 'last-commit-date','repo-size-in-bytes','attachments-size-in-bytes',
 'is-archived','pr-count','github_org','github_repo','gh_repo_visibility'
)
$missing = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) {
    Write-Host "[ERROR] Missing columns in CSV: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "[ERROR] Required columns: $($required -join ', ')" -ForegroundColor Red
    exit 1
}

# ---- Bitbucket auth & base URL ----
$baseUrl = $env:BBS_BASE_URL
if (-not $baseUrl) { Write-Host "[ERROR] BBS_BASE_URL env var is required." -ForegroundColor Red; exit 1 }
$baseUrl = $baseUrl.TrimEnd('/')

function Get-AuthHeaders {
    $h = @{}
    if ($env:BBS_PAT) {
        $h["Authorization"] = "Bearer $($env:BBS_PAT)"
        return $h
    } elseif ($env:BBS_USERNAME -and $env:BBS_PASSWORD) {
        $pair = "$($env:BBS_USERNAME):$($env:BBS_PASSWORD)"
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        $h["Authorization"] = "Basic $basic"
        return $h
    } else {
        throw "No Bitbucket credentials provided. Set BBS_PAT or BBS_USERNAME + BBS_PASSWORD."
    }
}
$headers = Get-AuthHeaders

# ---- REST helpers ----
function Invoke-BbsGet { param([string]$Url) ; Invoke-RestMethod -Method Get -Uri $Url -Headers $headers }
function Invoke-BbsGetPaged {
    param([string]$Url)
    $all = @()
    $start = 0
    do {
        $pagedUrl = if ($Url.Contains('?')) { "$Url&start=$start" } else { "$Url?start=$start" }
        $resp = Invoke-BbsGet -Url $pagedUrl
        if ($resp.values) { $all += $resp.values }
        $isLast = $resp.isLastPage
        $start  = $resp.nextPageStart
    } while (-not $isLast)
    return $all
}

# ---- Domain helpers ----
function Get-DefaultBranch {
    param([string]$ProjectKey, [string]$RepoSlug)
    try {
        $b = Invoke-BbsGet -Url "$baseUrl/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/branches/default"
        if ($b.id -or $b.displayId) { return $b }
    } catch { }
    $branches = Invoke-BbsGetPaged -Url "$baseUrl/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/branches?limit=100"
    $default = $branches | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
    return $default
}
function Get-LatestCommitOnBranch {
    param([string]$ProjectKey, [string]$RepoSlug, [string]$BranchDisplayId)
    $q = if ($BranchDisplayId) { "?limit=1&until=$BranchDisplayId" } else { "?limit=1" }
    $resp = Invoke-BbsGet -Url "$baseUrl/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/commits$q"
    return $resp.values[0]?.id
}
function Get-BuildStatuses {
    param([string]$ProjectKey, [string]$RepoSlug, [string]$CommitId)
    # Preferred repo-scoped builds resource
    try {
        $resp = Invoke-BbsGet -Url "$baseUrl/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/commits/$CommitId/builds"
        if ($resp.values) { return $resp.values }
    } catch { }
    # Fallback (deprecated global)
    try {
        $resp2 = Invoke-BbsGet -Url "$baseUrl/rest/build-status/latest/commits/$CommitId"
        if ($resp2.values) { return $resp2.values }
    } catch { }
    return @()
}
function Get-OpenPrCount {
    param([string]$ProjectKey, [string]$RepoSlug)
    $prs = Invoke-BbsGetPaged -Url "$baseUrl/rest/api/1.0/projects/$ProjectKey/repos/$RepoSlug/pull-requests?state=OPEN&limit=100"
    return ($prs | Measure-Object).Count
}

# ---- Processing ----
$results = New-Object System.Collections.Generic.List[object]
$blockerRepos = 0

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Checking PRs & Build Status (Pipeline proxy)      " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

foreach ($row in $rows) {
    $projKey   = $row.'project-key'
    $repoSlug  = $row.'repo'
    $archived  = [string]$row.'is-archived'
    $archivedB = ($archived -and $archived.Trim().ToLower() -eq 'true')

    # Default branch + latest commit
    $defaultBranch = Get-DefaultBranch -ProjectKey $projKey -RepoSlug $repoSlug
    $defaultBranchDisplayId = $defaultBranch?.displayId
    if (-not $defaultBranchDisplayId -and $defaultBranch?.id -like 'refs/heads/*') {
        $defaultBranchDisplayId = $defaultBranch.id.Substring(11)
    }
    $latestCommitId = $null
    if ($defaultBranchDisplayId) {
        $latestCommitId = Get-LatestCommitOnBranch -ProjectKey $projKey -RepoSlug $repoSlug -BranchDisplayId $defaultBranchDisplayId
    }

    # Build statuses on latest commit
    $statuses = if ($latestCommitId) { Get-BuildStatuses -ProjectKey $projKey -RepoSlug $repoSlug -CommitId $latestCommitId } else { @() }

    $stateCounts = @{ INPROGRESS=0; SUCCESSFUL=0; FAILED=0; CANCELLED=0; UNKNOWN=0 }
    foreach ($s in $statuses) {
        $st = ($s.state ?? 'UNKNOWN').ToUpper()
        if (-not $stateCounts.ContainsKey($st)) { $stateCounts.UNKNOWN++ } else { $stateCounts[$st]++ }
    }

    # Open PRs
    $openPrs = Get-OpenPrCount -ProjectKey $projKey -RepoSlug $repoSlug

    # Blockers
    $blockers = @()
    if ($archivedB) { $blockers += 'ARCHIVED_REPO' }
    if ($stateCounts.INPROGRESS -gt 0) { $blockers += 'RUNNING_BUILDS' }
    if ($openPrs -gt 0) { $blockers += 'OPEN_PRS' }
    if (-not $defaultBranchDisplayId) { $blockers += 'NO_DEFAULT_BRANCH' }
    if (-not $latestCommitId) { $blockers += 'NO_LATEST_COMMIT' }

    if ($blockers.Count -gt 0) {
        $blockerRepos++
        Write-Host ("[BLOCKER] {0}/{1} | PRs(Open): {2} | Builds(InProg/Fail/Succ): {3}/{4}/{5} | Blockers: {6}" -f `
          $projKey, $repoSlug, $openPrs, $stateCounts.INPROGRESS, $stateCounts.FAILED, $stateCounts.SUCCESSFUL, ($blockers -join ',')) -ForegroundColor Red
    } else {
        Write-Host ("[OK] {0}/{1} | PRs(Open): {2} | Builds(InProg/Fail/Succ): {3}/{4}/{5}" -f `
          $projKey, $repoSlug, $openPrs, $stateCounts.INPROGRESS, $stateCounts.FAILED, $stateCounts.SUCCESSFUL) -ForegroundColor Green
    }

    # Output row (preserve GitHub mapping columns)
    $results.Add([PSCustomObject]@{
        project_key            = $projKey
        project_name           = $row.'project-name'
        repo_slug              = $repoSlug
        url                    = $row.'url'
        github_org             = $row.'github_org'
        github_repo            = $row.'github_repo'
        gh_repo_visibility     = $row.'gh_repo_visibility'
        default_branch         = $defaultBranchDisplayId
        latest_commit_id       = $latestCommitId
        build_inprogress_count = $stateCounts.INPROGRESS
        build_success_count    = $stateCounts.SUCCESSFUL
        build_failed_count     = $stateCounts.FAILED
        build_cancelled_count  = $stateCounts.CANCELLED
        open_pr_count          = $openPrs
        is_archived            = $archivedB
        blockers               = ($blockers -join ';')
    })
}

# ---- Output CSV ----
$results | Export-Csv -Path $outputCsvPath -NoTypeInformation
Write-Host "[INFO] Wrote precheck CSV: $outputCsvPath" -ForegroundColor Cyan

# ---- Summary ----
$runningBuildsRepos = ($results | Where-Object { $_.build_inprogress_count -gt 0 } | Measure-Object).Count
$reposWithOpenPRs   = ($results | Where-Object { $_.open_pr_count -gt 0 } | Measure-Object).Count
$openPrsTotal       = ($results | Measure-Object -Property open_pr_count -Sum).Sum

Write-Host "`n[SUMMARY] Total repos: $($rows.Count)" -ForegroundColor Green
Write-Host ("Repos with RUNNING builds: {0}" -f $runningBuildsRepos) -ForegroundColor Green
Write-Host ("Repos with OPEN PRs:       {0} (total open PRs: {1})" -f $reposWithOpenPRs, $openPrsTotal) -ForegroundColor Green
Write-Host ("Repos with BLOCKERS:       {0}" -f $blockerRepos) -ForegroundColor Green
