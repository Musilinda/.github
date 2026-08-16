# deploy/terraform — Lightsail box as code

Provisions the single Musilinda box per environment: an `aws_lightsail_instance`
(Ubuntu 24.04, size per env), a static IP, and a firewall that opens **only 22/80/443**
(Flask 5000 + node 5001/5002 stay localhost-only). `user_data` runs `bootstrap.sh`.

**One config, per-env var sets** (matches the dev→main promotion model):
| Env | var file | box | domain |
|-----|----------|-----|--------|
| dev  | `environments/dev.tfvars`  | 4 GB (`medium_2_0`) | `dev.musilinda.com` |
| prod | `environments/prod.tfvars` | 8 GB (`large_2_0`)  | `musilinda.com` |

## Dry run (M3 — local, no AWS, no cost)
```bash
cd deploy/terraform
terraform init
terraform validate
terraform plan -var-file=environments/dev.tfvars -var=dry_run=true
```
`dry_run=true` lets `plan` run offline (no live creds). Review the plan — it should show
the instance + static IP + attachment + public ports, and nothing else.

## Real apply (M4 — costs money; a human runs this)
1. AWS creds active (`aws sts get-caller-identity` works).
2. `terraform plan  -var-file=environments/prod.tfvars`  ← review
3. `terraform apply -var-file=environments/prod.tfvars`
4. Point DNS (`app./learn./www.$domain`) at the `static_ip` output.

State is local for the PoC (`*.tfstate` is gitignored). Teardown: `terraform destroy -var-file=...`.
