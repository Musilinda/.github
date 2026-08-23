#!/usr/bin/env bash
#
# deploy-to-box.sh — provision/redeploy the Musilinda stack onto a remote box over SSH.
# The CI cousin of local-dev.sh: Lightsail has no IAM roles, so CI SSHes in and pushes
# everything (source + secrets + model weights + bootstrap). Idempotent — re-run to redeploy.
#
# Required env:
#   BOX_IP                 public IP of the box
#   DOMAIN                 e.g. dev.musilinda.com
#   SRC_DIR                dir holding checked-out service repos: $SRC_DIR/{api,app_musilinda,blog,web}
#   DEPLOY_DIR             the deploy/ dir (bootstrap.sh, fetch-artifacts.sh)
#   MUSILINDA_DB_PASSWORD BLOG_DB_PASSWORD SESSION_SECRET JWT_SECRET SENDGRID_API_KEY
# Optional:
#   SSH_USER (default ubuntu)
#
# Assumes the api model weights are already present under $SRC_DIR/api/ (the workflow
# pulls them from S3 before calling this) so they ride along in the api tar.
#
set -euo pipefail

: "${BOX_IP:?}"; : "${DOMAIN:?}"; : "${SRC_DIR:?}"; : "${DEPLOY_DIR:?}"
: "${MUSILINDA_DB_PASSWORD:?}"; : "${BLOG_DB_PASSWORD:?}"
: "${SESSION_SECRET:?}"; : "${JWT_SECRET:?}"; SENDGRID_API_KEY="${SENDGRID_API_KEY:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
REMOTE="${SSH_USER}@${BOX_IP}"

# commands are composed here and intentionally executed on the remote box
# shellcheck disable=SC2029
run() { ssh "${SSH_OPTS[@]}" "$REMOTE" "$@"; }

echo "==> waiting for SSH on ${BOX_IP}"
for _ in $(seq 1 30); do run true 2>/dev/null && break; sleep 10; done

echo "==> preparing dirs on the box"
run "sudo mkdir -p /srv/musilinda/api /srv/musilinda/app_musilinda /srv/musilinda/blog /srv/musilinda/web /opt/musilinda-deploy && sudo chown -R ${SSH_USER}:${SSH_USER} /srv/musilinda"

echo "==> staging service source"
for s in api app_musilinda blog web; do
  tar -C "${SRC_DIR}/${s}" -cf "/tmp/${s}.tar" .
  scp "${SSH_OPTS[@]}" "/tmp/${s}.tar" "${REMOTE}:/tmp/${s}.tar"
  run "sudo tar xf /tmp/${s}.tar -C /srv/musilinda/${s} && sudo chown -R ${SSH_USER}:${SSH_USER} /srv/musilinda/${s}"
done

echo "==> writing secrets.env + deploy scripts"
umask 077
cat > /tmp/secrets.env <<EOF
DOMAIN=${DOMAIN}
MUSILINDA_DB_PASSWORD=${MUSILINDA_DB_PASSWORD}
BLOG_DB_PASSWORD=${BLOG_DB_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
JWT_SECRET=${JWT_SECRET}
SENDGRID_API_KEY=${SENDGRID_API_KEY}
EOF
scp "${SSH_OPTS[@]}" "${DEPLOY_DIR}/bootstrap.sh" "${DEPLOY_DIR}/fetch-artifacts.sh" /tmp/secrets.env "${REMOTE}:/tmp/"
run "sudo cp /tmp/bootstrap.sh /tmp/fetch-artifacts.sh /tmp/secrets.env /opt/musilinda-deploy/ && sudo chmod 755 /opt/musilinda-deploy/*.sh && sudo chmod 600 /opt/musilinda-deploy/secrets.env && rm -f /tmp/secrets.env"
rm -f /tmp/secrets.env

echo "==> running bootstrap on the box (installs stack, builds, systemd, nginx)"
run "sudo bash /opt/musilinda-deploy/bootstrap.sh"

echo "==> done: ${DOMAIN} @ ${BOX_IP}"
echo "    (TLS: run certbot once DNS for app./learn./${DOMAIN} points at ${BOX_IP})"
