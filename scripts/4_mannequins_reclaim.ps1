# Script parameters
param(
  [Parameter(Mandatory=$false)]
  [string]$GithubOrg = "GH-ORG",
  
  [Parameter(Mandatory=$false)]
  [string]$CsvFile = "mannequins.csv",
  
  [Parameter(Mandatory=$false)]
  [switch]$SkipInvitation = $false
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Reclaiming mannequins for org '$GithubOrg' from '$CsvFile'..."

if (-not (Test-Path -LiteralPath $CsvFile)) {
  throw "CSV file not found: $CsvFile. Please run mannequin validation first."
}

# Build command arguments
$args = @(
  "bbs2gh", "reclaim-mannequin",
  "--github-org", $GithubOrg,
  "--csv", $CsvFile
)

if ($SkipInvitation) {
  $args += "--skip-invitation"
}

Write-Host "Running: gh $($args -join ' ')"
& gh @args

if ($LASTEXITCODE -ne 0) {
  throw "gh bbs2gh reclaim-mannequin failed with exit code $LASTEXITCODE"
}

Write-Host "==> Mannequin reclaim completed successfully"
