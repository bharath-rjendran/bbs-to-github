# Migration Strategy: bbs2gh (Bash + GitHub Actions)

This repository provides a **GitHub Actions-driven** migration pipeline to move repositories from **Bitbucket Server/Data Center** to **GitHub Enterprise Cloud** using the **GEI `gh-bbs2gh`** extension.

It uses **three Bash scripts**:

- `scripts/0_prechecks.sh` – **Pre-migration readiness** (Open PRs only)
- `scripts/1_migration.sh` – **Parallel migration runner** (supports storage auto-detection + Data Residency)
- `scripts/2_validation.sh` – **Post-migration validation** (branches, commit counts, latest SHA)

A **single combined workflow** orchestrates all 3 stages with an **issue-based manual approval gate** between readiness and migration/validation.

---

## ✅ What this workflow does

1. **Prechecks (optional)**
   - Calls Bitbucket REST API and produces `bbs_pr_validation_output-<timestamp>.csv`.
   - Flags repos with **open PRs** as a **warning** (not a hard blocker).

2. **Manual approval (required if migration/validation is requested)**
   - Opens a GitHub issue and waits for a configured approver to comment **approved**.

3. **Migration (optional)**
   - Runs migrations in parallel up to `max_concurrent`.
   - Produces `repo_migration_output-<timestamp>.csv` and per-repo log files `migration-*.txt`.
   - Supports:
     - **GitHub-owned storage** (`--use-github-storage`) by default
     - **AWS S3** (when AWS env vars are present)
     - **Azure Blob** (when `AZURE_STORAGE_CONNECTION_STRING` is present)

4. **Post-validation (optional)**
   - Validates **branch count**, **commit counts**, and **latest SHAs** between Bitbucket and GitHub.
   - Produces:
     - `validation-log-<YYYYMMDD>.txt`
     - `validation-summary.csv`
     - `validation_summary_<YYYYMMDD>.md` (also copied to `validation-summary.md` by the workflow)

---

## 📌 Workflow

- **Workflow file**: `.github/workflows/bbs2gh-migration-combined.yml`

### Workflow inputs

| Input | Required | Default | Notes |
|------|----------|---------|------|
| `csv_path` | ✅ | `repos.csv` | Path to your inventory/mapping CSV |
| `bbs_base_url` | ✅ | – | Bitbucket base URL, e.g. `https://bitbucket.example.com:7990` |
| `max_concurrent` | ❌ | `5` | Parallel migrations (script allows **1–20**) |
| `target_api_url` | ❌ | `https://api.github.com` | **Data Residency** target API endpoint |
| `run_prechecks` | ❌ | `true` | Run stage 0 |
| `run_migration` | ❌ | `true` | Run stage 1 |
| `run_post_validation` | ❌ | `true` | Run stage 2 |
| `approver` | ✅ | – | GitHub username(s) that can approve (comma-separated) |
| `runner_label` | ❌ | `ubuntu-latest` | Use GitHub-hosted runner or your `self-hosted` label |

---

## 📄 `repos.csv` format

The scripts expect these columns (header names must match):

```csv
project-key,project-name,repo,url,last-commit-date,repo-size-in-bytes,attachments-size-in-bytes,is-archived,pr-count,github_org,github_repo,gh_repo_visibility
```

**Minimum required columns used by scripts**:

- **Prechecks**: `project-key,repo`
- **Migration**: `project-key,project-name,repo,github_org,github_repo,gh_repo_visibility`
- **Validation**: `project-key,repo,url,github_org,github_repo`

> Tip: Keep a single CSV containing superset columns (as above). The scripts ignore extra columns they don’t need.

---

## 🔐 Required secrets / variables

### GitHub

- `GH_PAT` (**secret**) – GitHub PAT with permissions needed to create repos and run migrations.

### Bitbucket

Provide **either** PAT **or** Basic auth:

- `BBS_PAT` (**secret**) – Bitbucket PAT (preferred)

**OR**

- `BBS_AUTH_TYPE` (**secret/variable**) – set to `Basic`
- `BBS_USERNAME` (**secret**) – Bitbucket username
- `BBS_PASSWORD` (**secret**) – Bitbucket password

### SSH (required by migration)

- `SSH_USER` (**secret**) – SSH username to access Bitbucket archive export storage
- `SSH_PRIVATE_KEY` (**secret**) – **unencrypted** private key (raw PEM). Do not use a passphrase-protected key.

### Optional: Azure Blob storage backend

If set, migration uses Azure blob storage automatically.

- `AZURE_STORAGE_CONNECTION_STRING` (**secret**)

### Optional: AWS S3 storage backend

If set, migration uses S3 automatically.

- `AWS_ACCESS_KEY_ID` (**secret**)
- `AWS_SECRET_ACCESS_KEY` (**secret**)
- `AWS_BUCKET_NAME` (**secret**) (or your preferred bucket env mapping)
- `AWS_REGION` (**secret**)

> ⚠️ Do not set both AWS and Azure storage variables at the same time.

---

## 🌍 Data Residency support

For GitHub Enterprise Cloud **Data Residency**, pass the correct regional API endpoint using the workflow input:

- `target_api_url`

The migration script forwards this to `gh bbs2gh migrate-repo` using `--target-api-url`. It also supports the environment variable `TARGET_API_URL`.

---

## ▶️ How to run

1. Add the required **secrets** in your repository settings.
2. Ensure your runner (GitHub-hosted or self-hosted) can reach Bitbucket and can run `gh`, `jq`, `curl`, `python3`.
3. Go to **Actions → bbs-to-gh-migration (combined) → Run workflow**.
4. Fill inputs:
   - `csv_path` (usually `repos.csv`)
   - `bbs_base_url`
   - `approver`
   - optional stage toggles
5. After prechecks complete, the workflow opens an approval issue. Comment **approved** to continue.

---

## 📦 Artifacts produced

- **Prechecks**: `bbs-prechecks-<run_id>`
  - `bbs_pr_validation_output-*.csv`

- **Migration**: 
  - `migration-logs-<run_id>` → `migration-*.txt`
  - `migration-output-csv-<run_id>` → `repo_migration_output-*.csv`

- **Validation**: `validation-results-<run_id>`
  - `validation-log-*.txt`
  - `validation-summary.csv`
  - `validation_summary_*.md`
  - `validation-summary.md`

---

## 🧰 Generating `repos.csv`

If you maintain inventory scripts (for example, `inventory-report.sh` / `inventory-report.ps1`) to generate `repos.csv`, place them in the repository and run them prior to launching the workflow.

---

## Troubleshooting

- **`gh auth status` fails in workflow**: Ensure `GH_PAT` is set and valid. The workflow logs in using `gh auth login --with-token`.
- **SSH errors**: The migration script requires an **unencrypted** private key. Use a dedicated deploy key.
- **Open PR warnings**: Prechecks only report open PRs as warnings; you can still proceed after approval.
- **Validation mismatches**: Check `validation-log-*.txt` for missing branches or commit/SHA differences.

---

## Disclaimer

The GEI `bbs2gh` direct upload capability may require feature enablement/flags in your GitHub Enterprise Cloud environment. Coordinate with GitHub Support if needed.
