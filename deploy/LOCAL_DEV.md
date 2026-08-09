# Local Dev Environment (`.test`) — Runbook

Stand up the whole Musilinda stack locally in a **Multipass Ubuntu 24.04 VM** that faithfully
emulates the AWS Lightsail box, served over HTTPS at `*.musilinda.test`. This is the `.test`
tier of the `DOMAIN`-keyed model (`.test` local → `.dev` cloud dev → `.com` prod).

> The box provisioning itself is `deploy/bootstrap.sh` (the same script prod runs). This doc
> covers the **local-only wrapper**: the VM, source staging, HTTPS via mkcert, and `/etc/hosts`.
> Steps marked **(sudo/you)** need your Mac password — run them yourself with `!` in the prompt.

---

## Quick start (one command)

```bash
brew install multipass mkcert          # one-time
mkcert -install                        # one-time (trust the local CA)
./deploy/local-dev.sh                  # launch VM → stage → bootstrap → HTTPS
```

`local-dev.sh` does steps 1–4 below automatically (generates `deploy/secrets.env` with
`DOMAIN=musilinda.test` if absent, reuses an existing VM if present). When it finishes it prints
the exact `/etc/hosts` line to add. Then browse `https://musilinda.test`.

The manual steps below are the **explanation / fallback** for when you want to do it by hand or
debug a stage.

---

## 0. Prereqs (Mac, one-time)

```bash
brew install multipass mkcert shellcheck   # node 20 also needed for building web/app off-box
mkcert -install                            # (sudo/you) trust the local CA in your OS/browser
```

## 1. Launch the VM

```bash
multipass launch 24.04 --name musilinda --memory 8G --disk 25G --cpus 4
multipass info musilinda | awk '/IPv4/{print $2}'    # note the VM IP (changes on some restarts)
```

## 2. Stage source, secrets, and model artifacts into the VM

`bootstrap.sh` uses pre-staged source at `/srv/musilinda/<service>` (no GitHub creds in the VM).
Build one tarball per service **at the right ref** (blog from `claude/aws`, others
from `claude/aws`), plus the two gitignored model weights, plus `secrets.env`.

```bash
# from the repo root — archive each service at its branch
for s in api app_musilinda web; do git -C $s archive claude/aws -o /tmp/$s.tar; done
git -C blog archive claude/aws -o /tmp/blog.tar

# copy in, extract to /srv/musilinda/<svc>, add model weights (api), stage deploy/ scripts
multipass exec musilinda -- sudo mkdir -p /srv/musilinda/{api,app_musilinda,blog,web}
for s in api app_musilinda blog web; do
  multipass transfer /tmp/$s.tar musilinda:/home/ubuntu/$s.tar
  multipass exec musilinda -- sudo tar xf /home/ubuntu/$s.tar -C /srv/musilinda/$s
done
# gitignored model weights (~176 MB) → api/
multipass transfer api/whisper_multihead_model.pt musilinda:/home/ubuntu/
multipass transfer api/whisper_model/model.safetensors musilinda:/home/ubuntu/
multipass exec musilinda -- sudo bash -c 'cp /home/ubuntu/whisper_multihead_model.pt /srv/musilinda/api/ &&
  cp /home/ubuntu/model.safetensors /srv/musilinda/api/whisper_model/'

# deploy scripts + secrets to a world-traversable path (fetch-artifacts runs as unpriv user)
cp deploy/secrets.env.example deploy/secrets.env   # then fill in — DOMAIN=musilinda.test, real secrets
multipass exec musilinda -- sudo mkdir -p /opt/musilinda-deploy
multipass transfer deploy/bootstrap.sh deploy/fetch-artifacts.sh deploy/secrets.env musilinda:/home/ubuntu/
multipass exec musilinda -- sudo bash -c 'cp /home/ubuntu/{bootstrap.sh,fetch-artifacts.sh,secrets.env} /opt/musilinda-deploy/ &&
  chmod 755 /opt/musilinda-deploy/*.sh && chmod 600 /opt/musilinda-deploy/secrets.env'
```

**Set `DOMAIN=musilinda.test` in `secrets.env`.** Everything (nginx `server_name`s, the landing
`VITE_LEARN_URL`) derives from it.

## 3. Provision the box

```bash
multipass exec musilinda -- sudo bash /opt/musilinda-deploy/bootstrap.sh
```
Idempotent — safe to re-run. Installs nginx/postgres/node/ffmpeg, CPU-only torch, builds all
services, writes systemd units, and nginx routing for `app./learn./musilinda.test`.

## 4. HTTPS for `*.musilinda.test` (mkcert)

Plain HTTP breaks mic (`getUserMedia`) and drops the app's `Secure` session cookie, so local
**must be HTTPS**. Issue a cert (trusted because you ran `mkcert -install`) and wire nginx:

```bash
mkcert app.musilinda.test learn.musilinda.test www.musilinda.test musilinda.test blog.musilinda.test
# transfer the two .pem files → /etc/nginx/certs/ on the VM, add 443 server blocks
# (see deploy/nginx-test.conf.example, or the musilinda-test.conf already on the VM)
```

## 5. `/etc/hosts` (Mac) — point the names at the VM

```bash
# (sudo/you) — use the IP from step 1
sudo sh -c 'echo "192.168.252.2 app.musilinda.test learn.musilinda.test www.musilinda.test musilinda.test blog.musilinda.test" >> /etc/hosts'
```

## 6. Use it

| URL | Service |
|-----|---------|
| https://musilinda.test | marketing landing (`web`) — "Learn" CTA → `learn.musilinda.test` |
| https://app.musilinda.test | learning app (`app_musilinda`) |
| https://learn.musilinda.test | blog CMS (`blog`) |

Test account (created during setup): `httpsuser` / `pocpass123`.

---

## Notes / gotchas

- **VM IP can change** on `multipass stop/start`. If it does, update `/etc/hosts` (step 5).
- **Data is seed-only.** Lessons come from the app's seed; real users/posts/progress need the
  production DB dump (`pg_restore` into the VM's `musilinda`/`blog` DBs). Blog is empty until then.
- **Mic:** works only over HTTPS (`https://app.musilinda.test`) — secure context. `http://localhost`
  also works if you port-forward, but HTTPS `.test` is the clean path.
- **Inference API** is internal (`127.0.0.1:5000`), never exposed — reached via `app.musilinda.test/api/*`.
- **Teardown:** `multipass delete --purge musilinda`. Remove the `/etc/hosts` line when done.

## Automated: `deploy/local-dev.sh`

Steps 1–4 are automated by **`deploy/local-dev.sh`** (see Quick start above). It's idempotent —
re-run it to re-stage/re-provision an existing VM. The only things it can't do (your Mac
password): `mkcert -install` and editing `/etc/hosts` — it prints the exact commands at the end.

Not yet folded in (future): restoring a production DB dump, and building the `.dev`/`.com` tiers
via terraform (see `deploy/MILESTONES.md`).

## Dev loop — push code changes to the VM

The VM runs a **built** copy under systemd, so changes on the Mac don't auto-sync. Push one
service at a time with **`deploy/push-to-local-vm.sh`** (archive working tree → extract over
`/srv/musilinda/<svc>`, keeping `node_modules` → rebuild → restart the unit):

```bash
./deploy/push-to-local-vm.sh app_musilinda   # build + restart musilinda-app
./deploy/push-to-local-vm.sh blog            # build + restart musilinda-blog
./deploy/push-to-local-vm.sh web             # rebuild static dist (no restart)
./deploy/push-to-local-vm.sh api             # pip install + restart musilinda-api
```
Pushes tracked **and** uncommitted edits. If `package.json`/`requirements.txt` gained NEW deps,
run `npm ci` / `pip install` in the VM once (the script only builds).

## Capacitor simulator → VM

Point the iOS **simulator** at the VM (it inherits the Mac's `/etc/hosts` + reachability, so no
port-forward needed). In `capacitor/.env`:

```
CAP_SERVER_URL=https://app.musilinda.test
CAP_SERVER_CLEARTEXT=false
CAP_ALLOW_NAVIGATION=app.musilinda.test
```
```bash
cd capacitor && npx cap sync ios
xcrun simctl keychain booted add-root-cert "$(mkcert -CAROOT)/rootCA.pem"   # trust mkcert CA in the sim
```
Then run in Xcode. Flip back to the fast dev server by uncommenting the `localhost:5050` block and
re-running `cap sync`. (A **physical phone** can't reach the Multipass IP — that needs a Mac→VM
port-forward + the CA installed as an iOS profile.)
