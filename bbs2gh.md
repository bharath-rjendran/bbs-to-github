# Migration Strategy: bbs2gh

The `bbs2gh` migration strategy is the **recommended approach** for migrating repositories from Bitbucket Data Center to GitHub Enterprise Cloud (GHEC), GitHub Enterprise Cloud with EMU (GHEC+EMU), or GitHub Enterprise Cloud with Data Residency (GHEC+DR) using the latest `bbs2gh` tool.

> **✅ Recommended Choice**: This is the preferred migration strategy for new Bitbucket Data Center migrations, offering improved performance and direct upload capabilities.

> **⚠️ Beta Feature**: This migration strategy uses a beta feature of the GEI `bbs2gh` tool that allows direct uploads to GitHub Enterprise Cloud without intermediate storage. Ensure proper feature flags are enabled before use.

## Key Benefits

- **🚀 Direct Upload**: No intermediate storage required, faster transfers
- **⚡ Better Performance**: Optimized for large-scale enterprise migrations
- **🔄 Latest Features**: Access to newest migration capabilities and improvements
- **🛡️ Enterprise Ready**: Full support for GitHub Enterprise Cloud features

## Quick Start

1. **Configure** variables and secrets (see tables below)
2. **Enable** beta feature flags with GitHub Support
3. **Run** Configuration Settings workflow to apply changes
4. **Submit** migration batch using workflows.

## Configuration Requirements

The following variables and secrets are required for the `bbs2gh` migration strategy. Manually add secrets to the repository secrets.

> **⚙️ Important**: Configure the secrets and variable before running the migration workflows.

### Required Variables

| Variable Name                     | Description                                                                                                         | Example                                            |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| `BITBUCKET_SERVER_URL`            | The URL of the Bitbucket Data Center instance(optional)                                                                       | `https://bitbucket.example.com`                    |
| `BITBUCKET_SHARED_HOME`           | The shared home directory on the Bitbucket Data Center instance(optional)                                                     | `/var/atlassian/application-data/bitbucket/shared` |

### Required Secrets

| Secret Name          | Description                                                                                                         | Example                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `BBS_PASSWORD`       | The password of the Bitbucket Data Center user that will be used to authenticate with the Bitbucket Data Center API for generating Inventory | `bitbucket_pass`                                                      |
| `SSH_PRIVATE_KEY`  | The SSH private key that will be used to download the Bitbucket Data Center archive files and will be uploaded to github(--use-github-storage)                           | `-----BEGIN PRIVATE KEY----- ABUNCHOFSTUFF -----END PRIVATE KEY-----` |
| `GH_PAT` | Required for migration, GH Auth and for API calls during Post Validations.                                                | `GHC_XXXX`                                    |
| `SSH_USER`              | The SSH user that will be used to download the Bitbucket Data Center archive files                                  | `bitbucket`                                        |
| `BBS_TOKEN`              | Required for API call during Post Validations.                                  | `BBSXXXXX`                                             |
| `BBS_USERNAME`              | The username of the Bitbucket Data Center user that will be used to authenticate with the Bitbucket Data Center API | `bitbucket_user`                                   |

> **🔐 Security**: Store all secrets securely in repository settings. Never commit secrets to your repository.

## Migration Workflow Steps

The `bbs2gh` migration strategy consists of the following workflow files executed in sequence:

| Step | Workflow File                 | Purpose                                                    |
| ---- | ----------------------------- | ---------------------------------------------------------- |
|0     | `0-bbs-inventory.yml`         | This workflow generates the Inventory report               |
| 1    | `0-pr-pipeline-check.yml`       | Validates repos pre-migrations to check for any potential blockers(On PR, Build Pipelines, Release Pipelines etc)  |
| 2    | `1-migration.yml`        | Executes the main repository migration using `bbs2gh` tool |
| 3    | `2-migration-validation-bbs.yml` | Verifies migration status and validates results            |
| 4    | `3-mannequins-validation.yml`            | Generates Mannequins report       |
| 5    | `4-mannequins-reclaim.yml`    | Claims the mannequins(initiate the invitation)   |

### Workflow Sequence

```mermaid
flowchart TB
    subgraph Inputs[Inputs]
      BB[Bitbucket DC<br/>URL, Shared Home]
      Auth[Auth & Access<br/>BBS_USERNAME/BBS_PASSWORD/BBS_TOKEN<br/>SSH_USER/SSH_PRIVATE_KEY<br/>GH_PAT]
      Flags[GEI Beta Flags<br/>Direct Upload Enabled]
    end

    subgraph Workflows[Workflows]
      W0[0-bbs-inventory.yml]
      W1[0-pr-pipeline-check.yml]
      W2[1-migration.yml]
      W3[2-migration-validation-bbs.yml]
      W4[3-mannequins-validation.yml]
      W5[4-mannequins-reclaim.yml]
    end

    BB --> W0
    Auth --> W0
    Auth --> W1
    Flags --> W2
    BB --> W2
    Auth --> W2

    W0 --> W1 --> W2 --> W3 --> W4 --> W5

    subgraph Outputs[Outputs]
      Inv[Inventory Report]
      MigRes[Migrated Repositories on GHEC/GHEC+EMU/GHEC+DR]
      Val[Validation Results]
      Man[Mannequins Report & Reclaimed Accounts]
    end

    W0 --> Inv
    W2 --> MigRes
    W3 --> Val
    W4 --> Man
    W5 --> Man
```

> **🛠️ Customization**: Need to modify these workflows? See the **[Customizing Migrations Guide](../Customizing-Migrations.md)** for detailed instructions.

## Prerequisites

### System Requirements

- **Bitbucket Data Center**: Compatible version with API access
- **Network Access**: Connectivity between runners and Bitbucket instance
- **SSH Access**: For archive file downloads
- **GitHub Enterprise**: Feature flags enabled for direct upload

### Required Permissions

- **Bitbucket**: Repository admin access for source repositories
- **GitHub**: Organization owner or admin access for destination
- **SSH**: Key-based authentication to Bitbucket archive storage

## Support and Troubleshooting

### Common Issues

- **Authentication failures**: Verify tokens and SSH keys
- **Network connectivity**: Check firewall and routing
- **Feature flag access**: Contact GitHub Support for beta features
- **Archive download issues**: Validate SSH configuration

> Prerequisites & Security
mindmap
  root((bbs2gh Migration))
    Benefits
      Direct Upload
      Better Performance
      Latest Features
      Enterprise Ready
    Requirements
      Variables
        BITBUCKET_SERVER_URL (optional)
        BITBUCKET_SHARED_HOME (optional)
      Secrets
        BBS_USERNAME
        BBS_PASSWORD
        BBS_TOKEN
        SSH_USER
        SSH_PRIVATE_KEY
        GH_PAT
    Beta Flags
      GEI bbs2gh
      Direct upload to GHEC
    Security
      Store in repo secrets
      Never commit secrets

> Migration Workflow Pipeline
flowchart LR
    subgraph PreChecks[Pre-Migration]
        X0[0-bbs-inventory.yml<br/>Generate Inventory Report]
        X1[0-pr-pipeline-check.yml<br/>Validate PRs, Build/Release Pipelines]
    end

    subgraph Migration[Migration]
        X2[1-migration.yml<br/>Run bbs2gh main migration]
    end

    subgraph Validation[Validation & Mannequins]
        X3[2-migration-validation-bbs.yml<br/>Verify migration status]
        X4[3-mannequins-validation.yml<br/>Generate mannequins report]
        X5[4-mannequins-reclaim.yml<br/>Initiate invitations / reclaim]
    end

    X0 --> X1 --> X2 --> X3 --> X4 --> X5

> Dependencies & Data Flow
flowchart TB
    subgraph Inputs[Inputs]
      BB[Bitbucket DC<br/>URL, Shared Home]
      Auth[Auth & Access<br/>BBS_USERNAME/BBS_PASSWORD/BBS_TOKEN<br/>SSH_USER/SSH_PRIVATE_KEY<br/>GH_PAT]
      Flags[GEI Beta Flags<br/>Direct Upload Enabled]
    end

    subgraph Workflows[Workflows]
      W0[0-bbs-inventory.yml]
      W1[0-pr-pipeline-check.yml]
      W2[1-migration.yml]
      W3[2-migration-validation-bbs.yml]
      W4[3-mannequins-validation.yml]
      W5[4-mannequins-reclaim.yml]
    end

    BB --> W0
    Auth --> W0
    Auth --> W1
    Flags --> W2
    BB --> W2
    Auth --> W2

    W0 --> W1 --> W2 --> W3 --> W4 --> W5

    subgraph Outputs[Outputs]
      Inv[Inventory Report]
      MigRes[Migrated Repositories on GHEC/GHEC+EMU/GHEC+DR]
      Val[Validation Results]
      Man[Mannequins Report & Reclaimed Accounts]
    end

    W0 --> Inv
    W2 --> MigRes
    W3 --> Val
    W4 --> Man
    W5 --> Man