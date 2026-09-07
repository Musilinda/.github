# Prod cutover — Replit → AWS (DNS repoint)

**What this is:** move the production domains from Replit to the AWS prod box. This is a
**DNS/hosting cutover**, NOT a data migration — AWS prod runs on its committed seeds
(blog seed = 20 posts + images; app self-seeds interval lessons + admins). Replit's
database is **not** copied over. (Decision: owner, 2026-09-07.)

**Trust boundary (unchanged):** Claude holds no GitHub/AWS/registrar creds. Every `push`,
`terraform apply`, DNS edit, and approval below is the **human's** to run. Claude prepared
this runbook and verified the repo config; it does not execute cloud/remote steps.

## Current state (verified 2026-09-07)
- Prod DNS today (Replit / Google Cloud): `musilinda.com`, `app.`, `learn.` → `34.111.179.208`.
  `www` has **no** record.
- AWS dev box `34.231.3.91` — healthy, proven end-to-end over HTTPS.
- AWS parked prod box `52.23.49.184` — up (HTTP 200), build parity unverified; the earlier
  prod deploy failed only at the `web` build because `main` lagged `dev`.
- Repo config is already prod-correct — **no code changes needed**:
  - `deploy/terraform/environments/prod.tfvars` → `domain=musilinda.com`, `large_2_0` (8 GB).
  - `bootstrap.sh` nginx `server_name`s: `app.$DOMAIN`, `learn.$DOMAIN` (+`blog.$DOMAIN` alias),
    `$DOMAIN` + `www.$DOMAIN`.
  - `bootstrap.sh setup_tls` auto-issues LE certs for `app.`/`learn.`/apex/`www` (idempotent,
    DNS-gated: skips any name not yet resolving to the box; re-runs every deploy).
  - `VITE_LEARN_URL` built as `https://learn.$DOMAIN`.

## The only real blocker
The last prod deploy failed because `main` was behind `dev` (missing the web build fix +
interval-seed fix). **Promotion is the unblock.** Everything else is DNS + verify.

---

## Runbook (ordered; each step is the human's to run)

### 1. Promote `dev → main` for every deploy repo
`api`, `app_musilinda`, `blog`, `web`, and `.github`. Confirm on the remote that no repo's
`main` lags `dev` after this (that lag is exactly what broke the prior prod run).
```bash
# per repo:
git checkout main && git merge --ff-only origin/dev && git push origin main
```

### 2. Provision/deploy prod via CI
Pushing `main` triggers `.github/workflows/deploy.yml` on the **prod** path (env `prod`,
`musilinda.com`, `large_2_0`), gated on the prod Environment's required reviewer → **approve**.
Jobs: `plan → apply → deploy` (SSH + `bootstrap.sh`: schema via `db:push`, blog seed if empty,
model weights from S3, TLS re-run).
- **Recommend: redeploy onto the existing box** (idempotent; the only prior failure is fixed by
  step 1) rather than destroy/recreate.
- After it's green, capture the prod IP: `terraform output static_ip` (expected `52.23.49.184`)
  — this is the DNS target.

### 3. Lower TTL now (before flipping) — GoDaddy
In GoDaddy DNS for `musilinda.com`, set TTL on the `@` / `www` / `app` / `learn` A records to
the minimum (600s; GoDaddy's floor) and **wait out the previous TTL**. This is what makes
rollback fast. (Claude will prompt you here — this is the "update GoDaddy" step.)

### 4. Verify AWS prod on the IP (Replit still live — zero user impact)
```bash
curl -H 'Host: app.musilinda.com'   http://52.23.49.184/    # learning app
curl -H 'Host: learn.musilinda.com' http://52.23.49.184/    # blog (20 posts)
curl -H 'Host: musilinda.com'       http://52.23.49.184/    # marketing site
```

### 5. Flip DNS — GoDaddy A records
Set these in GoDaddy (Type A; value = confirmed prod IP, expected `52.23.49.184`):

| Type | Name (Host) | Value          | Notes                     |
| ---- | ----------- | -------------- | ------------------------- |
| A    | `@`         | `52.23.49.184` | apex `musilinda.com`      |
| A    | `www`       | `52.23.49.184` | new — Replit never had it |
| A    | `app`       | `52.23.49.184` | learning app              |
| A    | `learn`     | `52.23.49.184` | blog CMS                  |

**Leave Replit running** as warm rollback.

### 6. Issue TLS
Once DNS resolves to the box, **re-run the deploy** (or `ssh` in and run bootstrap's
`setup_tls`). certbot issues LE certs for the four names that now resolve. Brief HTTP-only
window during issuance.

### 7. Verify HTTPS end-to-end (mirror dev's "milestone prime")
- `https://app.musilinda.com`: create account, sing an interval, `/api/analyze` scores it.
- `https://learn.musilinda.com`: 20 posts render with images.
- Admin logins work on both app and blog.
- apex + `www` → marketing site over HTTPS.

### 8. Soak, then decommission Replit
Keep Replit as rollback for a day or two. When prod is clean, retire the Replit deployment.

---

## Rollback
Revert the four A records to `34.111.179.208` (Replit). Instant once TTL is low. Replit
keeps serving throughout the soak, so a flip-back is a pure DNS change — no rebuild.

## Known post-cutover polish (non-blocking)
- Cross-service blog/app links may still point at the dev host — fix env-driven off `$DOMAIN`
  (deferred item in MILESTONES.md).
- Add `www` A record (new on AWS; Replit didn't serve it).
