# CI/CD pipeline (GitHub Actions)

Two-stage pipeline for the serverless Customer Management Platform.

| Stage | Trigger | Stack base name | Gate |
|-------|---------|-----------------|------|
| `dev`  | every push + PR (any branch) | `workshop-dev`  | none (auto) |
| `prod` | push to `main` only | `workshop-prod` | protected Environment `prod` (manual approval) |

- **Auth:** GitHub OIDC -> AWS IAM role (no stored keys).
- **Region:** us-west-2 (both stages).
- **State:** local backend, persisted per stage as a GitHub Actions artifact
  (`terraform-state-dev` / `terraform-state-prod`), downloaded at job start and
  uploaded at job end. A per-stage `concurrency` group serializes runs.
  Artifacts are not durable or lockable — workshop-grade, not production-grade.

## One-time setup (do these before the first run)

1. **Bootstrap the OIDC provider + deploy role** (from your machine, once):
   ```bash
   cd infrastructure/bootstrap
   terraform init
   terraform apply        # creates the GitHub OIDC provider + deploy role
   terraform output deploy_role_arn
   ```
   (If an OIDC provider for GitHub already exists in the account, run with
   `-var create_oidc_provider=false`.)

2. **Add the role ARN as a repo variable** named `AWS_DEPLOY_ROLE_ARN`
   (Settings -> Secrets and variables -> Actions -> Variables), value = the
   `deploy_role_arn` output above. Expected:
   `arn:aws:iam::949301320739:role/workshop-github-actions-deploy`

3. **Create the protected `prod` environment** (Settings -> Environments ->
   New environment -> `prod`), and add yourself under **Required reviewers**.
   This is the manual-approval gate for prod. (A `dev` environment is optional;
   the workflow references it but it needs no protection rules.)

After that, push to any branch to trigger `dev`; push to `main` to trigger
`dev` then `prod` (prod waits for your approval).
