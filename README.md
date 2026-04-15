# HCP Terraform Learning Notes

Notes from a hands-on investigation into HCP Terraform (formerly Terraform Cloud).

The starting point is familiarity with running Terraform locally — these notes focus on what changes and what stays the same when moving to HCP Terraform.

---

## The Mental Shift

When running Terraform locally, you own the full execution environment:

| Concern | Local Terraform | HCP Terraform |
|---|---|---|
| Where state lives | Local file / S3 / GCS | HCP Terraform (managed) |
| Where plan/apply runs | Your laptop or CI runner | HCP Terraform's infrastructure |
| State locking | DynamoDB / GCS native | Built-in |
| Secrets / variables | `TF_VAR_*`, `.tfvars` files | Workspace variables (encrypted at rest) |
| Who can apply | Anyone with cloud credentials | Controlled via team permissions |
| Triggering runs | `terraform apply` in terminal | VCS push, API call, or UI |

The biggest shift: **your laptop is no longer the execution environment**. You push code or call an API, and HCP Terraform runs the plan/apply on its own managed infrastructure.

Your `.tf` files change very little — mostly a `backend` block change and moving credentials into workspace variables. The logic, resources, and modules stay the same.

---

## Hierarchy: Organization, Project, Workspace

HCP Terraform has three levels:

**Organization** — the top level, corresponding to a company or team. All billing, SSO, and org-wide settings live here.

**Project** — a grouping of workspaces within an org, used to organize workspaces and apply permissions at a higher level. Every org gets a Default project automatically. For a real team setup you would create a dedicated project per product, e.g. `managed-gke-clusters`.

**Workspace** — the core unit of work. Each workspace has its own state file, variables, run history, and permissions. In practice, teams typically create one workspace per environment:

```
Organization: my-org
└── Project: managed-gke-clusters
    ├── Workspace: dev
    ├── Workspace: staging
    └── Workspace: prod
```

Note: workspace names are unique within an organization, so specifying org + workspace name is sufficient to identify a workspace — the project does not need to be specified in the Terraform configuration.

---

## Connecting a Terraform Configuration to HCP Terraform

Add a `cloud` block to the `terraform` block in your configuration:

```hcl
terraform {
  required_version = "~> 1.14.8"

  cloud {
    organization = "my-org"

    workspaces {
      name = "my-workspace"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.28"
    }
  }
}
```

The `cloud` block is the modern replacement for the older `backend "remote"` block. You may still see `backend "remote"` in older configurations and documentation.

Authenticate the CLI before running `terraform init`:

```bash
terraform login
```

This opens a browser to generate a token, which is saved to `~/.terraform.d/credentials.tfrc.json`.

Running `terraform init` after adding the `cloud` block will detect any existing local state and offer to migrate it to HCP Terraform automatically.

---

## Workspace Workflow Types

When creating a workspace, HCP Terraform offers three workflow types:

**CLI-driven** — runs are triggered from your terminal with `terraform plan` and `terraform apply`. Execution happens remotely on HCP Terraform's infrastructure, but you initiate it.

**VCS-driven** — a GitHub/GitLab repo is connected to the workspace. Pushes to the configured branch trigger runs automatically. Pull requests trigger speculative plans only.

**API-driven** — runs are triggered programmatically via the HCP Terraform API. Used for advanced CI/CD pipelines.

You can migrate a workspace from CLI-driven to VCS-driven at any time via **Workspace → Settings → Version Control** without affecting state.

---

## GCP Credentials in HCP Terraform

Because `terraform plan` and `terraform apply` run on HCP Terraform's infrastructure — not your laptop — your local `gcloud` application default credentials are not available. You must explicitly provide credentials to the workspace.

**Options in order of preference:**

1. **Dynamic Provider Credentials** — HCP Terraform's first-class feature built on Workload Identity Federation (WIF). HCP Terraform generates a short-lived OIDC token per run; GCP exchanges it for a short-lived access token. No long-lived secret ever exists. Requires a paid HCP Terraform tier.

2. **Workload Identity Federation (manual)** — Configure a WIF Pool and Provider in GCP to trust HCP Terraform's OIDC identity provider. Set a few non-sensitive environment variables in the workspace. Works on any tier.

3. **JSON service account key** — Set the key contents as a sensitive `GOOGLE_CREDENTIALS` environment variable in the workspace. Acceptable for experimentation only.

> **Note:** Long-lived JSON service account keys are a security risk due to potential leakage. WIF or Dynamic Provider Credentials should be the approach used for production workspaces. Credential strategy should be resolved early in migration planning.

When adding a JSON key as a workspace variable, the value must be compacted to a single line first:

```bash
jq -c . key.json | pbcopy
```

---

## Remote Execution: What Runs Where

This is one of the most important things to understand when moving to HCP Terraform. Commands fall into two categories:

**Run remotely on HCP Terraform's infrastructure:**
- `terraform plan`
- `terraform apply`

**Run locally but operate against remote state:**
- `terraform state mv`
- `terraform state rm`
- `terraform state pull` / `terraform state push`
- `terraform import`
- `terraform show`
- `terraform output`
- `terraform state list`

State manipulation commands bypass the remote run lifecycle entirely. They download the state from HCP Terraform, make changes locally, and push the updated state back. This has two practical consequences:

- They appear in the workspace **States** tab as a new state version but do NOT appear in the **Runs** tab
- They use your local HCP Terraform token, not the workspace's cloud credentials — this is why `terraform state mv` works without GCP credentials

**Why is `terraform apply` blocked locally but `terraform state mv` allowed?**

The restriction on `terraform apply` is deliberate policy enforcement by HCP Terraform, not a consequence of who owns the state. In a VCS-driven workspace, blocking local applies ensures all infrastructure changes go through the VCS pipeline, maintaining a consistent audit trail and enforcing the PR review process.

State manipulation commands are a deliberate exception — there is no VCS-driven equivalent of renaming a resource address in state. HashiCorp intentionally allows these as an administrative escape hatch.

---

## The VCS-Driven Workflow in Practice

Once a workspace is connected to a GitHub repo, the workflow is:

**Pull request** → HCP Terraform runs a speculative plan and posts the result as a GitHub status check. Plan only — no apply, no confirmation required. Gives reviewers visibility into infrastructure impact before approving.

**Merge to `main`** → HCP Terraform triggers a full run. With **Auto apply** enabled, this plans and applies automatically. With Manual apply (the default), it waits for confirmation in the UI.

> **Recommendation:** Enable GitHub branch protection on `main` when using VCS-driven workflow with auto apply. Without it, anyone with push access can bypass the PR review and speculative plan, pushing directly to `main` and triggering an automatic apply.

---

## Safely Reorganizing Terraform Configurations

Renaming a resource in code — e.g. from `google_storage_bucket.this` to `google_storage_bucket.that` — without updating state causes Terraform to plan a destroy of the old resource and a create of the new one, even though nothing about the real infrastructure has changed.

The fix is `terraform state mv`, which updates the resource address in state without touching real infrastructure:

```bash
terraform state mv google_storage_bucket.this google_storage_bucket.that
```

Under a VCS-driven workflow the order of operations matters:

1. **State first** — run `terraform state mv` locally against the remote state
2. **Code second** — rename the resource in the `.tf` file, commit, and push

If you do it in the wrong order, the VCS push triggers an apply before the state is updated, and Terraform will attempt to destroy and recreate the resource.

---

## `.gitignore` for Terraform

```gitignore
# Local state files
terraform.tfstate
terraform.tfstate.backup
terraform.tfstate.*.backup

# Local variable files (may contain secrets)
*.tfvars
*.tfvars.json

# Terraform working directory
.terraform/

# Crash log files
crash.log
crash.*.log

# Sensitive files
*.pem
*.key
override.tf
override.tf.json
*_override.tf
*_override.tf.json
```

Note: `.terraform.lock.hcl` is intentionally **not** ignored. This lock file pins provider versions and should be committed so all team members get consistent provider versions.

---

## Topics Not Covered — For Further Investigation

The following HCP Terraform concepts were not covered in this session but are worth exploring:

- **Variable sets** — define variables once at org or project level and share across multiple workspaces. Relevant if multiple workspaces need the same credentials.
- **Private Registry** — hosting private Terraform modules within the org. Relevant if publishing reusable modules.
- **Sentinel / OPA policies** — policy-as-code enforcement between plan and apply, e.g. enforcing labelling standards or restricting resource types. A paid tier feature.
- **Run triggers** — automatically trigger a run in one workspace when another completes. Useful for workspaces with infrastructure dependencies.
- **Agents** — self-hosted HCP Terraform runners for accessing private networks, e.g. private GKE clusters.
