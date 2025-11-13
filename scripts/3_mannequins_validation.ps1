# Script parameters
param(
  [Parameter(Mandatory=$false)]
  [string]$GithubOrg = "GH-ORG",
  
  [Parameter(Mandatory=$false)]
  [string]$OutputFile = "mannequins.csv"
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Generating mannequin CSV for org '$GithubOrg'..."

# Run the gh ado2gh command directly
$cmdOutput = & gh ado2gh generate-mannequin-csv --github-org $GithubOrg --output $OutputFile 2>&1
$exit = $LASTEXITCODE

if ($exit -ne 0) {
  Write-Host $cmdOutput
  throw "gh ado2gh generate-mannequin-csv failed with exit code $exit."
}

# Validate the CSV and show a quick summary
if (-not (Test-Path -LiteralPath $OutputFile)) {
  throw "Command reported success, but '$OutputFile' was not created."
}

$rows = Import-Csv -LiteralPath $OutputFile
$cnt = ($rows | Measure-Object).Count
Write-Host "==> Wrote '$OutputFile' with $cnt mannequins."

if ($cnt -gt 0) {
  $rows | Select-Object -First 10 | Format-Table -AutoSize
} else {
  Write-Host "No mannequins found. (They may already be reclaimed, or your migration produced none.)"
}
