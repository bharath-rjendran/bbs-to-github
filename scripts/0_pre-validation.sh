#!/usr/bin/env bash
# Bitbucket Server/DC "pipeline" readiness check - Bash version
# Flags [BLOCKER] when:
#   • OPEN PRs
#   • INPROGRESS builds on latest default-branch commit
#   • Archived repo
#   • Missing default branch / latest commit
#
# Inputs:
#   - CsvPath      (default: repos.csv)
#   - OutputPath   (optional; default: bbs_pipeline_validation_output-<timestamp>.csv)
#
# Env:
#   BBS_SERVER_URL -> e.g., https://bitbucket.example.com
#   (Either) BBS_PAT OR BBS_USERNAME + BBS_PASSWORD
#
# Dependencies: bash 4+, curl, jq

set -u
set -o pipefail

# ---------- Defaults / args ----------
CSV_PATH="${1:-repos.csv}"
OUTPUT_PATH="${2:-}"

TS="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUTPUT_PATH}" ]]; then
  OUTPUT_CSV_PATH="bbs_pipeline_validation_output-${TS}.csv"
else
  OUTPUT_CSV_PATH="${OUTPUT_PATH}"
fi

# ---------- Required columns ----------
# Header is locked to the provided repos.csv schema
declare -a REQUIRED_COLUMNS=(
  "project-key" "project-name" "repo" "url"
  "last-commit-date" "repo-size-in-bytes" "attachments-size-in-bytes"
  "is-archived" "pr-count" "github_org" "github_repo" "gh_repo_visibility"
)

# ---------- Helpers ----------
error() { printf "\e[31m[ERROR]\e[0m %s\n" "$*" >&2; }
info()  { printf "\e[36m[INFO]\e[0m %s\n" "$*"; }
ok()    { printf "\e[32m[OK]\e[0m %s\n" "$*"; }
blocker(){ printf "\e[31m[BLOCKER]\e[0m %s\n" "$*"; }

trim_trailing_slash() {
  local s="$1"
  # remove trailing slash(s)
  printf '%s' "${s%/}"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { error "Required command not found: $cmd"; exit 1; }
}

# ---------- Preflight dep check ----------
require_cmd curl
require_cmd jq

# ---------- Env / Auth ----------
BBS_SERVER_URL="${BBS_SERVER_URL:-}"
if [[ -z "${BBS_SERVER_URL}" ]]; then
  error "BBS_SERVER_URL env var is required."
  exit 1
fi
BASE_URL="$(trim_trailing_slash "${BBS_SERVER_URL}")"

declare -a CURL_AUTH_ARGS=()
declare -a CURL_HEADERS=(
  "-H" "Accept: application/json"
)

if [[ -n "${BBS_PAT:-}" ]]; then
  CURL_HEADERS+=("-H" "Authorization: Bearer ${BBS_PAT}")
elif [[ -n "${BBS_USERNAME:-}" && -n "${BBS_PASSWORD:-}" ]]; then
  CURL_AUTH_ARGS=("-u" "${BBS_USERNAME}:${BBS_PASSWORD}")
else
  error "No Bitbucket credentials provided. Set BBS_PAT or BBS_USERNAME + BBS_PASSWORD."
  exit 1
fi

curl_json() {
  # curl wrapper returning JSON to stdout, failing on HTTP errors
  # Usage: curl_json "<URL>"
  local url="$1"
  curl --fail --silent --show-error "${CURL_AUTH_ARGS[@]}" "${CURL_HEADERS[@]}" "${url}"
}

# ---------- Pre-flight auth test (ADO-style early failure) ----------
if ! curl_json "${BASE_URL}/rest/api/1.0/projects?limit=1" >/dev/null; then
  error "Bitbucket auth failed. Verify BBS_SERVER_URL and credentials (BBS_PAT or BBS_USERNAME/BBS_PASSWORD)."
  exit 1
fi

# ---------- REST helpers ----------
bbs_get() {
  local url="$1"
  curl_json "$url"
}

# Accumulate all pages where response has { values, isLastPage, nextPageStart }
bbs_get_paged_values() {
  local base_url="$1"
  local start=0
  local first=true
  local tmp
  local acc='[]'
  while :; do
    local url
    if [[ "$base_url" == *"?"* ]]; then
      url="${base_url}&start=${start}"
    else
      url="${base_url}?start=${start}"
    fi

    tmp="$(bbs_get "${url}" || echo '{}')"
    # If first page returns no structure, exit
    if [[ "${first}" == "true" ]] && ! jq -e '.values' >/dev/null 2>&1 <<<"${tmp}"; then
      break
    fi
    first=false

    # Append values to acc
    acc="$(jq -c --argjson a "${acc}" --argjson b "$(jq -c '.values // []' <<<"${tmp}")" \
        -n '$a + $b')"

    local is_last next_start
    is_last="$(jq -r '.isLastPage // true' <<<"${tmp}")"
    next_start="$(jq -r '.nextPageStart // empty' <<<"${tmp}")"

    if [[ "${is_last}" == "true" || -z "${next_start}" ]]; then
      break
    fi
    start="${next_start}"
  done

  printf '%s\n' "${acc}"
}

# ---------- Domain helpers ----------
get_default_branch_display_id() {
  local project="$1" repo="$2"

  # Try repo default API
  local j
  j="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${project}/repos/${repo}/branches/default" 2>/dev/null || echo '{}')"

  local displayId
  displayId="$(jq -r '.displayId // empty' <<<"${j}")"
  if [[ -n "${displayId}" && "${displayId}" != "null" ]]; then
    printf '%s\n' "${displayId}"
    return 0
  fi

  # Fallback: list branches and locate isDefault
  local branches
  branches="$(bbs_get_paged_values "${BASE_URL}/rest/api/1.0/projects/${project}/repos/${repo}/branches?limit=100")"

  displayId="$(jq -r '[.[] | select(.isDefault == true) | .displayId // (.id | sub("^refs/heads/";""))] | .[0] // empty' <<<"${branches}")"
  printf '%s\n' "${displayId}"
}

get_latest_commit_on_branch() {
  local project="$1" repo="$2" branch_display="$3"
  local q="?limit=1"
  if [[ -n "${branch_display}" ]]; then
    q+="&until=${branch_display}"
  fi

  local j
  j="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${project}/repos/${repo}/commits${q}" 2>/dev/null || echo '{}')"
  jq -r '.values[0].id // empty' <<<"${j}"
}

get_build_statuses_for_commit() {
  local project="$1" repo="$2" commit="$3"

  # Preferred repo-scoped builds resource
  local j
  j="$(bbs_get "${BASE_URL}/rest/api/1.0/projects/${project}/repos/${repo}/commits/${commit}/builds" 2>/dev/null || echo '{}')"
  local count
  count="$(jq -r '.values | length // 0' <<<"${j}")"
  if [[ "${count}" -gt 0 ]]; then
    jq -c '.values' <<<"${j}"
    return 0
  fi

  # Fallback (deprecated global)
  j="$(bbs_get "${BASE_URL}/rest/build-status/latest/commits/${commit}" 2>/dev/null || echo '{}')"
  jq -c '.values // []' <<<"${j}"
}

get_open_pr_count() {
  local project="$1" repo="$2"
  local prs
  prs="$(bbs_get_paged_values "${BASE_URL}/rest/api/1.0/projects/${project}/repos/${repo}/pull-requests?state=OPEN&limit=100")"
  jq -r 'length' <<<"${prs}"
}

# ---------- CSV header validation ----------
if [[ ! -f "${CSV_PATH}" ]]; then
  error "CSV not found: ${CSV_PATH}"
  exit 1
fi

# Read first line (header)
IFS= read -r HEADER_LINE < "${CSV_PATH}" || { error "CSV is empty: ${CSV_PATH}"; exit 1; }
if [[ -z "${HEADER_LINE}" ]]; then
  error "CSV is empty: ${CSV_PATH}"
  exit 1
fi

# Split header into array (simple CSV: no embedded commas)
declare -a HEADER=()
IFS=',' read -r -a HEADER <<< "${HEADER_LINE}"

# Trim spaces from header cells
for i in "${!HEADER[@]}"; do
  HEADER[$i]="$(echo "${HEADER[$i]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
done

# Build name->index map
declare -A COLIDX=()
for i in "${!HEADER[@]}"; do
  COLIDX["${HEADER[$i]}"]="$i"
done

# Validate required columns present
declare -a MISSING=()
for col in "${REQUIRED_COLUMNS[@]}"; do
  if [[ -z "${COLIDX[$col]:-}" ]]; then
    MISSING+=("$col")
  fi
done

if [[ "${#MISSING[@]}" -gt 0 ]]; then
  error "Missing columns in CSV: ${MISSING[*]}"
  error "Required columns: ${REQUIRED_COLUMNS[*]}"
  exit 1
fi

# ---------- Output CSV init ----------
# Columns mirror PowerShell output
printf 'project_key,project_name,repo_slug,url,github_org,github_repo,gh_repo_visibility,default_branch,latest_commit_id,build_inprogress_count,build_success_count,build_failed_count,build_cancelled_count,open_pr_count,is_archived,blockers\n' > "${OUTPUT_CSV_PATH}"

printf "\e[36m==================================================\n"
printf " Bitbucket Pipeline Readiness Check (PRs + Builds)\n"
printf "==================================================\e[0m\n"

# ---------- Processing ----------
TOTAL_REPOS=0
RUNNING_BUILDS_REPOS=0
REPOS_WITH_OPEN_PRS=0
OPEN_PRS_TOTAL=0

{
  # Skip header
  read -r _header_line

  while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue

    # Split line into fields (simple CSV; if you need quoted commas, I can provide a robust CSV reader)
    IFS=',' read -r -a FIELDS <<< "${LINE}"
    if [[ "${#FIELDS[@]}" -lt "${#HEADER[@]}" ]]; then
      for ((k="${#FIELDS[@]}"; k<"${#HEADER[@]}"; k++)); do FIELDS[k]=""; done
    fi

    projKey="$(echo "${FIELDS[${COLIDX["project-key"]}]}" | xargs)"
    projName="$(echo "${FIELDS[${COLIDX["project-name"]}]}" | xargs)"
    repoSlug="$(echo "${FIELDS[${COLIDX["repo"]}]}" | xargs)"
    urlVal="$(echo "${FIELDS[${COLIDX["url"]}]}" | xargs)"
    isArchivedRaw="$(echo "${FIELDS[${COLIDX["is-archived"]}]}" | xargs)"
    githubOrg="$(echo "${FIELDS[${COLIDX["github_org"]}]}" | xargs)"
    githubRepo="$(echo "${FIELDS[${COLIDX["github_repo"]}]}" | xargs)"
    ghVis="$(echo "${FIELDS[${COLIDX["gh_repo_visibility"]}]}" | xargs)"

    [[ -z "${projKey}" || -z "${repoSlug}" ]] && continue
    ((TOTAL_REPOS++))

    # Default branch + latest commit
    defaultBranchDisplayId="$(get_default_branch_display_id "${projKey}" "${repoSlug}")"
    latestCommitId=""
    [[ -n "${defaultBranchDisplayId}" ]] && latestCommitId="$(get_latest_commit_on_branch "${projKey}" "${repoSlug}" "${defaultBranchDisplayId}")"

    # Build statuses on latest commit
    inprogress=0; successful=0; failed=0; cancelled=0; unknown=0
    if [[ -n "${latestCommitId}" ]]; then
      statuses_json="$(get_build_statuses_for_commit "${projKey}" "${repoSlug}" "${latestCommitId}")"
      while IFS= read -r st; do
        case "${st}" in
          INPROGRESS) ((inprogress++)) ;;
          SUCCESSFUL) ((successful++)) ;;
          FAILED)     ((failed++)) ;;
          CANCELLED)  ((cancelled++)) ;;
          *)          ((unknown++)) ;;
        esac
      done < <(jq -r '.[] | (.state // "UNKNOWN") | ascii_upcase' <<<"${statuses_json}")
    fi

    # Open PRs
    openPrs="$(get_open_pr_count "${projKey}" "${repoSlug}")"
    OPEN_PRS_TOTAL=$((OPEN_PRS_TOTAL + openPrs))

    # Blockers
    blockers=()
    archivedB="false"
    if [[ -n "${isArchivedRaw}" ]]; then
      lc="$(echo "${isArchivedRaw}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${lc}" == "true" ]]; then archivedB="true"; blockers+=("ARCHIVED_REPO"); fi
    fi
    [[ "${inprogress}" -gt 0 ]] && blockers+=("RUNNING_BUILDS")
    [[ "${openPrs}" -gt 0 ]] && blockers+=("OPEN_PRS")
    [[ -z "${defaultBranchDisplayId}" ]] && blockers+=("NO_DEFAULT_BRANCH")
    [[ -z "${latestCommitId}" ]] && blockers+=("NO_LATEST_COMMIT")

    # Print status line
    if [[ "${#blockers[@]}" -gt 0 ]]; then
      blocker "$(printf "%s/%s PRs(Open): %d Builds(InProg/Fail/Succ): %d/%d/%d Blockers: %s" \
        "${projKey}" "${repoSlug}" "${openPrs}" "${inprogress}" "${failed}" "${successful}" "$(IFS=','; echo "${blockers[*]}")")"
    else
      ok "$(printf "%s/%s PRs(Open): %d Builds(InProg/Fail/Succ): %d/%d/%d" \
        "${projKey}" "${repoSlug}" "${openPrs}" "${inprogress}" "${failed}" "${successful}")"
    fi

    # Aggregate stats (must be done regardless of blockers)
    (( RUNNING_BUILDS_REPOS += (inprogress > 0) ? 1 : 0 ))
    (( REPOS_WITH_OPEN_PRS += (openPrs > 0) ? 1 : 0 ))

    # Output row (preserve GitHub mapping columns)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d,%d,%s,%s\n' \
      "${projKey}" \
      "${projName}" \
      "${repoSlug}" \
      "${urlVal}" \
      "${githubOrg}" \
      "${githubRepo}" \
      "${ghVis}" \
      "${defaultBranchDisplayId}" \
      "${latestCommitId}" \
      "${inprogress}" \
      "${successful}" \
      "${failed}" \
      "${cancelled}" \
      "${openPrs}" \
      "${archivedB}" \
      "$(IFS=';'; echo "${blockers[*]}")" \
      >> "${OUTPUT_CSV_PATH}"

  done
} < "${CSV_PATH}"

info "Wrote precheck CSV: ${OUTPUT_CSV_PATH}"

# ---------- Summary ----------
printf "\n\e[32m[SUMMARY] Total repos: %s\e[0m\n" "${TOTAL_REPOS}"
printf "\e[32mRepos with RUNNING builds: %s\e[0m\n" "${RUNNING_BUILDS_REPOS}"
printf "\e[32mRepos with OPEN PRs: %s (total open PRs: %s)\e[0m\n" "${REPOS_WITH_OPEN_PRS}" "${OPEN_PRS_TOTAL}"
