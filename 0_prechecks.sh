#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./0_pr_pipeline_check.sh [-c repos.csv] [-o output.csv] [-p "KEY1,KEY2"]
#
# CSV minimum columns if provided: project-key,repo
# Env: BBS_BASE_URL + (BBS_PAT or BBS_USERNAME+BBS_PASSWORD with BBS_AUTH_TYPE=Basic)

CSV_PATH="repos.csv"
OUTPUT_PATH=""
PROJECT_KEYS_CSV=""

sed -i 's/"//g' $CSV_PATH

while getopts ":c:o:p:" opt; do
  case "$opt" in
    c) CSV_PATH="$OPTARG" ;;
    o) OUTPUT_PATH="$OPTARG" ;;
    p) PROJECT_KEYS_CSV="$OPTARG" ;;
    *) echo "Usage: $0 [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]" >&2; exit 1 ;;
  esac
done

if [[ -z "${BBS_BASE_URL:-}" ]]; then
  echo "[ERROR] BBS_BASE_URL env var is required." >&2
  exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    echo "Authorization: Bearer ${BBS_PAT}"
  elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
    b64="$(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64)"
    echo "Authorization: Basic ${b64}"
  else
    echo "[ERROR] Provide BBS_PAT or BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD." >&2
    exit 1
  fi
}

curl_json() {
  curl -sS -H "$(auth_header)" "$1"
}

# Preflight auth test
curl -f -sS -H "$(auth_header)" "${BASE_URL}/rest/api/1.0/projects?limit=1" >/dev/null || {
  echo "[ERROR] Bitbucket auth failed. Verify BBS_BASE_URL and credentials." >&2
  exit 1
}

timestamp="$(date +'%Y%m%d-%H%M%S')"
OUTPUT_CSV="${OUTPUT_PATH:-bbs_pr_validation_output-${timestamp}.csv}"

IFS=',' read -r -a PROJECT_KEYS <<< "${PROJECT_KEYS_CSV:-}"

discover_projects() {
  local start=0 vals isLast nextStart
  local results=()
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects?limit=100&start=${start}")"
    vals="$(echo "$resp" | jq -r '.values[]?.key')"
    [[ -n "$vals" ]] && results+=($(echo "$vals"))
    isLast="$(echo "$resp" | jq -r '.isLastPage')"
    nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  printf "%s\n" "${results[@]}"
}

discover_repos_for_project() {
  local projectKey="$1"
  local start=0
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos?limit=100&start=${start}")"
    echo "$resp" | jq -r '.values[]? | @base64' | while read -r row; do
      _jq() { echo "$row" | base64 --decode | jq -r "$1"; }
      printf "%s,%s,%s\n" "$(_jq '.project.name')" "$(_jq '.slug')" "$(_jq '.archived')"
    done
    isLast="$(echo "$resp" | jq -r '.isLastPage')"
    nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
}

get_open_pr_count() {
  local projectKey="$1" repoSlug="$2"
  local start=0 total=0
  while :; do
    resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/pull-requests?state=OPEN&limit=100&start=${start}")" || break
    cnt="$(echo "$resp" | jq '.values | length')"
    total=$(( total + cnt ))
    isLast="$(echo "$resp" | jq -r '.isLastPage')"
    nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  echo "$total"
}

echo ""
echo " Bitbucket Pipeline Readiness Check (Open PRs only) "
echo "===================================================="

# Load or discover input rows
rows_tmp="$(mktemp)"
if [[ -f "$CSV_PATH" ]] && [[ -s "$CSV_PATH" ]]; then
  header="$(head -n1 "$CSV_PATH")"
  if echo "$header" | grep -q "project-key" && echo "$header" | grep -q ",repo"; then
    tail -n +2 "$CSV_PATH" > "$rows_tmp"
  else
    echo "[ERROR] CSV missing minimum columns: project-key,repo"
    echo "[INFO] Falling back to auto-discovery."
  fi
fi

if [[ ! -s "$rows_tmp" ]]; then
  echo "[INFO] Auto-discovering projects & repos..."
  projects=($(discover_projects))
  for pk in "${projects[@]}"; do
    if [[ "${#PROJECT_KEYS[@]}" -gt 0 ]]; then
      match=false
      for filter in "${PROJECT_KEYS[@]}"; do [[ "$pk" == "$filter" ]] && match=true; done
      [[ "$match" == "false" ]] && continue
    fi
    discover_repos_for_project "$pk" | while IFS=',' read -r pname rslug archived; do
      printf "%s,%s,%s,%s\n" "$pk" "$pname" "$rslug" "$archived" >> "$rows_tmp"
    done
  done
fi

# Process
ready_tmp="$(mktemp)"
results_tmp="$(mktemp)"
echo "project_key,project_name,repo_slug,is_archived,open_pr_count,warnings,ready_to_migrate" > "$results_tmp"

total_open_prs=0
while IFS=',' read -r projKey projName repoSlug isArchived; do
  openPrs="$(get_open_pr_count "$projKey" "$repoSlug")"
  total_open_prs=$(( total_open_prs + openPrs ))
  warns=""
  if (( openPrs > 0 )); then
    warns="OPEN_PRS"
    echo "[WARNING] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
  else
    echo "[OK] ${projKey}/${repoSlug} PRs(Open): ${openPrs}"
    echo "${projKey}/${repoSlug}" >> "$ready_tmp"
  fi
  ready=false; [[ -z "$warns" ]] && ready=true
  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$projKey" "$projName" "$repoSlug" "${isArchived:-false}" "$openPrs" "$warns" "$ready" >> "$results_tmp"
done < "$rows_tmp"

mv "$results_tmp" "$OUTPUT_CSV"
echo "[INFO] Wrote precheck CSV: $OUTPUT_CSV"

if [[ -s "$ready_tmp" ]]; then
  echo ""
  echo "[READY] Repos ready to migrate (no open PRs)✅:"
  sed 's/^/ - /' "$ready_tmp"
else
  echo ""
  echo "[READY] No repos are currently without open PRs."
fi

total_repos="$(($(wc -l < "$rows_tmp")))"
repos_with_warnings="$(awk -F',' 'NR>1 && $6!="" {c++} END{print c+0}' "$OUTPUT_CSV")"

echo ""
echo "[SUMMARY] Total repos: $total_repos"
echo "Open PRs total: $total_open_prs"
echo "======================Completed============================="