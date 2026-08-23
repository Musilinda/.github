# bootstrap — the one-time CI/CD foundation (you apply this locally, once)

Chicken-and-egg: GitHub Actions can't create its own auth + state store before they
exist. So this small config — **applied once, locally, by you** — creates:

- **S3 bucket** for terraform state (the main `deploy/terraform` uses it as its backend)
- **GitHub OIDC provider** + a **least-privilege role** Actions assumes (Lightsail + the
  state bucket only), scoped to **dev/main of your org repos** (PR branches can't deploy)

This is the **only** local `terraform apply` in the whole setup. Uses local state
(`bootstrap.tfstate`) — it rarely changes, so that's fine.

## Apply (once)
```bash
cd deploy/terraform/bootstrap
terraform init
terraform plan     # review — creates S3 bucket + OIDC provider + role/policy
terraform apply    # type yes
terraform output   # note state_bucket + gha_role_arn
```

Then give me the two outputs (`state_bucket`, `gha_role_arn`) and I'll wire the main
terraform's S3 backend + the M5 workflow to them.

## Decisions to check before applying
- **`state_bucket_name`** (default `musilinda-tfstate`) — S3 names are **globally unique**;
  if it's taken, set `-var=state_bucket_name=musilinda-tfstate-<something>`.
- **`allowed_subjects`** — defaults to any `Musilinda/*` repo on `dev`/`main`. Tighten to a
  specific repo if you want (e.g. only the infra repo).
- Region defaults to `us-east-1`.

Note: `bootstrap.tfstate` stays **local** and is gitignored — don't commit it.
