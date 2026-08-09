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

| #   | Milestone                                         | Gate              | Status |
| --- | ------------------------------------------------- | ----------------- | ------ |
| 0   | Setup & rules of engagement                       | branch + this doc | ✅     |
| 1   | `deploy/bootstrap.sh` (the deploy IS this script) | no VM/AWS         | ✅     |
| 2   | Local proof in a Multipass VM                     | on the Mac        | 🔄     |
| 3   | Terraform wrap (dry — plan only, no apply)        | local             | ⬜     |
| 4   | The real click — live AWS apply + verify          | human applies     | ⬜     |
| 5   | CI/CD — GitHub Actions workflow                   | human triggers    | ⬜     |

### Deferred TODOs (later — not blocking the current milestone)

- [ ] **`local-dev.sh` soup-to-nuts validation.** `deploy/local-dev.sh` is authored but never
      run end-to-end (the current VM was built by hand). Prove it later: `multipass delete
      --purge musilinda`, then a single `./deploy/local-dev.sh` from a clean state must bring the
      whole stack up (all six M2 checks) with **zero manual steps** except the printed `mkcert
      -install` + `/etc/hosts` line. Fold in the docx blog re-ingest so content comes back too.
      *(Natural to do alongside M5/CI, where reproducible-from-scratch builds matter.)*

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

## Milestone 1 — `deploy/bootstrap.sh` ✅ (complete)

**shellcheck:** clean, exit 0 (`shellcheck deploy/bootstrap.sh deploy/fetch-artifacts.sh`)
after installing shellcheck 0.11.0 via brew. Idempotency proven live in M2 (guards fired on
re-run). All acceptance criteria met. See M2 for the fixes M1's script needed once run for real.

<details><summary>original M1 notes</summary>

**Scope:** one idempotent script that takes a clean **Ubuntu 24.04** host to a fully running
stack — system deps; nginx (subdomain routing per note 4); Postgres with both DBs + Drizzle
migrations (note 2); the three services built and running under systemd + static `web` served
by nginx (note 1); blog `BLOB_STORAGE_DIR` wired; Flask on `127.0.0.1` only, `--workers 1`
(note 3). Config/secrets from **one** env file: `deploy/secrets.env` (gitignored), with
`deploy/secrets.env.example` committed as template. Include `deploy/fetch-artifacts.sh` stub
for the gitignored model files (`whisper_model/model.safetensors`, `whisper_multihead_model.pt`)
— document options, pick the simplest.

**Acceptance criteria**

- [~] Script is **idempotent** (safe to re-run) — written with idempotent guards; **not yet
      verified by an actual re-run** (happens in M2).
- [ ] **shellcheck-clean** — PENDING: shellcheck not installed on the Mac; run in the VM
      (`apt install shellcheck`) or `brew install shellcheck` locally.
- [x] Every long-running service has a **systemd unit** — `musilinda-api`, `musilinda-app`,
      `musilinda-blog` (web is static, served by nginx — no unit, per note 1).
- [x] Section-by-section walkthrough delivered to the human.
- [x] No VM, no AWS invoked.

**Files written on `claude/aws` (uncommitted working tree):**
- `deploy/bootstrap.sh` — 9 sections: config → packages → user/dirs → postgres → env files →
  sources → builds → systemd → nginx.
- `deploy/secrets.env.example` — template (real `secrets.env` is gitignored).
- `deploy/fetch-artifacts.sh` — stub for the two gitignored model files (pre-stage, or
  `ARTIFACTS_BASE_URL`).

**Open decisions to confirm before/at M2:**
1. Source staging = pre-stage code into the VM (no GitHub creds needed) vs set `*_REPO` to clone.
2. Python 3.12 (Ubuntu 24.04 default) tried first; fall back to deadsnakes 3.11 if wheels break.
3. `drizzle db:push` may prompt interactively — most likely thing to need a tweak at M2.
4. TLS: bootstrap is HTTP-only; certbot on the real box at M4.
5. Whisper RAM: lazy/optional model load for the local proof if the Mac is tight.

**Status:** superseded — completed in M2. (Original resume notes retained above.)

</details>

---

## Milestone 2 — Local proof in a Multipass VM 🔄 (infra proven; app-functionality gate NOT met)

> **Revised bar (human, 2026-08-08):** "Until the app functions as designed, milestone 2 has
> not been reached." The six infra checks below all pass, but standing up the box is necessary,
> not sufficient. M2 is **not complete** until the deployed app *works as designed* end-to-end
> (see "App-functionality gate" at the end of this section).

**Environment:** Multipass `musilinda` VM, Ubuntu 24.04.4, 8 GB RAM, 4 vCPU, 25 GB disk,
aarch64 (Apple-Silicon host). **Faithfulness caveat:** real Lightsail is x86_64; everything
M2 proves (nginx routing, systemd, Postgres, blob storage, proxy boundary, idempotency) is
arch-independent. The only arch-sensitive piece — torch wheels — gets re-proven on x86 at M4.

**Acceptance criteria — six checks, all with real output**

- [x] (1) `bootstrap.sh` completes **exit 0** on a fresh VM. → `___BOOTSTRAP_DONE_rc=0___`
- [x] (2) All systemd services **active**. → `musilinda-api app blog nginx postgresql` = `active` ×5
- [x] (3) nginx routing through `Host:` headers → all HTTP 200, correct site each:
      `app.` "Sing the Interval" · `blog.` "Musilinda Blog" · `www.`/apex "Theory You Can Feel"
- [x] (4) Blog upload → filesystem → served back → uploaded PNG landed at
      `/var/lib/musilinda-blog/blob-store/blogs/poc1/…png`, fetched via `/api/blob-proxy`
      as `image/png`, **byte-identical** round-trip (`cmp` = YES). Real path: register → login
      (JWT) → `POST /api/admin/upload-image/:blogId` → `GET /api/blob-proxy/...`, all via nginx.
- [x] (5) Flask isolated + proxy-reachable → gunicorn bound `127.0.0.1:5000`; Mac→`VM:5000`
      = HTTP 000 (refused); `POST app.musilinda.com/api/generate-token` (nginx → app_musilinda →
      Flask) returned a real token, HTTP 200.
- [x] (6) Idempotent re-run → rc=0, guards fired ("Swap already active", "Source present …
      using as-is" ×4), **0 error lines**, all 5 services still active, routing still 200,
      previously-uploaded blob still served (data preserved).

### Defects found by the clean-room run — all fixed at source in `bootstrap.sh`/secrets

None of these were visible from reading code; only a real build on a bare box surfaced them.

1. **No swap → OOM-wedged the VM** unpacking the torch stack. → `setup_swap` adds a 4 GB
   swapfile early (Lightsail 8 GB also ships swapless — real fix, not a VM band-aid).
2. **CUDA torch on a GPU-less box** (~2.5 GB unused NVIDIA libs). → install CPU-only torch from
   `download.pytorch.org/whl/cpu` before the requirements pass (`torch 2.13.0+cpu`).
3. **`npm ci` needs a lockfile app_musilinda doesn't commit.** → `_npm_build` falls back to
   `npm install` when no `package-lock.json` (warns).
4. **nginx web root wrong:** `vite build client` outputs to `web/client/dist`, script pointed
   at `web/dist`. → corrected `web_root`.
5. **app_musilinda throws on empty `SENDGRID_API_KEY` in production** (`emailService.ts:8`,
   guarded by `NODE_ENV!=="development"`). → PoC secrets set a placeholder key; real key at
   cutover. (CLAUDE.md's ".env" "blank OK in dev" is accurate for dev only.)

### Reproducibility correction (important)

The web build initially only passed because two missing deps were hand-installed *inside the
VM* — a step in neither `bootstrap.sh` nor the web repo, so a truly fresh git-sourced run
would still have failed. This was corrected properly: `web/package.json` +
`web/package-lock.json` now declare `tailwindcss-animate` + `@tailwindcss/typography` (web
repo working tree — **needs a human commit**). Re-verified by wiping the VM's web dir and
re-staging web from the corrected source (no node_modules, no manual step): unmodified
`bootstrap.sh` built it via `npm ci` → `✓ built`, `web/client/dist/index.html` present,
apex + www HTTP 200. **web is now reproducible from source.**

### Repo-hygiene follow-ups for the human (Claude does not commit to these repos)

- **web (REQUIRED for reproducibility — fix already in working tree, needs commit):** the two
  tailwind plugins added to `package.json`/`package-lock.json`. Without this the deploy needs
  a manual `npm install`; with it, `bootstrap.sh` is turnkey. Committed = M2 fully clean.
- **app_musilinda (optional):** commit a `package-lock.json`. Not required — `bootstrap.sh`'s
  `npm install` fallback already builds it from pristine source — but a lockfile restores
  reproducible `npm ci`.

### Open decisions from M1 — now resolved by the live run

1. **Source staging:** pre-staged via `git archive <ref> | multipass transfer` (no GitHub
   creds in the VM). blog from `claude/aws`, others from `claude/aws`. ✔
2. **Python:** 3.12 (Ubuntu 24.04 default) worked — CPU torch/deps wheels all resolved. ✔
3. **drizzle `db:push`:** ran **non-interactively** on both fresh DBs ("Changes applied"), no
   prompt hang. ✔
4. **TLS:** stayed HTTP-only in the VM as planned; certbot deferred to M4. ✔
5. **Whisper RAM:** lazy-load fallback **not needed** — real weights pre-staged, model loaded,
   token endpoint served. (8 GB + 4 GB swap was comfortable.) ✔

### Minor hardening notes (not blocking; consider at M3/M4)

- Node apps bind `0.0.0.0:5001/5002`. Fine behind the Lightsail firewall (only 80/443 open),
  but binding `127.0.0.1` would be defense-in-depth since nginx fronts them.
- `fetch-artifacts.sh` runs as the unprivileged `musilinda` user, so the deploy dir must be
  world-traversable — deploy scripts staged under `/opt/musilinda-deploy` (not `/home/...`).

### App-functionality gate (NEW — required to close M2)

Infra checks pass, but hands-on testing over HTTPS (mkcert on `*.musilinda.test`) exposed that
**the deployed app does not function as designed on fresh-DB data.** Concretely, the Intervals
lesson is stuck on "C→E", shows "1/0", and hits Congratulations every attempt.

**Root cause (verified, not the deploy):** `db:push` creates only the schema; the app then
**self-seeds** `interval_lessons` with an **old category taxonomy** (`unison, seconds, thirds,
fourths, fifths, sixths, sevenths, octaves`) that the **current client does not recognize** —
the client filters on `perfect, major_diatonic, minor_diatonic, modal, chromatic`. **Zero
overlap** → the client's `exercises` array is empty → it falls back to a hardcoded default
exercise (`C4→E4, Major 3rd` = the "C→E" seen) → `categoryExercises.length = 0` ("1/0") →
`currentExercise === totalExercises` → Congratulations every time. (`client/src/pages/Home.tsx`
~L345 category grouping, L460 fallback, L488 counter.)

Auth + persistence themselves are proven working over HTTPS: register/login set an HttpOnly
**Secure** `userToken` cookie, `/api/auth/me` → 200, and `POST /api/progress/complete` wrote a
real `lesson_progress` row. So the failure is **data**, not stack/auth/TLS.

**What closing M2 now requires:**
- [x] **Intervals fixed** — replaced the VM's mis-categorized `interval_lessons` with the
      authoritative 18 rows pulled from prod's public `/api/lessons`, AND fixed the app's seed
      (`app_musilinda/server/storage.ts`) to the correct quality taxonomy so a fresh DB is right.
- [x] **Blog content loaded** — reconstructed all **20 posts** by re-ingesting the original
      `.docx` files through the migrated admin (`/api/admin/upload-blog`): titles/icons from
      filenames, categories/excerpts inferred (owner-approved), images extracted natively to the
      filesystem blob store, serving via `/api/blob-proxy` (verified HTTP 200, image/png). No
      URL-normalization needed because the migrated code authored them. Categories: basics 5 /
      intervals 4 / scales 3 / chords 2 / harmony 5 / advanced 1.
- [x] **Admin confirmed on both** over HTTPS: app `POST /api/admin/login` (`admin`/`admin123`,
      separate `adminToken` cookie) → `/api/admin/me` 200; blog `/admin-login` (`pocadmin`) 200.
- [ ] **Owner to eyeball in browser**: Intervals starts at Perfect Unison (C→C) / advances /
      saves score; blog lists the 20 posts with images; both `/admin` dashboards usable.
- [ ] **True prod data** (users/progress for `app_musilinda`) still test-only — a real cutover
      would still `pg_restore` the Replit dumps. Blog content is now real via docx re-ingest.

### Progress note (2026-08-09)
The app-functionality gate is **substantially met**: intervals works, blog has real content +
images, both admins log in. Remaining before the owner signs off M2: browser eyeball of the
above. Content path chosen for blog = **docx re-ingest** (not a DB dump) — cleaner, uses the
migrated pipeline, produces native `/api/blob-proxy` URLs.

### Blog content + web/blog repo fixes applied (2026-08-09)

Content authoring, admin, and a batch of real bugs — all fixed in the service repos' working
trees (uncommitted; **owner to commit**), rebuilt in the VM, and verified.

**`blog` repo (`claude/aws`):**
- ✅ **Analytics were dead** — `analyticsMiddleware` was imported but **never `app.use()`d**, so
  `page_visits` stayed empty and admin analytics read 0. Mounted it before the routes → views now
  record (verified: 4 views → 4 rows → dashboard shows them). `server/routes.ts`.
- ✅ **Category dropdown mismatch** — the upload form offered `Fundamentals/Theory/Advanced/
  Conclusion` (matched no all-posts card); edit form offered `basics/intervals/scales/chords/
  harmony/advanced` (the real cards). Made upload match the cards; fallback `General`→`basics`.
  `client/src/pages/admin.tsx`. *(This is why an admin-UI upload seemed to "vanish" — it went to
  a phantom category. API uploads used correct categories, so the 20 posts were fine.)*
- ✅ **Upload gave no feedback** — the upload mutation's `onSuccess` had no toast (every other
  mutation did). Added a "Post published" toast. `client/src/pages/admin.tsx`.
- ✅ **Source-code leak** — `/download` + `/project.tar.gz` served the whole project tarball
  **unauthenticated**. Removed. `server/routes.ts`.
- ✅ **Replit dev-banner** `<script>` removed. `client/index.html`.
- ✅ **all-posts ordering** — removed dead `Full Disclaimer`/`Conclusion` sort special-cases;
  cards now order by curriculum (`basics→intervals→scales→chords→harmony→advanced`).
  `client/src/pages/all-posts.tsx`.

**`web` repo (`claude/aws`):**
- ✅ **Tailwind Play CDN → build-time CSS** — landing loaded `cdn.tailwindcss.com` at runtime
  (dev-only, external dep, no styling if CDN is down). Added `client/style.css` (`@tailwind`
  directives) + `<link>`; build now emits a 10KB purged stylesheet (class coverage verified).
- ✅ **Replit dev-banner** removed. `client/index.html`.
- ✅ **`privacy-policy.html` was never emitted** by `vite build` → the footer link fell through
  to the homepage. Moved to `client/public/` so Vite copies it; now serves the real page.
- ✅ **Env-driven "Learn" CTA** — `%VITE_LEARN_URL%` + `client/.env` default + `bootstrap.sh`
  build override (local→`learn.musilinda.test`, prod→`learn.musilinda.com`).

**Admin access (both, over HTTPS):** app `https://app.$DOMAIN/admin/login` (`admin`/`admin123`,
`adminToken` cookie); blog `https://learn.$DOMAIN/admin-login` (`pocadmin`/`pocpass123`).

**Still-open repo notes (not blocking M2):**
- Interval-lesson **seed** was out of sync with the client taxonomy — fixed in `app_musilinda`
  working tree; a fresh prod DB on the OLD seed would break Intervals in prod too.
- Blog **title derivation** mangles non-ASCII docx filenames + strips a leading `(` (cosmetic;
  worked around by fixing 2 titles in the DB).
- `web` **Tailwind CDN removal** covers `index.html`; if `privacy-policy.html` ever needs
  utility classes it would need the same `<link>` (currently self-contained inline CSS).

### HTTPS-for-local-testing note (mkcert)

To test secure-context features locally (mic `getUserMedia`, Secure cookies) without shadowing
the real domains, the VM serves `*.musilinda.test` over HTTPS via a **mkcert** cert
(`/etc/nginx/sites-available/musilinda-test.conf`, certs in `/etc/nginx/certs/`). The Mac trusts
the mkcert local CA (`mkcert -install`). This is **local-testing scaffolding only** — production
TLS is Let's Encrypt at M4. `*.musilinda.test` server blocks are additive and never touch the
real `musilinda.com` routing.

**Status:** 🔄 **in progress — NOT complete.** Infra checks pass; the app-functionality gate is
**open** pending real production data. **Do not start M3 until M2's app gate is met.**

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

**Scope:** `.github/workflows/deploy.yml` — **triggered on push/PR to `claude/aws` only**, so
`main` is never touched during the PoC. The workflow file lives **only on `claude/aws`** (not
merged to main). Jobs: `terraform plan`, `apply` on approval, using **GitHub-side secrets**
(Claude documents required secret names; never sees values). Include a smoke-test job running
the curl checks post-deploy.

```yaml
on:
  push:
    branches: [claude/aws]
  pull_request:
    branches: [claude/aws]
```

**Why not `workflow_dispatch` yet:** the manual "Run workflow" button only works if the
workflow file is on the repo's **default branch** (main) — a GitHub limitation. Keeping the
PoC off main means push-triggering on `claude/aws` instead. When promoting to real use, merge
the workflow to main and switch to `workflow_dispatch`.

**Acceptance criteria**

- [ ] Workflow YAML passes **actionlint**.
- [ ] Triggers are scoped to `claude/aws`; workflow file is not on `main` (main stays clean).
- [ ] `deploy/README.md` documents required **secret names** + how it triggers.
- [ ] Dry-run explanation of each job delivered.
- [ ] Human pushes to `claude/aws` to run it (Claude does not push).

**Evidence:** _(to fill: actionlint output, secret-name list, per-job explanation)_

**Status:** ⬜ not started. Depends on M4.

---

## Current position

**M1 COMPLETE. M2 IN PROGRESS — infra proven, app-functionality gate OPEN.** `bootstrap.sh`
stands up the full stack on a fresh Multipass Ubuntu 24.04 VM (all six infra checks pass, five
deploy defects fixed at source). **But** hands-on HTTPS testing showed the app does **not**
function as designed on fresh-DB data: Intervals is stuck on C→E / "1/0" / endless Congrats,
because the app's boot-seed uses a category taxonomy the current client doesn't recognize
(0 overlap). Per the human's bar — "until the app functions as designed, M2 has not been
reached" — **M2 is not complete.** Closing it requires loading **real production data** and
re-verifying the app works end-to-end over HTTPS. See the "App-functionality gate" in the M2
section. The VM (`musilinda`) is still up (`multipass shell musilinda`; browse
`https://app.musilinda.test` after `mkcert -install`).

**Next: get a production DB dump into the VM, then re-verify app functionality. M3 (terraform)
is blocked until M2's app gate is met.**

**Follow-ups to commit** (Claude doesn't push these repos):
- **web repo (required for a turnkey deploy; fix is in the working tree):** the two tailwind
  plugins in `package.json` + `package-lock.json`. Commit these on web's branch.
- **app_musilinda (optional):** a `package-lock.json` — bootstrap's `npm install` fallback
  already handles its absence.

**Uncommitted working-tree changes (nothing pushed — all yours to commit):**
- **Musilinda root** (`claude/aws`): `deploy/bootstrap.sh` (swap, CPU torch, npm fallback, web
  root, learn.$DOMAIN nginx, VITE_LEARN_URL build), `deploy/.gitignore`, `deploy/MILESTONES.md`,
  `deploy/LOCAL_DEV.md` (new), `deploy/local-dev.sh` (new), `CLAUDE.md` (domain-map correction).
- **web** (`claude/aws`): `client/index.html` (banner, CDN→built CSS, env CTA), `client/style.css`
  (new), `client/public/privacy-policy.html` (moved), `client/.env` (new), `package.json` +
  `package-lock.json` (tailwind plugins).
- **app_musilinda** (`claude/aws`): `server/storage.ts` (interval seed → correct taxonomy).
- **blog** (`claude/aws`): `server/routes.ts` (analytics mount + leak removal),
  `client/src/pages/admin.tsx` (dropdown, fallback, upload toast), `client/src/pages/all-posts.tsx`
  (curriculum sort), `client/index.html` (banner).

> ⚠️ Local **VM data is NOT in git**: the 20 blog posts (docx re-ingest), blob-store images, the
> corrected `interval_lessons`, and test accounts live only in the Multipass VM. Recreating the VM
> (e.g. via `local-dev.sh`) starts from seed — re-run the docx upload to restore blog content.

_Branch layout: Musilinda + api + app_musilinda + web on `claude/aws`; blog on
`claude/aws` (filesystem storage) and `claude/aws`; core + capacitor on `main`._
