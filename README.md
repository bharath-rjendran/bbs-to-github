# 🚀 Bitbucket Server to GitHub Repository Migration Pipeline

> A GitHub Actions–based solution for migrating **Bitbucket Server** repositories to **GitHub** at scale. Supports parallel migrations, pre-migration checks, post-migration validation, multiple storage backends, and GitHub Data Residency.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Migration Tool](https://img.shields.io/badge/Tool-gh--bbs2gh-181717.svg)](https://github.com/github/gh-bbs2gh)
[![Platform](https://img.shields.io/badge/Platform-Bash%20%7C%20PowerShell-blue.svg)](https://github.com/github/gh-bbs2gh)

---

## 📋 Table of Contents

- [Introduction](#-introduction)
- [Limitations](#️-limitations)
- [Prerequisites](#️-prerequisites)
- [Initial Setup](#-initial-setup)
- [Quick Start](#-quick-start)
- [Artifacts and References](#-artifacts-and-references)

---

## 📖 Introduction

Migrating repositories from Bitbucket Server to GitHub is a multi-stage process that includes readiness validation, parallel repository migration, and post-migration verification. When applied across hundreds or thousands of repositories, this process becomes difficult to coordinate, error-prone, and hard to scale using ad-hoc commands.

This toolkit addresses those challenges through a staged, CSV-driven execution model. Each stage runs independently, produces machine-readable output, and can be executed from the command line or embedded inside a CI/CD pipeline. Failures in individual repositories are isolated — they do not block the remaining batch.

---

## ⚠️ Limitations

- Limitation of GHE
  - 2 GiB size limit for a single Git commit: No single commit in your Git repository can be larger than 2 GiB.
  - 255 byte limit for Git references: No single Git reference, commonly known as a "ref", can have a name larger than 255 bytes.
  - 100 MiB file size limit: After you complete your migration, no single file in your Git repository can be larger than 100 MiB.

- Limitations of GitHub Enterprise Importer:
  - 40 GiB size limit for repository archives: The Importer cannot migrate repositories with more than 40 GiB of combined git data and metadata in the repository archive.
  - 400 MiB file size limit: no single file in your Git repository can be larger than 400 MiB.
  - Git LFS objects not migrated.
  - Delayed code search functionality: Re-indexing the search index can take a few hours after a repository is migrated, and code searches may return unexpected results until re-indexing is complete.

- What Gets Migrated
  - Git repository content (all files)
  - Complete commit history
  - All branches and tags
  - Commit metadata (authors, dates, messages, SHAs)

- Maximum Concurrency
  - The migration stage enforces a hard cap of **20 concurrent migrations** per run.
  - The default concurrency is **3**. Increase with `--max-concurrent` up to the limit.
  - The actual repository migration runs on **GitHub's backend services**, not on the local machine. The script only polls migration status at regular intervals.

- **Track Long-Running Migrations:**
If a migration is taking longer than expected, monitor progress directly using the GitHub CLI:

```bash
gh extension install mona-actions/gh-migration-monitor
gh migration monitor
```

[GitHub Migration Monitor](https://github.com/mona-actions/gh-migration-monitor)

---

## ⚙️ Prerequisites

- To migrate a repository, you must be an organization owner for the destination organization in GitHub, or an organization owner must grant you the migrator role.
- You must also have required permissions and access to your Bitbucket Server instance:
  -  Admin or super admin permissions.
  -  If your Bitbucket Server instance runs Linux, SFTP access to the instance, using a supported SSH private key.
  -  If your Bitbucket Server instance runs Windows, file sharing (SMB) access to the instance.


---

## 🔧 Initial Setup

Complete these steps before your first migration run:

#### 1️⃣ 🔐 Authenticate the GitHub CLI

```bash
gh auth login
# or export the token directly:
export GH_PAT=<your-github-pat>
```

---

#### 2️⃣ 🧩 Install the BBS2GH Extension

```bash
gh extension install github/gh-bbs2gh
```

Verify the installation:

```bash
gh bbs2gh --version
```

---

#### 3️⃣ 🌍 Configure Environment Variables

Set the following environment variables before running any script. See `bbs2gh-env-list.txt` for the complete reference.

**Required for all stages:**

```bash
export GH_PAT=<github-personal-access-token>
export BBS_BASE_URL=http://bitbucket.example.com:7990
export SSH_USER=<ssh-username>
export SSH_PRIVATE_KEY="$(cat ~/.ssh/id_rsa)"   # must be passphrase-free
```

**Bitbucket authentication (choose one):**

```bash
# Option A — PAT (recommended)
export BBS_PAT=<bitbucket-personal-access-token>

# Option B — Basic auth
export BBS_AUTH_TYPE=Basic
export BBS_USERNAME=<bitbucket-username>
export BBS_PASSWORD=<bitbucket-password>
```

**Storage backend (choose one, or omit for GitHub-owned storage):**

```bash
# AWS S3
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_BUCKET_NAME=...
export AWS_REGION=...

# Azure Blob Storage
export AZURE_STORAGE_CONNECTION_STRING=...
```

**Data Residency (optional):**

```bash
export TARGET_API_URL=https://api.tenant.ghe.com   # regional API endpoint
```

---

#### 4️⃣ 🗂️ Prepare `repos.csv`

Edit `repos.csv` to define the repositories to migrate. The required columns are:

| Column | Description |
|--------|-------------|
| `project-key` | Bitbucket project key (e.g., `MYPROJ`) |
| `project-name` | Bitbucket project display name |
| `repo` | Bitbucket repository slug |
| `github_org` | Target GitHub organization |
| `github_repo` | Target GitHub repository name |
| `gh_repo_visibility` | `private`, `internal`, or `public` |

**Example `repos.csv`:**
```csv
project-key,project-name,repo,github_org,github_repo,gh_repo_visibility
MYPROJ,My Project,my-repo,my-github-org,my-repo-migrated,private
PLATFORM,Platform Team,api-service,my-github-org,platform-api,private
```

> **💡 Tip:** For a first run, start with one or two non-critical repositories to validate your environment before migrating the full inventory.

---

## 🚀 Quick Start

**Before you begin**, ensure you've completed the [Initial Setup](#-initial-setup):
- ✅ GitHub CLI authenticated and `gh bbs2gh` extension installed
- ✅ All required environment variables exported
- ✅ `repos.csv` prepared with at least one repository

---

#### 1️⃣ **Make scripts executable** (Linux / macOS)
```bash
chmod +x scripts/*.sh
```

#### 2️⃣ **Run Stage 0 — Prechecks**
```bash
./scripts/0_prechecks.sh -c repos.csv
```

Review the output report and resolve any flagged open PRs before continuing:

| Stage | Output File | What to Check |
|-------|-------------|---------------|
| **Stage 0: Prechecks** | `bbs_pr_validation_output-<timestamp>.csv` | ✅ No `OPEN_PRS` warnings remain |

#### 3️⃣ **Run Stage 1 — Migration**
```bash
./scripts/1_migration.sh --csv repos.csv --max-concurrent 5
```

Monitor the live status bar and verify the output:

| Stage | Output File | What to Check |
|-------|-------------|---------------|
| **Stage 1: Migration** | `repo_migration_output-<timestamp>.csv` | ✅ All repositories show `MIGRATED` |

#### 4️⃣ **Run Stage 2 — Validation**
```bash
./scripts/2_validation.sh -c repos.csv
```

Review the validation report:

| Stage | Output File | What to Check |
|-------|-------------|---------------|
| **Stage 2: Validation** | `validation-summary.md` | ✅ All entries show `✅ Matching` for branches, commits, and SHAs |

---

### Windows (PowerShell)

```powershell
# Stage 0 — Prechecks
pwsh misc/0_prechecks.ps1 -c repos.csv

# Stage 1 — Migration
pwsh misc/1_migration.ps1 --csv repos.csv --max-concurrent 5

# Stage 2 — Validation
pwsh misc/2_validation.ps1 -c repos.csv
```

### Azure Pipelines

A ready-to-use pipeline definition is available at `samples/ado2gh-migration.yml`. Configure a variable group named `core-entauto-github-migration-secrets` containing your `GH_PAT` and Bitbucket credentials, then import the YAML into your Azure DevOps project.

---

## 📎 Artifacts and References

After all three stages complete successfully, confirm the following checklist before decommissioning Bitbucket repositories.

- [ ] **Stage 0 output** — No `OPEN_PRS` warnings remain (or you have acknowledged the loss of open PRs).
- [ ] **Stage 1 output** — All repositories in `repo_migration_output-<timestamp>.csv` show `MIGRATED`.
- [ ] **Stage 2 output** — All entries in `validation-summary.md` show `✅ Matching` for branches, commit counts, and latest SHAs.
- [ ] **GitHub repository settings** — Confirm visibility, branch protection rules, and team access are correctly configured.
- [ ] **CI/CD pipelines** — Update pipeline configurations to point to the new GitHub repository URLs.
- [ ] **Webhooks and integrations** — Reconfigure Bitbucket webhooks, Jira integrations, or any notification services.
- [ ] **Developer workstations** — Notify developers of the new remote URLs and provide instructions to update local clones:

  ```bash
  git remote set-url origin https://github.com/<org>/<repo>.git
  ```

### Output Artifacts Reference

| File | Stage | Description |
|------|-------|-------------|
| `bbs_pr_validation_output-<timestamp>.csv` | 0 | Per-repository open PR counts and migration readiness |
| `repo_migration_output-<timestamp>.csv` | 1 | Per-repository migration status (`MIGRATED` / `FAILED`) |
| `validation-log-<timestamp>.txt` | 2 | Full verbose validation log |
| `validation-summary.csv` | 2 | Machine-readable per-repository validation results |
| `validation-summary.md` | 2 | Human-readable Markdown validation report |

**Next Steps:**
- **More repositories?** Update `repos.csv` and rerun the pipeline from Stage 0
- **Partial failures?** Fix the root cause, remove successfully migrated repos from `repos.csv`, and rerun Stage 1 for remaining repos

> **💡 Tip:** Once all checks pass and teams are working from GitHub, decommission or archive Bitbucket repositories following your organization's retention policy.
