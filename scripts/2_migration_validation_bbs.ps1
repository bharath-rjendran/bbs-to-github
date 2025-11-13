# BBS → GH Migration Validation
# - Reads repos from CSV (expects the header you provided).
# - Compares branches (names & counts) and commits (counts & latest SHA) between Bitbucket Server/DC and GitHub.
# - Auth:
#     * Bitbucket: Bearer token (BBS_TOKEN) OR Basic (BBS_USERNAME + BBS_PASSWORD, set BBS_AUTH_TYPE=Basic).
#       Modern Bitbucket DC supports HTTP access tokens with Bearer. Older versions support Personal Access Tokens with Bearer
#       or Basic depending on version and configuration.  [5](https://confluence.atlassian.com/bitbucketserver/http-access-tokens-939515499.html)[6](https://confluence.atlassian.com/bitbucketserver076/personal-access-tokens-1026534797.html)
#     * GitHub: GH_PAT (also exposed as GH_TOKEN for gh cli).
# - Logging: writes validation-log-YYYYMMDD.txt and per-repo JSON for GH repo info.

[CmdletBinding()]
param(
  [string]$CsvPath = "repos.csv"
)

Add-Type -AssemblyName System.Web

$LOG_FILE = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

function Get-BbsHeaders {
  # Decide between Bearer and Basic auth
  if ($env:BBS_AUTH_TYPE -and $env:BBS_AUTH_TYPE.Trim().ToLower() -eq 'basic') {
    if (-not $env:BBS_USERNAME -or -not $env:BBS_PASSWORD) {
      throw "BBS_AUTH_TYPE=Basic requires BBS_USERNAME and BBS_PASSWORD."
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes("$($env:BBS_USERNAME):$($env:BBS_PASSWORD)")
    $basic = [Convert]::ToBase64String($bytes)
    return @{ Authorization = "Basic $basic" }
  }

  if ($env:BBS_TOKEN) {
    # Default to Bearer when a token is provided (recommended for DC HTTP access tokens)
    return @{ Authorization = "Bearer $($env:BBS_TOKEN)" }
  }

  throw "Provide Bitbucket credentials via BBS_TOKEN (preferred) or set BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD."
}

function Get-BbsBaseUrl([string]$repoUrl) {
  # Strip path beyond /projects/... to get the Bitbucket base URL
  return ($repoUrl -replace '(?i)/projects/.*$','')
}

function Get-BbsBranches([string]$baseUrl, [string]$projectKey, [string]$repoSlug, [hashtable]$headers) {
  $branches = @()
  $start = 0
  do {
    $endpoint = "$baseUrl/rest/api/1.0/projects/$projectKey/repos/$repoSlug/branches?limit=500&start=$start"
    $resp = Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Get
    $branches += ($resp.values | ForEach-Object { $_.displayId })
    $isLast = $resp.isLastPage
    $start  = $resp.nextPageStart
  } while (-not $isLast)
  return $branches
  # Bitbucket DC paged APIs use isLastPage/nextPageStart and expose branch displayId. [4](https://developer.atlassian.com/server/bitbucket/how-tos/command-line-rest/)
}

function Get-BbsCommitsInfo([string]$baseUrl, [string]$projectKey, [string]$repoSlug, [string]$branch, [hashtable]$headers) {
  $total = 0
  $latest = ""
  $start = 0
  $limit = 1000
  do {
    $encBranch = [System.Web.HttpUtility]::UrlEncode($branch)
    $endpoint = "$baseUrl/rest/api/1.0/projects/$projectKey/repos/$repoSlug/commits?until=$encBranch&limit=$limit&start=$start"
    $resp = Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Get
    if (-not $latest -and $resp.values.Count -gt 0) {
      # First element of first page is newest
      $latest = $resp.values[0].id
    }
    $total += $resp.values.Count
    $isLast = $resp.isLastPage
    $start  = $resp.nextPageStart
  } while (-not $isLast)
  return [pscustomobject]@{ Count = $total; Latest = $latest }
  # Official examples show /commits?until=<branch> with paging metadata. [4](https://developer.atlassian.com/server/bitbucket/how-tos/command-line-rest/)
}

function Get-GhBranches([string]$org, [string]$repo) {
  $json = gh api "/repos/$org/$repo/branches" --paginate | ConvertFrom-Json
  return $json | ForEach-Object { $_.name }
  # gh api --paginate follows Link headers for all pages. [7](https://cli.github.com/manual/gh_api)[8](https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api)
}

function Get-GhCommitsInfo([string]$org, [string]$repo, [string]$branch) {
  $total = 0
  $latest = ""
  $page = 1
  $perPage = 100
  do {
    $encBranch = [System.Web.HttpUtility]::UrlEncode($branch)
    $chunk = gh api "/repos/$org/$repo/commits?sha=$encBranch&page=$page&per_page=$perPage" | ConvertFrom-Json
    if ($page -eq 1 -and $chunk.Count -gt 0) {
      $latest = $chunk[0].sha
    }
    $total += $chunk.Count
    $page++
  } while ($chunk.Count -eq $perPage)
  return [pscustomobject]@{ Count = $total; Latest = $latest }
}

function Validate-Migration {
  param(
    [string]$bbsProjectKey,
    [string]$bbsRepoSlug,
    [string]$bbsRepoUrl,
    [string]$githubOrg,
    [string]$githubRepo
  )

  Write-Output "[$(Get-Date)] Validating migration: $githubOrg/$githubRepo  (BBS: $bbsProjectKey/$bbsRepoSlug)" |
    Tee-Object -FilePath $LOG_FILE -Append

  # Basic GH repo info (optional artifact, mirrors your ADO script)
  gh repo view "$githubOrg/$githubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate |
    Out-File -FilePath "validation-$githubRepo.json"

  $headers = Get-BbsHeaders
  $baseUrl = Get-BbsBaseUrl $bbsRepoUrl

  # Branches
  $ghBranches  = Get-GhBranches  -org $githubOrg -repo $githubRepo
  $bbsBranches = Get-BbsBranches -baseUrl $baseUrl -projectKey $bbsProjectKey -repoSlug $bbsRepoSlug -headers $headers

  $ghBranchCount  = $ghBranches.Count
  $bbsBranchCount = $bbsBranches.Count
  $branchCountStatus = if ($ghBranchCount -eq $bbsBranchCount) { "✅ Matching" } else { "❌ Not Matching" }

  Write-Output "[$(Get-Date)] Branch Count: BBS=$bbsBranchCount  GitHub=$ghBranchCount  $branchCountStatus" |
    Tee-Object -FilePath $LOG_FILE -Append

  $missingInGH  = $bbsBranches | Where-Object { $_ -notin $ghBranches }
  $missingInBBS = $ghBranches  | Where-Object { $_ -notin $bbsBranches }

  if ($missingInGH.Count -gt 0) {
    Write-Output "[$(Get-Date)] Branches missing in GitHub: $($missingInGH -join ', ')" |
      Tee-Object -FilePath $LOG_FILE -Append
  }
  if ($missingInBBS.Count -gt 0) {
    Write-Output "[$(Get-Date)] Branches missing in Bitbucket: $($missingInBBS -join ', ')" |
      Tee-Object -FilePath $LOG_FILE -Append
  }

  # Commits (only for branches that exist on both sides)
  foreach ($branch in ($ghBranches | Where-Object { $_ -in $bbsBranches })) {
    $ghInfo  = Get-GhCommitsInfo  -org $githubOrg -repo $githubRepo -branch $branch
    $bbsInfo = Get-BbsCommitsInfo -baseUrl $baseUrl -projectKey $bbsProjectKey -repoSlug $bbsRepoSlug -branch $branch -headers $headers

    $countMatch = ($ghInfo.Count -eq $bbsInfo.Count)
    $shaMatch   = ($ghInfo.Latest -eq $bbsInfo.Latest)

    $countStatus = if ($countMatch) { "✅ Matching" } else { "❌ Not Matching" }
    $shaStatus   = if ($shaMatch)   { "✅ Matching" } else { "❌ Not Matching" }

    Write-Output "[$(Get-Date)] Branch '$branch': BBS Commits=$($bbsInfo.Count)  GitHub Commits=$($ghInfo.Count)  $countStatus" |
      Tee-Object -FilePath $LOG_FILE -Append
    Write-Output "[$(Get-Date)] Branch '$branch': BBS SHA=$($bbsInfo.Latest)  GitHub SHA=$($ghInfo.Latest)  $shaStatus" |
      Tee-Object -FilePath $LOG_FILE -Append
  }

  Write-Output "[$(Get-Date)] Validation complete for $githubOrg/$githubRepo" |
    Tee-Object -FilePath $LOG_FILE -Append
}

function Validate-FromCSV {
  param([string]$csvPath = "repos.csv")

  if (-not (Test-Path $csvPath)) {
    Write-Output "[$(Get-Date)] ERROR: CSV file not found: $csvPath" |
      Tee-Object -FilePath $LOG_FILE -Append
    return
  }

  $repos = Import-Csv -Path $csvPath
  foreach ($repo in $repos) {
    $bbsProjectKey = $repo.'project-key'
    $bbsRepoSlug   = $repo.repo
    $bbsUrl        = $repo.url
    $ghOrg         = $repo.github_org
    $ghRepo        = $repo.github_repo

    Write-Output "[$(Get-Date)] Processing: BBS '$bbsProjectKey/$($repo.repo)' @ $($repo.url)  -->  GH '$ghOrg/$ghRepo'" |
      Tee-Object -FilePath $LOG_FILE -Append

    Validate-Migration -bbsProjectKey $bbsProjectKey `
                       -bbsRepoSlug   $bbsRepoSlug   `
                       -bbsRepoUrl    $bbsUrl        `
                       -githubOrg     $ghOrg         `
                       -githubRepo    $ghRepo
  }

  Write-Output "[$(Get-Date)] All validations from CSV completed" |
    Tee-Object -FilePath $LOG_FILE -Append
}

# Entrypoint
Validate-FromCSV -csvPath $CsvPath
