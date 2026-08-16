# CLAUDE.md — Musilinda Platform (Replit → Lightsail migration)

This workspace is a **federated multi-repo product suite**, not one deployable app. Each
service directory (`api`, `app_musilinda`, `blog`, `web`, `core`, `capacitor`) is its own
**nested git repository** with its own remote on GitHub. `profile` is docs only (no git).

Production currently runs on **Replit**. We are migrating to **one AWS Lightsail box**
(Ubuntu, nginx reverse proxy, on-box Postgres). Replit keeps serving prod until cutover.

See `ARCHITECTURAL_LANDSCAPE.md` for the system-context diagram and per-directory map.
This file captures the **migration-relevant** facts: RAM, artifacts, env vars, blob
storage, build/run commands, and the ordered checklist.

---

## Target architecture (single Lightsail box)

```
                            nginx (:80/:443, TLS)
        ┌────────────────────┬────────────────────┬────────────────────┐
   app.musilinda.com    learn.musilinda.com  musilinda.com / www   (static files)
   (learning app,       (blog CMS)
    Capacitor→iOS)          │                    │
        │                    │                    │
   127.0.0.1:5001       127.0.0.1:5002      served directly by nginx from web/ dist
   app_musilinda         blog Express
     Express                │
        │                   │
        │ AUDIO_API_BASE_URL → 127.0.0.1:5000  (Flask/gunicorn, localhost-only)
        │                   │
        └────────┬──────────┘
                 │ SQL
        Postgres 127.0.0.1:5432
          ├─ db: musilinda   (app_musilinda)
          └─ db: blog        (blog)
                 │
        blog images → local filesystem at BLOB_STORAGE_DIR (default <cwd>/blob-store)
```

Domains (authoritative — confirmed by owner 2026-08-09):
- `app.musilinda.com` → `app_musilinda` = the **interactive learning app** (also wrapped by
  **Capacitor → iOS App Store**; see `capacitor/README.md`).
- `learn.musilinda.com` → `blog` = the **blog CMS** (admin side uploads posts). *(The marketing
  site's "Learn" CTA points here. "blog" and "learn" are used interchangeably by the owner; the
  production host is `learn.`.)*
- `musilinda.com` + `www.musilinda.com` → the static `web` marketing site.
- **Inference API: no subdomain — intentionally internal.** The Flask API binds **127.0.0.1
  only** and is reached exclusively via `app_musilinda`'s `AUDIO_API_BASE_URL` proxy (browser
  hits it as the same-origin path `app.musilinda.com/api/*`), never directly from the internet.
  There is deliberately **no `api.musilinda.com`** — co-located on one box, it needs no public
  host. (Would only need a *private* address if inference ever moves to a separate box.)

> ⚠️ Earlier drafts of this file said `blog.musilinda.com`; that was an unsourced assumption.
> The real host is `learn.musilinda.com`. `bootstrap.sh`/nginx must serve `blog` at `learn.$DOMAIN`
> (decision pending on whether to also keep `blog.` as an alias).

---

## Services at a glance

| Service         | Stack                                       | Runtime  | Public?        | Notes                                                |
| --------------- | ------------------------------------------- | -------- | -------------- | ---------------------------------------------------- |
| `api`           | Flask + PyTorch/Whisper                     | gunicorn | No (localhost) | Loads model at startup; heavy RAM                    |
| `app_musilinda` | React+Vite / Express(TS) / Drizzle+Postgres | Node 20  | Yes            | Proxies to `api`; serves its own built client        |
| `blog`          | React+Vite / Express(TS) / Drizzle+Postgres | Node 20  | Yes            | DOCX ingestion (mammoth); Azure Blob for images      |
| `web`           | Static Vite + Tailwind                      | none     | Yes            | Pure static; nginx serves `dist/`                    |
| `capacitor`     | iOS shell                                   | —        | —              | Points at deployed URL; **out of scope for now**     |
| `core`          | Offline R&D pipeline                        | —        | —              | Produces model/notation artifacts; **never deploys** |
| `profile`       | Docs                                        | —        | —              | —                                                    |

---

## 1. Flask (`api`) RAM footprint

**Model artifacts on disk:**

| Artifact                                                            | Size       | Git-tracked?  |
| ------------------------------------------------------------------- | ---------- | ------------- |
| `whisper_model/model.safetensors` (whisper-tiny, 384-dim)           | **151 MB** | ❌ gitignored |
| `whisper_multihead_model.pt` (multi-head classifier weights)        | **32 MB**  | ❌ gitignored |
| `whisper_model/*` tokenizer/config JSON + `merges.txt`/`vocab.json` | ~2 MB      | ✅ tracked    |
| `syllable/vowel/consonant_encoder.joblib`                           | ~1 KB each | ✅ tracked    |

**How it loads (`api/audio_processor.py`):** `AudioProcessor` is a singleton, built once at
startup (`app.py:init_audio_processor()` runs at import, so gunicorn loads the model in
each worker). It:

- forces `TRANSFORMERS_OFFLINE=1` / `HF_HUB_OFFLINE=1`,
- `WhisperModel.from_pretrained("whisper_model", local_files_only=True).encoder` (loads the
  full whisper-tiny then keeps only the frozen encoder),
- loads `whisper_multihead_model.pt` state dict (CPU, `map_location='cpu'`),
- loads the three joblib encoders.
- CPU-only in practice (`cuda` if available, but Lightsail has no GPU).

**RAM estimate (single gunicorn worker, steady state):** ~**1.0–1.5 GB RSS**, dominated by
`import torch` (~0.5–0.7 GB) + `transformers` (~0.15–0.25 GB) + model weights + working set.
Peak during load is slightly higher. **This scales linearly with gunicorn `--workers`.**

> ⚠️ `api/README.md` suggests `gunicorn --workers 2` — that would run **two full copies of
> torch** (~2.5–3 GB). On this box use **`--workers 1`** (the Replit `.replit` deploy line
> already uses the gunicorn default of 1). Concurrency for a single-user-ish inference
> endpoint is fine at 1 worker; add `--threads` if needed instead of more workers.

**Whole-box budget (steady state, 1 worker):**

| Component                        | Approx RSS      |
| -------------------------------- | --------------- |
| Ubuntu + systemd                 | ~0.4 GB         |
| nginx                            | ~0.02 GB        |
| Postgres (2 small DBs)           | ~0.3 GB         |
| Flask/gunicorn (1 worker, torch) | ~1.2 GB         |
| app_musilinda (Express prod)     | ~0.15 GB        |
| blog (Express prod)              | ~0.15 GB        |
| **Total steady**                 | **~2.2–2.4 GB** |

**Decision: 8 GB box.** Steady state uses ~2.2–2.4 GB, so 8 GB leaves comfortable headroom
for `vite build` spikes (each Vite/esbuild build can hit 0.5–1.5 GB) and inference bursts.
Still use gunicorn **`--workers 1`** (no reason to pay for a second torch copy). Blog images
are served from the **local filesystem**, so there is no Azurite process on the box.

**System packages the model needs (were Replit nix packages → now apt):**
`ffmpeg`, `libsndfile1` (torchaudio decoding), plus `python3.11`. `openssl`/`pkg-config`
are toolchain-only.

---

## 2. Artifact commit status (what must be copied to the server)

| Repo            | Artifact                                                                                                      | Status                                                  | Action                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------- |
| `api`           | `whisper_model/model.safetensors` (151 MB)                                                                    | **gitignored**                                          | **Copy to server out-of-band**                                    |
| `api`           | `whisper_multihead_model.pt` (32 MB)                                                                          | **gitignored**                                          | **Copy to server out-of-band**                                    |
| `api`           | encoders `.joblib`, `whisper_model/*.json`, `merges.txt`, `vocab.json`                                        | tracked                                                 | ships with clone                                                  |
| `app_musilinda` | `public/whisper_multihead_model.onnx` (32 MB), root `whisper_multihead_model.onnx` (32 MB), `test_model.onnx` | **tracked** (committed before the `*.onnx` ignore rule) | ships with clone ✅                                               |
| `app_musilinda` | notation/media assets under `public/` (`audio/`, `images/`, `keyboard_notes/`, `modal_scales/`, `samples/`)   | tracked                                                 | ships with clone ✅                                               |
| `blog`          | `uploads/` (3.9 MB, legacy multer disk files)                                                                 | tracked                                                 | ships with clone                                                  |
| `blog`          | actual production blog images                                                                                 | in prod's Replit blob store, **not in git**             | **data migration needed** → copy into `BLOB_STORAGE_DIR` (see §4) |

**Key point:** the two big `api` files are the **only code-repo artifacts that are NOT in
git** and must be transferred manually (scp/rsync/S3) as part of provisioning. Everything
`app_musilinda` needs (including its client-side ONNX and notation assets) is committed and
arrives with `git clone`. `core` produces these artifacts upstream but never deploys.

---

## 3. Environment variables & Replit config

Replit-specific files present: `api/.replit`, `app_musilinda/.replit`. No `replit.nix`
(nix config is inline in `.replit`). `blog` and `web` have no `.replit`. On the server the
`.replit` files are inert; their port maps and nix packages are replaced by nginx + apt.
Also Replit dev cruft in `app_musilinda`: `replit.md`, `migration_env.txt`, `*_cookies.txt`,
`*_test.txt` (see TODO — clean from history before making repos public).

### `.env` templates

**`api/.env`**

```dotenv
# Flask session signing (was Replit secret)
SESSION_SECRET=<long-random-string>
# Leave unset/production so ProxyFix trusts nginx X-Forwarded-* headers.
# Set to "development" or "local" ONLY for local runs.
# FLASK_ENV=
```

Notes: API auth tokens are **in-memory**, generated at runtime — no secret needed. No
`DATABASE_URL` (the Flask service does not use Postgres despite `flask-sqlalchemy` being in
requirements — `models.py` is plain dataclasses).

**`app_musilinda/.env`**

```dotenv
DATABASE_URL=postgresql://USER:PASS@localhost:5432/musilinda
PORT=5001
AUDIO_API_BASE_URL=http://127.0.0.1:5000
SESSION_SECRET=<long-random-string>
SENDGRID_API_KEY=<sendgrid-key-or-blank-in-dev>
FRONTEND_URL=https://app.<domain>   # required in production (email links)
# NODE_ENV=production                # set by the start script
```

Note: the `.replit` lists openai/stripe/google-analytics integrations, but **only SendGrid
is actually referenced in code**. No `STRIPE_*` / `OPENAI_*` / `VITE_*` vars are used.

**`blog/.env`**

```dotenv
DATABASE_URL=postgresql://USER:PASS@localhost:5432/blog
JWT_SECRET=<long-random-string>
PORT=5002                                          # Express listen port (nginx proxies to it)
BLOB_STORAGE_DIR=/var/lib/musilinda-blog/blob-store   # where blog images are stored on disk
```

Note: blob storage is now the **local filesystem** (was Azure Blob/Azurite). `AZURE_*` vars
are gone. If `BLOB_STORAGE_DIR` is unset it defaults to `<cwd>/blob-store`; set it to a
persistent path outside the repo checkout on the server.

**`web/.env`** — none. Pure static site; no `process.env` / `import.meta.env` usage.

---

## 4. Blog blob storage — now local filesystem

**Decision: switched from Azure Blob/Azurite to the local filesystem.** Implemented in
`blog/server/blob-storage.ts` (a small module: `putObject`, `getObjectStream`,
`objectExists`, `deleteObject`, `deletePrefix`, `contentTypeFor`). The five former Azure call
sites in `blog/server/routes.ts` (proxy-serve, DOCX-extract upload, single upload,
delete-post, delete-specific-images) now call this module.

- Objects are addressed by the same key as before, `blogs/<blogId>/<filename>`, stored as
  files under **`BLOB_STORAGE_DIR`** (default `<cwd>/blob-store`).
- Read path (`/api/blob-proxy/:blogId/:filename`) infers content type from the file
  extension and streams the file; `resolveKey()` blocks `../` path traversal from URL params.
- Delete-post removes the whole `blogs/<id>/` directory.
- Some icons are still stored inline as base64 data-URIs in Postgres (unchanged). DOCX
  ingestion still uses `mammoth` + `JSZip` (no external service).

**On the server:** just a writable directory — no Azurite, no Azure account, no extra
process. Set `BLOB_STORAGE_DIR` to a persistent path (e.g. `/var/lib/musilinda-blog/blob-store`)
and **back it up** (it holds all blog images). `@azure/storage-blob` is no longer imported;
it remains an unused entry in `package.json` (optional cleanup — removing it means updating
`package-lock.json` too). The repo's local `azurite_data/` and 7 MB `azurite_debug.log` are
dev cruft — do not ship.

**Data migration:** existing production blog images must be copied out of Replit's current
blob store into `BLOB_STORAGE_DIR`, preserving the `blogs/<blogId>/<filename>` layout. This
is a separate data move from the git clone.

---

## 5. Build & start commands (all run outside Replit)

| Service         | Build                                                        | Start (prod)                                               | System deps                          |
| --------------- | ------------------------------------------------------------ | ---------------------------------------------------------- | ------------------------------------ |
| `api`           | `pip install -r requirements.txt` (Python 3.11 venv)         | `gunicorn main:app --bind 127.0.0.1:5000 --workers 1`      | ffmpeg, libsndfile1                  |
| `app_musilinda` | `npm ci && npm run build` (`vite build` + esbuild → `dist/`) | `npm run start` → `NODE_ENV=production node dist/index.js` | Node 20                              |
| `blog`          | `npm ci && npm run build` (same pattern → `dist/`)           | `npm run start` → `node dist/index.js` (reads `PORT`)      | Node 20; writable `BLOB_STORAGE_DIR` |
| `web`           | `npm ci && npm run build` (`vite build client`)              | none — nginx serves the static `dist/`                     | Node 20 (build-time only)            |

All start commands are standard gunicorn/node — **no Replit runtime dependency**. The
`.replit` `run`/`deployment` blocks and Replit port mappings (5000→80 etc.) are replaced by
systemd units + nginx. `app.py`'s `ProxyFix` is gated on `FLASK_ENV` — keep it unset in prod
so forwarded headers from nginx are trusted.

> Build-RAM caveat: run `vite build` for the Node apps **off-box (CI/local) and ship `dist/`**,
> or build one at a time with other services stopped, if you land on a 4 GB box.

---

## 6. Migration checklist (ordered by risk, highest first)

**A. Highest risk — get these right or the box falls over / data is lost**

- [ ] **Transfer the two gitignored model files** (`whisper_model/model.safetensors`,
      `whisper_multihead_model.pt`) to `api/` on the server; verify checksums. Startup fails
      without them.
- [ ] **Postgres data migration**: create `musilinda` + `blog` DBs, then restore from
      **fresh Replit dumps taken at cutover** (decided — do not rely on the committed
      `app_musilinda/*.sql` dumps, which may be stale).
- [ ] **Copy existing blog images** out of Replit's blob store into `BLOB_STORAGE_DIR`,
      preserving the `blogs/<blogId>/<filename>` layout. (Code already switched to filesystem.)
- [ ] **Bind Flask to 127.0.0.1 only**; confirm it is not reachable from the internet.
- [ ] **Run gunicorn with `--workers 1`** (8 GB box has headroom, but a 2nd worker doubles
      the ~1.2 GB torch footprint for no benefit here).

**B. Medium risk — config/wiring**

- [ ] Provision apt deps: `nginx postgresql ffmpeg libsndfile1 python3.11 python3.11-venv`;
      Node 20. (No Azurite — blob storage is the local filesystem now.)
- [ ] Write `.env` for each service from the templates above; generate fresh secrets
      (`SESSION_SECRET`, `JWT_SECRET`) — do **not** reuse Replit ones.
- [ ] nginx: subdomain → upstream map, TLS (Let's Encrypt), static `web/` root, client
      max body size for DOCX/image uploads.
- [ ] systemd units for: gunicorn(api), app_musilinda, blog, azurite. Set `WorkingDirectory`
      and `EnvironmentFile`.
- [ ] Set `AUDIO_API_BASE_URL=http://127.0.0.1:5000` and confirm the proxy path
      (`app_musilinda` → api token + analyze) works end-to-end.
- [ ] Set `PORT=5002` for blog (now env-driven) and `PORT=5001` for app_musilinda; point
      nginx upstreams at those.
- [ ] Create `BLOB_STORAGE_DIR` on the box (writable by the blog service user) and add it to
      the backup set.

**C. Lower risk — hygiene / follow-ups**

- [ ] Clean junk from `app_musilinda` git history (`migration_env.txt`, `*_cookies.txt`,
      `*_test.txt`, `browser_cookies.txt`) — from TODO; do before repos go public.
- [ ] Add auth/secret to the `api` token-generation endpoint (`/api/generate-token` is
      currently open; mitigated only by localhost binding) — from TODO.
- [ ] Pin `scikit-learn` to the encoder training version (README notes 1.5.x) to avoid
      LabelEncoder unpickle warnings.
- [ ] Don't ship dev artifacts: `blog/azurite_data/`, `blog/azurite_debug.log`, `.venv/`,
      `node_modules/`.
- [ ] DNS: point subdomains at the Lightsail static IP; plan cutover + rollback to Replit.

### Decisions (resolved 2026-08-02)

1. **Box: 8 GB Lightsail.** Run gunicorn `--workers 1`.
2. **Blob storage: local filesystem** (`blog/server/blob-storage.ts`, `BLOB_STORAGE_DIR`) —
   Azure/Azurite dropped.
3. **Blog server port: env-driven** (`process.env.PORT`, default 3000; set `PORT=5002`).
4. **Domains:** `app.musilinda.com` (learning app / Capacitor→iOS), `learn.musilinda.com`
   (blog CMS), apex + `www.musilinda.com` → `web`. Inference API is internal-only (no subdomain).
   *(Corrected 2026-08-09: was wrongly `blog.musilinda.com`.)*
5. **DB: fresh Replit dumps at cutover** (not the committed SQL dumps).

No open decisions blocking the build-out. Remaining work is execution (Section 6 A–C).

---

## Conventions for working in this repo

- Each service is a **separate git repo** — commits/branches/PRs are per-service, not
  workspace-wide. Check `git -C <service> status` in the right subdir.
- `core` and `capacitor` are **not deployment targets**; don't wire them into the box.
- Secrets live in per-service `.env` (all gitignored). Never commit real secrets.
- The Flask API is an **internal service** — treat `127.0.0.1`-only as a security boundary.

## The command to pick up where claude left off

```bash
# Read CLAUDE.md and deploy/MILESTONES.md, follow the ground rules there, continue from the current milestone.

```
