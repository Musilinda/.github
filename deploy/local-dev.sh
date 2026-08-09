#!/usr/bin/env bash
#
# local-dev.sh — stand up the whole Musilinda stack in a local Multipass VM,
# served over HTTPS at *.musilinda.test (the `.test` tier of the DOMAIN-keyed model).
#
# Run from the repo root on your Mac:  ./deploy/local-dev.sh
#
# What it does: launch VM → stage source/secrets/model weights → run bootstrap.sh →
# issue an mkcert cert → enable HTTPS in nginx → print the /etc/hosts line to add.
#
# Idempotent-ish: re-running reuses an existing VM and re-stages/re-provisions.
# Two steps need YOUR sudo (printed at the end): `mkcert -install` and editing /etc/hosts.
#
set -euo pipefail

# ---- config (override via env) ---------------------------------------------
VM_NAME="${VM_NAME:-musilinda}"
DOMAIN="${DOMAIN:-musilinda.test}"
VM_MEM="${VM_MEM:-8G}"; VM_DISK="${VM_DISK:-25G}"; VM_CPUS="${VM_CPUS:-4}"
API_REF="${API_REF:-claude/aws}"; APP_REF="${APP_REF:-claude/aws}"
WEB_REF="${WEB_REF:-claude/aws}"; BLOG_REF="${BLOG_REF:-claude/aws}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 0. preflight ----------------------------------------------------------
command -v multipass >/dev/null || die "multipass not installed (brew install multipass)"
command -v mkcert    >/dev/null || die "mkcert not installed (brew install mkcert && mkcert -install)"
command -v git       >/dev/null || die "git not found"
cd "${REPO_ROOT}"
for d in api app_musilinda blog web; do [[ -d "$d" ]] || die "run from repo root; missing $d/"; done
[[ -s api/whisper_model/model.safetensors && -s api/whisper_multihead_model.pt ]] \
  || die "api model weights missing locally (whisper_model/model.safetensors + whisper_multihead_model.pt)"

# ---- 1. secrets.env (generate for local if absent) -------------------------
if [[ ! -f deploy/secrets.env ]]; then
  log "Generating deploy/secrets.env for local (DOMAIN=${DOMAIN})"
  cat > deploy/secrets.env <<EOF
DOMAIN=${DOMAIN}
MUSILINDA_DB_PASSWORD=$(openssl rand -hex 16)
BLOG_DB_PASSWORD=$(openssl rand -hex 16)
SESSION_SECRET=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
SENDGRID_API_KEY=SG.placeholder-local-not-a-real-key
EOF
  chmod 600 deploy/secrets.env
else
  log "Using existing deploy/secrets.env"
fi

# DOMAIN is the single source of truth in secrets.env (same file bootstrap sources),
# so the mkcert cert + nginx HTTPS names match what the box is actually provisioned with.
# shellcheck disable=SC1091
source deploy/secrets.env
DOMAIN="${DOMAIN:-musilinda.test}"
log "DOMAIN=${DOMAIN}"

# ---- 2. launch VM ----------------------------------------------------------
if multipass info "${VM_NAME}" >/dev/null 2>&1; then
  log "VM '${VM_NAME}' exists — reusing"
else
  log "Launching VM '${VM_NAME}' (Ubuntu 24.04, ${VM_MEM}/${VM_CPUS}cpu/${VM_DISK})"
  multipass launch 24.04 --name "${VM_NAME}" --memory "${VM_MEM}" --disk "${VM_DISK}" --cpus "${VM_CPUS}"
fi
VM_IP="$(multipass info "${VM_NAME}" | awk '/IPv4/{print $2}')"
[[ -n "${VM_IP}" ]] || die "could not determine VM IP"
log "VM IP: ${VM_IP}"

# ---- 3. stage source, model weights, deploy scripts ------------------------
log "Staging source into the VM"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
git -C api           archive "${API_REF}"  -o "${TMP}/api.tar"
git -C app_musilinda archive "${APP_REF}"  -o "${TMP}/app_musilinda.tar"
git -C web           archive "${WEB_REF}"  -o "${TMP}/web.tar"
git -C blog          archive "${BLOG_REF}" -o "${TMP}/blog.tar"

multipass exec "${VM_NAME}" -- sudo mkdir -p /srv/musilinda/{api,app_musilinda,blog,web} /opt/musilinda-deploy
for s in api app_musilinda blog web; do
  multipass transfer "${TMP}/${s}.tar" "${VM_NAME}:/home/ubuntu/${s}.tar"
  multipass exec "${VM_NAME}" -- sudo tar xf "/home/ubuntu/${s}.tar" -C "/srv/musilinda/${s}"
done
# gitignored model weights
multipass transfer api/whisper_multihead_model.pt "${VM_NAME}:/home/ubuntu/"
multipass transfer api/whisper_model/model.safetensors "${VM_NAME}:/home/ubuntu/"
multipass exec "${VM_NAME}" -- sudo bash -c '
  cp /home/ubuntu/whisper_multihead_model.pt /srv/musilinda/api/
  mkdir -p /srv/musilinda/api/whisper_model
  cp /home/ubuntu/model.safetensors /srv/musilinda/api/whisper_model/'
# deploy scripts + secrets to a world-traversable path (fetch-artifacts runs as unpriv user)
multipass transfer deploy/bootstrap.sh deploy/fetch-artifacts.sh deploy/secrets.env "${VM_NAME}:/home/ubuntu/"
multipass exec "${VM_NAME}" -- sudo bash -c '
  cp /home/ubuntu/bootstrap.sh /home/ubuntu/fetch-artifacts.sh /home/ubuntu/secrets.env /opt/musilinda-deploy/
  chmod 755 /opt/musilinda-deploy/*.sh; chmod 600 /opt/musilinda-deploy/secrets.env'

# ---- 4. provision ----------------------------------------------------------
log "Running bootstrap.sh in the VM (first run pulls torch/npm — several minutes)"
multipass exec "${VM_NAME}" -- sudo bash /opt/musilinda-deploy/bootstrap.sh

# ---- 5. HTTPS via mkcert ---------------------------------------------------
log "Issuing mkcert cert for *.${DOMAIN} and enabling HTTPS"
( cd "${TMP}" && mkcert "app.${DOMAIN}" "learn.${DOMAIN}" "www.${DOMAIN}" "${DOMAIN}" "blog.${DOMAIN}" >/dev/null 2>&1 )
CERT=""; KEY=""
for f in "${TMP}"/*+*.pem; do
  case "$f" in *-key.pem) KEY="$f" ;; *) CERT="$f" ;; esac
done
[[ -s "${CERT}" && -s "${KEY}" ]] || die "mkcert did not produce cert/key in ${TMP}"

# Build the nginx HTTPS config locally: ${DOMAIN} expands here, nginx runtime
# vars stay literal via \$. Then ship the finished file (no nested-heredoc escaping).
cat > "${TMP}/musilinda-https.conf" <<CONF
map \$host \$svc_upstream {
    app.${DOMAIN}   127.0.0.1:5001;
    learn.${DOMAIN} 127.0.0.1:5002;
    blog.${DOMAIN}  127.0.0.1:5002;
}
server {
    listen 443 ssl;
    server_name app.${DOMAIN} learn.${DOMAIN} blog.${DOMAIN};
    ssl_certificate     /etc/nginx/certs/musilinda-test.pem;
    ssl_certificate_key /etc/nginx/certs/musilinda-test-key.pem;
    client_max_body_size 25m;
    location / {
        proxy_pass http://\$svc_upstream;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};
    ssl_certificate     /etc/nginx/certs/musilinda-test.pem;
    ssl_certificate_key /etc/nginx/certs/musilinda-test-key.pem;
    root /srv/musilinda/web/client/dist;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
CONF

multipass transfer "${CERT}" "${VM_NAME}:/home/ubuntu/test-cert.pem"
multipass transfer "${KEY}"  "${VM_NAME}:/home/ubuntu/test-key.pem"
multipass transfer "${TMP}/musilinda-https.conf" "${VM_NAME}:/home/ubuntu/musilinda-https.conf"
multipass exec "${VM_NAME}" -- sudo bash -c '
  install -d -m 0750 /etc/nginx/certs
  mv /home/ubuntu/test-cert.pem /etc/nginx/certs/musilinda-test.pem
  mv /home/ubuntu/test-key.pem  /etc/nginx/certs/musilinda-test-key.pem
  chmod 0640 /etc/nginx/certs/*.pem; chown root:www-data /etc/nginx/certs/*.pem
  mv /home/ubuntu/musilinda-https.conf /etc/nginx/sites-available/musilinda-https.conf
  ln -sf /etc/nginx/sites-available/musilinda-https.conf /etc/nginx/sites-enabled/musilinda-https.conf
  nginx -t && systemctl reload nginx'

# ---- 6. done ---------------------------------------------------------------
cat <<DONE

$(printf '\033[1;32m==> Local stack is up.\033[0m')

Two steps only YOU can do (need your Mac password) — run in the prompt with '!':

  1) trust the local CA (one-time):        mkcert -install
  2) point the hostnames at the VM:
       sudo sh -c 'echo "${VM_IP} app.${DOMAIN} learn.${DOMAIN} www.${DOMAIN} ${DOMAIN} blog.${DOMAIN}" >> /etc/hosts'

Then browse (valid cert, HTTPS):
  https://${DOMAIN}          marketing (Learn CTA -> learn.${DOMAIN})
  https://app.${DOMAIN}      learning app
  https://learn.${DOMAIN}    blog CMS

Notes: data is seed-only until a prod DB dump is restored. VM IP can change on restart
(re-run this script or update /etc/hosts). Teardown: multipass delete --purge ${VM_NAME}
DONE
