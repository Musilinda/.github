# Deploy PoC → CI/CD — Milestones (source of truth)

**Branch:** `claude/deploy-poc` (off `main`). All deploy-PoC work lives on this branch and
under `deploy/`. This file is the single source of truth for **where we are**. It is updated
after every milestone with ✅/❌ per acceptance criterion + evidence, **before** stopping for
confirmation. A fresh session should read this file first to resume exactly where the last
one stopped.

Governs / sits beside: `deploy/bootstrap.sh`, `deploy/terraform/`, `deploy/RUNBOOK.md`,
`.github/workflows/deploy.yml` (created as milestones land). Platform-wide context lives in
root `CLAUDE.md` and `ARCHITECTURAL_LANDSCAPE.md` — this doc governs the deploy workstream only.

---

## Rules of engagement (Prompt 0)

- **Branch isolation:** all work on `claude/deploy-poc`. **Never touch `main`.**
- **No remote ops by Claude:** Claude has **no GitHub or AWS credentials** and will never
  `push`, `pull`, or call `gh`. Local commits to the branch are allowed as milestones
  complete. The human does **all** pushes, applies, and remote operations by hand.
- **Milestone discipline:** one milestone at a time. At the end of each, Claude verifies the
  acceptance criteria itself, shows the evidence (real command output), updates this file,
  and **STOPS for confirmation** before starting the next. Do not run ahead.
- **Secrets:** real secret values are the human's; never echoed. Templates are committed,
  real secret/tfvars files are gitignored.

**Trust boundary:** branch isolation + no creds ⇒ Claude edits and verifies locally; the
human performs every push and every cloud `apply`.

## Why this doc lives in `deploy/` (rationale)

- Root docs (`ARCHITECTURAL_LANDSCAPE.md`, `CLAUDE.md`) describe the **whole platform** and
  are permanent. This doc governs **one workstream**, so it lives with the work.
- It is **born on the branch** with the work it tracks, evolves if the PoC direction changes,
  and merges together with the thing it documents.
- Living where the work happens keeps it updated, and it **survives session restarts** — the
  durable checklist a fresh Claude session reads to pick up mid-stream.

---

## Status legend

⬜ not started · 🔄 in progress · ✅ pass · ❌ fail · ⏸️ blocked (needs human)

## Milestone map

| # | Milestone | Gate | Status |
|---|---|---|---|
| 0 | Setup & rules of engagement | branch + this doc | 🔄 |
| 1 | `deploy/bootstrap.sh` (the deploy IS this script) | no VM/AWS | ⬜ |
| 2 | Local proof in a Multipass VM | on the Mac | ⬜ |
| 3 | Terraform wrap (dry — plan only, no apply) | local | ⬜ |
| 4 | The real click — live AWS apply + verify | human applies | ⬜ |
| 5 | CI/CD — GitHub Actions workflow | human triggers | ⬜ |

---

## Reconciliation notes vs `CLAUDE.md` (fold into the milestones)

The cloud plan asked to reconcile against the two root MDs before starting. Corrections that
carry into the work below:

1. **"All four services under systemd" → three long-running services.** `api` (gunicorn),
   `app_musilinda` (Express), and `blog` (Express) get systemd units. **`web` is a static
   Vite build served directly by nginx — no systemd unit.** Bootstrap builds `web` to static
   files and points an nginx root at them.
2. **Postgres data timing.** For the PoC, bootstrap creates the two DBs (`musilinda`, `blog`)
   and applies **schema via Drizzle migrations** (`db:push`) — possibly with seed/empty data.
   **Real production data arrives only at cutover via fresh Replit dumps** (per `CLAUDE.md`),
   not inside the PoC.
3. **Flask gunicorn `--workers 1`.** torch is ~1.2 GB per worker; a second worker doubles it
   for no benefit here. Bootstrap's systemd unit uses one worker, bound to `127.0.0.1:5000`.
4. **Ports / routing** (per `CLAUDE.md`): `app.musilinda.com`→`127.0.0.1:5001`,
   `blog.musilinda.com`→`127.0.0.1:5002`, apex+`www.musilinda.com`→static `web`. Flask
   `127.0.0.1:5000` reached only via `app_musilinda`'s `AUDIO_API_BASE_URL` proxy.
5. **Blob storage** is the local filesystem (`blog/server/blob-storage.ts`, `BLOB_STORAGE_DIR`)
   — already implemented on this branch's blog changes; no Azurite/Azure on the box.

### Open decision flagged by the cloud plan

- **Milestone 2 RAM:** Multipass runs on the Mac and the VM must load Whisper (~real RAM,
  ≈8 GB free needed while running). **If the Mac is tight, decide to make the Flask model
  load lazy/optional for the local proof** (health check + proxy path still exercised, heavy
  inference deferred). Human to confirm at M2. → `[ ] decision pending`

---

## Milestone 0 — Setup & rules of engagement 🔄

**Deliverable:** branch created off `main`; `deploy/MILESTONES.md` established as source of
truth; rules understood and recorded.

**Acceptance criteria**
- [x] Branch `claude/deploy-poc` created off `main`, currently checked out.
- [x] `deploy/MILESTONES.md` written (this file) with the 5-milestone plan, acceptance
      criteria, and rationale.
- [x] Rules of engagement recorded (branch isolation, no creds/remote ops, milestone stops).
- [ ] Human confirms setup before Milestone 1 begins.

**Evidence:** `git branch --show-current` → `claude/deploy-poc`. This file committed locally
to the branch.

**Status:** 🔄 awaiting human confirmation. **STOP here.**

---

## Milestone 1 — `deploy/bootstrap.sh` ⬜

**Scope:** one idempotent script that takes a clean **Ubuntu 24.04** host to a fully running
stack — system deps; nginx (subdomain routing per note 4); Postgres with both DBs + Drizzle
migrations (note 2); the three services built and running under systemd + static `web` served
by nginx (note 1); blog `BLOB_STORAGE_DIR` wired; Flask on `127.0.0.1` only, `--workers 1`
(note 3). Config/secrets from **one** env file: `deploy/secrets.env` (gitignored), with
`deploy/secrets.env.example` committed as template. Include `deploy/fetch-artifacts.sh` stub
for the gitignored model files (`whisper_model/model.safetensors`, `whisper_multihead_model.pt`)
— document options, pick the simplest.

**Acceptance criteria**
- [ ] Script is **idempotent** (safe to re-run; no duplicate/broken state).
- [ ] **shellcheck-clean**.
- [ ] Every long-running service has a **systemd unit** (api, app_musilinda, blog).
- [ ] Section-by-section walkthrough delivered to the human.
- [ ] No VM, no AWS invoked in this milestone.

**Evidence:** _(to fill: shellcheck output, unit file list, walkthrough)_

**Status:** ⬜ not started.

---

## Milestone 2 — Local proof in a Multipass VM ⬜

**Scope:** prove `bootstrap.sh` in a local **Multipass Ubuntu 24.04** VM. Claude provides the
exact multipass install + launch commands (human runs them), then drives the deploy inside
the VM.

**Acceptance criteria — each shown with real output**
- [ ] (1) `bootstrap.sh` completes **exit 0** on a fresh VM.
- [ ] (2) All systemd services **active**.
- [ ] (3) `curl` checks pass for each service **through nginx** using `Host:` headers for
      `app.` / `blog.` / `www.musilinda.com`.
- [ ] (4) Blog file upload **lands in `BLOB_STORAGE_DIR`** and is served back.
- [ ] (5) Flask API **unreachable from outside** the VM; **reachable via** app_musilinda's proxy.
- [ ] (6) Re-running `bootstrap.sh` **changes nothing and breaks nothing**.
- [ ] Pass/fail table against all six presented.

**Evidence:** _(to fill: six-row pass/fail table with command output)_

**Status:** ⬜ not started. Depends on M1. See RAM open decision above.

---

## Milestone 3 — Terraform wrap (dry) ⬜

**Scope:** `deploy/terraform/` — `aws_lightsail_instance` (Ubuntu 24.04, 8 GB plan), static
IP, `user_data` that runs `bootstrap.sh`, secrets from gitignored `terraform.tfvars`
(template committed). Output instance IP on apply. PoC teardown expected (`prevent_destroy`
off).

**Acceptance criteria**
- [ ] `terraform init` + `validate` + `plan` succeed locally with **dummy tfvars**.
- [ ] Plan output shows **exactly** the expected resources.
- [ ] `deploy/README.md` documents the click: fill tfvars → `terraform apply` → site up.
- [ ] **No apply** — human reviews the plan first.

**Evidence:** _(to fill: init/validate/plan output, resource summary)_

**Status:** ⬜ not started. Depends on M2.

---

## Milestone 4 — The real click (live AWS) ⬜

**Scope:** human has reviewed the plan and set real tfvars + AWS creds in their shell (creds
are theirs, never echoed). Human runs `terraform apply`; Claude interprets output and drives
verification against the live IP — the same six checks as M2, adapted for remote.

**Acceptance criteria**
- [ ] `apply` **exit 0**.
- [ ] All **six checks** pass against the AWS box.
- [ ] `terraform destroy` + re-apply **reproduces** it (proves turnkey).
- [ ] `deploy/RUNBOOK.md` written capturing the whole flow.

**Evidence:** _(to fill: apply output interpretation, six checks, destroy/re-apply proof)_

**Status:** ⬜ not started. Depends on M3. Human drives `apply`/`destroy`.

---

## Milestone 5 — CI/CD ⬜

**Scope:** `.github/workflows/deploy.yml` — on `workflow_dispatch` (manual): `terraform plan`
on PR, `apply` on approval, using **GitHub-side secrets** (Claude documents required secret
names; never sees values). Include a smoke-test job running the curl checks post-deploy.

**Acceptance criteria**
- [ ] Workflow YAML passes **actionlint**.
- [ ] `deploy/README.md` documents required **secret names** + how the human triggers it.
- [ ] Dry-run explanation of each job delivered.
- [ ] Human pushes and runs it from GitHub (Claude does not).

**Evidence:** _(to fill: actionlint output, secret-name list, per-job explanation)_

**Status:** ⬜ not started. Depends on M4.

---

## Current position

**Milestone 0 (setup) — awaiting your confirmation.** Branch `claude/deploy-poc` is created
and this doc is committed to it. On your go, I start **Milestone 1** (`deploy/bootstrap.sh`)
and stop again at its acceptance gate. Nothing is pushed — all remote ops are yours.
