# bbs-to-gh-migration (combined)

A single GitHub Actions workflow that:
1) runs a **PR-only readiness check** on Bitbucket repos,
2) **waits for manual approval** via a GitHub Issue–based prompt, and
3) executes **migration** followed by **post‑migration validation**.

This combines the logic from your previous workflows and scripts.  
_Original sources_: `0-pr-pipeline-check.yml`, `1-migration.yml`, `2-migration-validation-bbs.yml`. citeturn1search1turn1search3turn1search2

---

## Prerequisites

- Repo contains the PowerShell scripts:
  - `./scripts/0_pr_pipeline_check.ps1` (PR readiness) citeturn1search1
  - `./scripts/1_migration.ps1` (migration execution) citeturn1search3
  - `./scripts/2_migration_validation_bbs.ps1` (post‑migration validation) citeturn1search2
- Workflow file path: `.github/workflows/bbs-to-gh-migration.yml` (this combined pipeline).

## Required GitHub Secrets

Set in **Settings → Secrets and variables → Actions**:

- `GH_PAT` — GitHub PAT used by `gh` and validation/migration steps. citeturn1search3turn1search2
- Bitbucket auth (choose one):
  - `BBS_PAT` **or** (`BBS_USERNAME`, `BBS_PASSWORD`) — used by readiness & migration. citeturn1search1turn1search3
- (Optional, if used by validation): `BBS_TOKEN`, `BBS_AUTH_TYPE`. citeturn1search2
- (Optional, if your migration uses SSH): `SSH_USER`, `SSH_PRIVATE_KEY`. citeturn1search3

> The workflow grants `contents: read`, `actions: write`, and `issues: write` permissions; `issues: write` is required for the manual approval step.

## Inputs (Run workflow)

- `csv_path` (string, required): Path to repositories CSV (e.g., `repos.csv`). citeturn1search1turn1search3turn1search2
- `bbs_base_url` (string, required): Bitbucket Server/DC base URL. citeturn1search1turn1search3
- `max_concurrent` (choice, default `5`): Concurrent migrations for `1_migration.ps1`. citeturn1search3
- `gh_host` (optional): GHES hostname if applicable (used in validation). citeturn1search2

## Configure Approvers (mandatory)

The workflow pauses in the **approval-gate** job using `trstringer/manual-approval@v1`.  
Update the `approvers:` list with **real GitHub usernames and/or team slugs** (e.g., `org/team-slug`).

```yaml
# .github/workflows/bbs-to-gh-migration.yml (excerpt)
- name: Wait for manual approval
  uses: trstringer/manual-approval@v1
  with:
    secret: ${{ github.token }}
    approvers: yashtnaik, org-name/team-slug   # ← replace with real identities
    minimum-approvals: 1
    issue-title: "Approve migration to GitHub"
    issue-body: |
      Please review the PR readiness summary in the previous job.
      Comment **approved** to proceed, or **deny** to stop.
    exclude-workflow-initiator-as-approver: false
    fail-on-denial: true
    polling-interval-seconds: 30
```

## How to Run & Approve

1. Go to **Actions → bbs-to-gh-migration (combined) → Run workflow** and provide inputs.  
2. The run will pause at **Manual Approval to Proceed** and create an **Issue** assigning approvers.  
3. Approver comments one of `approve`, `approved`, `lgtm`, or `yes` → workflow continues.  
   Comment `deny`, `denied`, or `no` → workflow stops.

## What Each Job Does

- **readiness-check**: Runs PR-only readiness; open PRs are treated as **warnings**, not blockers. Produces `bbs_pipeline_validation_output-*.csv` and a summary. citeturn1search1
- **approval-gate**: Opens the approval Issue and waits for approver comment (no Enterprise required).
- **migrate-repositories**: Installs `gh` + `gh-bbs2gh`, validates CSV, runs concurrent migrations; uploads logs and `repo_migration_output-*.csv`, writes a migration summary. citeturn1search3
- **validate-migrations**: Validates migrated repos and appends a table-only summary; uploads validation artifacts. citeturn1search2

## Artifacts

- `bbs-pr-check-<runNumber>` → `bbs_pipeline_validation_output-*.csv`. citeturn1search1
- `migration-logs-<runId>` → `migration-*.txt`, `*.log`, `repo_migration_output-*.csv`. citeturn1search3
- `validation-results-bbs-<runNumber>` → `validation-*.txt`, `validation-*.json`, `validation-summary.*`. citeturn1search2

## Troubleshooting

- **Approval issue failed to create**: Ensure all `approvers` are valid/assignable in this repo/org.
- **CSV validation failed**: Check required columns. Migration requires `project-key, project-name, repo, github_org, github_repo, gh_repo_visibility`. citeturn1search3  
  Validation requires `project-key, repo, url, github_org, github_repo`. citeturn1search2
- **Bitbucket auth errors**: Provide `BBS_PAT` or `BBS_USERNAME/BBS_PASSWORD` and verify `bbs_base_url`. citeturn1search1

---

**Tip:** If you later move to GitHub Enterprise and want a native approval banner, you can swap the issue-based approval for an **environment with required reviewers** and bind the migration job to that environment.
