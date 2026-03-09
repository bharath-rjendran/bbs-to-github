#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Bitbucket ↔ GitHub Migration Validation (CLI)
# - Validates branch sets, commit counts, and latest SHAs between Bitbucket S/DC and GitHub
# - Writes: validation-log-<date>.txt, validation-summary.csv, validation-summary.md
#
# CSV columns required: project-key, repo, url, github_org, github_repo (others ignored)
#
# Env:
#   BBS_BASE_URL   : e.g., http://bitbucket.example.com:7990 (or pass -b)
#   Auth: BBS_PAT OR (BBS_AUTH_TYPE=Basic with BBS_USERNAME + BBS_PASSWORD)
#   gh auth status (GH_TOKEN/GH_PAT or interactive)
#
# Usage:
#   ./2_validation.sh [-c repos.csv] [-b http://host:7990]
# ------------------------------------------------------------------------------

set -euo pipefail

CSV_PATH="./repos.csv"
BBS_BASE_URL="${BBS_BASE_URL:-}"

while getopts ":c:b:" opt; do
  case "$opt" in
    c) CSV_PATH="$OPTARG" ;;
    b) BBS_BASE_URL="$OPTARG" ;;
    *) echo "Usage: $0 [-c repos.csv] [-b BBS_BASE_URL]" >&2; exit 1 ;;
  esac
done

# GH auth
if ! gh auth status >/dev/null 2>&1; then
  echo "[ERROR] GitHub CLI not authenticated. Run: gh auth login (or set GH_TOKEN/GH_PAT)." >&2
  exit 1
fi

# Base URL
if [[ -z "$BBS_BASE_URL" ]]; then
  echo "BbsBaseUrl is required (pass -b or export BBS_BASE_URL)." >&2
  exit 1
fi
BASE_URL="${BBS_BASE_URL%/}"

LOG_FILE="validation-log-$(date +'%Y%m%d-%H%M%S').txt"

# ---- Bitbucket auth header ----------------------------------------------------
auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    printf "Authorization: Bearer %s" "$BBS_PAT"
  elif [[ "${BBS_AUTH_TYPE:-}" == "Basic" && -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
    local b64; b64="$(printf '%s:%s' "$BBS_USERNAME" "$BBS_PASSWORD" | base64)"
    printf "Authorization: Basic %s" "$b64"
  else
    echo "[ERROR] Provide Bitbucket credentials via BBS_PAT (preferred) or set BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD." >&2
    exit 1
  fi
}

curl_json() { curl -sS -H "$(auth_header)" "$1"; }

# ---- Bitbucket helpers --------------------------------------------------------
get_bbs_branches() {
  local projectKey="$1" repoSlug="$2" start=0
  local branches=()
  while :; do
    local resp; resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/branches?limit=500&start=${start}")"
    mapfile -t chunk < <(echo "$resp" | jq -r '.values[]?.displayId')
    branches+=("${chunk[@]}")
    local isLast; isLast="$(echo "$resp" | jq -r '.isLastPage')"
    local nextStart; nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  printf "%s\n" "${branches[@]}" | sort -u
}

urlencode_py() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
}

get_bbs_commits_info() {
  local projectKey="$1" repoSlug="$2" branch="$3"
  # If called with a 4th arg (known GH SHA), fetch only the first page to get the
  # latest BBS SHA and short-circuit the full count pagination when SHAs match.
  local known_gh_sha="${4:-}"
  local total=0 latest="" start=0 limit=1000
  local encBranch; encBranch="$(urlencode_py "$branch")"
  while :; do
    local resp; resp="$(curl_json "${BASE_URL}/rest/api/1.0/projects/${projectKey}/repos/${repoSlug}/commits?until=${encBranch}&limit=${limit}&start=${start}")"
    local cnt; cnt="$(echo "$resp" | jq '.values | length')"
    if [[ -z "$latest" && "$cnt" -gt 0 ]]; then
      latest="$(echo "$resp" | jq -r '.values[0].id')"
      # If caller supplied the GH SHA and it already matches, no need to count all pages
      if [[ -n "$known_gh_sha" && "$latest" == "$known_gh_sha" ]]; then
        # Return a sentinel count equal to GH count (caller checks SHA first)
        echo "SKIP,${latest}"
        return
      fi
    fi
    total=$(( total + cnt ))
    local isLast; isLast="$(echo "$resp" | jq -r '.isLastPage')"
    local nextStart; nextStart="$(echo "$resp" | jq -r '.nextPageStart // empty')"
    [[ "$isLast" == "true" ]] && break
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  echo "${total},${latest}"
}

# ---- GitHub helpers -----------------------------------------------------------
gh_repo_exists() { gh api -X GET "/repos/$1/$2" >/dev/null 2>&1; }

get_gh_branches() {
  gh api "/repos/$1/$2/branches" --paginate | jq -r '.[].name' | sort -u
}

get_gh_commits_info() {
  local org="$1" repo="$2" branch="$3"
  local total=0 latest="" page=1 per=100
  local encBranch; encBranch="$(urlencode_py "$branch")"
  while :; do
    local chunk; chunk="$(gh api "/repos/${org}/${repo}/commits?sha=${encBranch}&page=${page}&per_page=${per}" | jq -c '.')"
    local count; count="$(echo "$chunk" | jq 'length')"
    if [[ "$page" -eq 1 && "$count" -gt 0 ]]; then
      latest="$(echo "$chunk" | jq -r '.[0].sha')"
    fi
    total=$(( total + count ))
    [[ "$count" -lt "$per" ]] && break
    page=$((page+1))
  done
  echo "${total},${latest}"
}

status_marker() { # $1: ok|true|false
  [[ "$1" == "true" ]] && echo "✅ Matching" || echo "❌ Not Matching"
}

# ---- Banners ------------------------------------------------------------------
echo "=================================================="
echo " Bitbucket ↔ GitHub Migration Validation (CLI) "
echo "=================================================="
echo "Using CSV: ${CSV_PATH}"
echo "Using Bitbucket Base URL: ${BASE_URL}"

# ---- CSV helpers (RFC 4180 compliant) -----------------------------------------
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

strip_quotes() {
  local s="$1"
  [[ ${s} == \"* ]] && s="${s#\"}"
  [[ ${s} == *\" ]] && s="${s%\"}"
  printf '%s' "$s"
}

# ---- CSV checks ---------------------------------------------------------------
[[ -f "$CSV_PATH" ]] || { echo "[ERROR] CSV file not found: $CSV_PATH" | tee -a "$LOG_FILE"; exit 1; }
[[ -s "$CSV_PATH" ]] || { echo "[ERROR] CSV has no rows: $CSV_PATH" | tee -a "$LOG_FILE"; exit 1; }

# Validate header and build column index
REQUIRED_COLUMNS=(project-key project-name repo github_org github_repo)
read -r HEADER_LINE < "$CSV_PATH"
mapfile -t HEADER_FIELDS < <(parse_csv_line "${HEADER_LINE}")
declare -A COLIDX=()
for idx in "${!HEADER_FIELDS[@]}"; do
  name="${HEADER_FIELDS[$idx]}"
  name="${name%\"}"; name="${name#\"}"
  COLIDX["$name"]="$idx"
done
missing_cols=()
for col in "${REQUIRED_COLUMNS[@]}"; do
  [[ -n "${COLIDX[$col]:-}" ]] || missing_cols+=("$col")
done
if [[ ${#missing_cols[@]} -gt 0 ]]; then
  echo "Missing required column(s): ${missing_cols[*]}" >&2; exit 1
fi

summary_csv="validation-summary-$(date +'%Y%m%d-%H%M%S').csv"
echo "github_org,github_repo,bbs_project_key,bbs_repo,branch_count_bbs,branch_count_gh,branch_count_match,commits_match_all,shas_match_all,gh_notes" > "$summary_csv"

echo "==> Starting validation..."

# ---- Parallel validation -------------------------------------------------------
# Each repo is validated in a background subshell. Results are written to
# per-repo temp files then merged in order into the summary CSV.
validate_repo() {
  local bbsProjectKey="$1" bbsRepoSlug="$2" ghOrg="$3" ghRepo="$4"
  local out_file="$5"  # temp file for this repo's CSV row + log lines

  {
    echo "[$(date)] Processing: ${bbsProjectKey}/${bbsRepoSlug} -> ${ghOrg}/${ghRepo}"

    local ghExists="yes"
    if ! gh_repo_exists "$ghOrg" "$ghRepo"; then
      echo "[$(date)] GitHub repo not found or inaccessible: ${ghOrg}/${ghRepo}. Treating GH side as empty."
      ghExists="no"
    fi

    local bbsBranches=() ghBranches=()
    mapfile -t bbsBranches < <(get_bbs_branches "$bbsProjectKey" "$bbsRepoSlug")
    mapfile -t ghBranches < <( [[ "$ghExists" == "yes" ]] && get_gh_branches "$ghOrg" "$ghRepo" || true )

    local bbsBranchCount="${#bbsBranches[@]}" ghBranchCount="${#ghBranches[@]}"
    local branchCountOk="false"; [[ "$bbsBranchCount" -eq "$ghBranchCount" ]] && branchCountOk="true"
    echo "[$(date)] Branch Count: BBS=${bbsBranchCount} GitHub=${ghBranchCount} $(status_marker "$branchCountOk")"

    local missingInGH missingInBBS
    missingInGH=$(comm -23 <(printf "%s\n" "${bbsBranches[@]}" | sort) <(printf "%s\n" "${ghBranches[@]}" | sort || true) || true)
    missingInBBS=$(comm -13 <(printf "%s\n" "${bbsBranches[@]}" | sort) <(printf "%s\n" "${ghBranches[@]}" | sort || true) || true)
    [[ -n "$missingInGH" ]]  && echo "[$(date)] Branches missing in GitHub: $(echo "$missingInGH" | tr '\n' ', ')"
    [[ -n "$missingInBBS" ]] && echo "[$(date)] Branches missing in Bitbucket: $(echo "$missingInBBS" | tr '\n' ', ')"

    local commitsMatchAll="false" shasMatchAll="false"
    if [[ "$ghExists" == "yes" ]]; then
      local common=()
      mapfile -t common < <(comm -12 <(printf "%s\n" "${bbsBranches[@]}" | sort) <(printf "%s\n" "${ghBranches[@]}" | sort))
      if (( ${#common[@]} > 0 )); then
        commitsMatchAll="true"
        shasMatchAll="true"
        for br in "${common[@]}"; do
          local ghInfo bbsInfo
          ghInfo="$(get_gh_commits_info "$ghOrg" "$ghRepo" "$br")"
          local ghCount="${ghInfo%%,*}" ghSha="${ghInfo#*,}"

          # Pass ghSha so BBS side can short-circuit when SHA already matches
          bbsInfo="$(get_bbs_commits_info "$bbsProjectKey" "$bbsRepoSlug" "$br" "$ghSha")"
          local bbsCount="${bbsInfo%%,*}" bbsSha="${bbsInfo#*,}"

          local shaOk="false"; [[ "$ghSha" == "$bbsSha" ]] && shaOk="true"
          [[ "$shaOk" == "false" ]] && shasMatchAll="false"

          local countOk="false"
          if [[ "$bbsCount" == "SKIP" ]]; then
            # SHA matched — commits are identical by definition
            countOk="true"
          else
            [[ "$ghCount" == "$bbsCount" ]] && countOk="true"
            [[ "$countOk" == "false" ]] && commitsMatchAll="false"
            echo "[$(date)] Branch '$br': BBS Commits=${bbsCount} GitHub Commits=${ghCount} $(status_marker "$countOk")"
          fi
          echo "[$(date)] Branch '$br': BBS SHA=${bbsSha} GitHub SHA=${ghSha} $(status_marker "$shaOk")"
        done
      fi
    fi

    local gh_notes=""
    if [[ "$ghExists" == "no" ]]; then
      gh_notes="repo not found or no access"
    elif [[ "$ghBranchCount" -eq 0 && "$bbsBranchCount" -gt 0 ]]; then
      gh_notes="no branches on GH"
    fi

    echo "[$(date)] Validation complete for ${ghOrg}/${ghRepo}"
    # Write the CSV row as a sentinel line prefixed with CSV: so we can extract it
    printf 'CSV:%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ghOrg" "$ghRepo" "$bbsProjectKey" "$bbsRepoSlug" \
      "$bbsBranchCount" "$ghBranchCount" "$branchCountOk" \
      "$commitsMatchAll" "$shasMatchAll" "$gh_notes"
  } > "$out_file" 2>&1
}

# Launch all repos in parallel
declare -a PIDS=() OUTFILES=()
while IFS= read -r line; do
  mapfile -t F < <(parse_csv_line "$line")
  bbsProjectKey="$(strip_quotes "${F[${COLIDX[project-key]}]}")"  
  bbsRepoSlug="$(strip_quotes "${F[${COLIDX[repo]}]}")"
  ghOrg="$(strip_quotes "${F[${COLIDX[github_org]}]}")"
  ghRepo="$(strip_quotes "${F[${COLIDX[github_repo]}]}")"
  tmp_out="$(mktemp)"
  OUTFILES+=("$tmp_out")
  validate_repo "$bbsProjectKey" "$bbsRepoSlug" "$ghOrg" "$ghRepo" "$tmp_out" &
  PIDS+=("$!")
done < <(tail -n +2 "$CSV_PATH")

# Collect results in submission order
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}" || true
  out="${OUTFILES[$i]}"
  if [[ -f "$out" ]]; then
    # Emit log lines (everything except the CSV: sentinel)
    grep -v '^CSV:' "$out" | tee -a "$LOG_FILE"
    # Append the CSV row (strip the CSV: prefix)
    grep '^CSV:' "$out" | sed 's/^CSV://' >> "$summary_csv"
    rm -f "$out"
  fi
done

echo "[$(date)] All validations from CSV completed" | tee -a "$LOG_FILE"

# Markdown table (name matches the summary CSV for easy correlation)
md="${summary_csv%.csv}.md"
{
  echo "| GitHub Repo | BBS Repo | Branch Count (BBS/GH) | Branch Count Match | All Commit Counts Match | All Latest SHAs Match | Notes |"
  echo "|---|---|---:|---|---|---|---|"
  # Read rows directly from the CSV file (no pipe → no subshell surprises)
  while IFS=',' read -r ghOrg ghRepo bbsKey bbsRepo bcB ghC bcOk ccOk shaOk notes; do
    # Skip empty lines
    [[ -z "$ghOrg" && -z "$ghRepo" ]] && continue
    printf "| %s/%s | %s/%s | %s/%s | %s | %s | %s | %s |\n" \
      "$ghOrg" "$ghRepo" \
      "$bbsKey" "$bbsRepo" \
      "$bcB" "$ghC" \
      "$( [[ "$bcOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "$( [[ "$ccOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "$( [[ "$shaOk" == "true" ]] && echo "✅" || echo "❌" )" \
      "${notes}"
  done < <(tail -n +2 "$summary_csv")
} > "$md"
echo "=======================Summary==========================="
cat ${md}
echo "======================Completed==========================="