#!/usr/bin/env bash
#
# bootstrap.sh — take a clean Ubuntu 24.04 host to a fully running Musilinda stack.
#
# The deploy IS this script: system deps, nginx (subdomain routing), Postgres with
# both DBs + migrations, the three app services under systemd, static `web` served by
# nginx, blob storage on the local filesystem, and the Flask API bound to localhost.
#
# Idempotent: safe to re-run. Config/secrets come from deploy/secrets.env.
#
# Usage:  sudo ./bootstrap.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets.env (required). Everything the operator must set lives there.
if [[ -f "${SCRIPT_DIR}/secrets.env" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "${SCRIPT_DIR}/secrets.env"
else
  echo "FATAL: ${SCRIPT_DIR}/secrets.env not found. Copy secrets.env.example and fill it in." >&2
  exit 1
fi

# Defaults (override via secrets.env or the environment).
DOMAIN="${DOMAIN:-musilinda.com}"
SRC_ROOT="${SRC_ROOT:-/srv/musilinda}"
RUN_USER="${RUN_USER:-musilinda}"
BLOB_STORAGE_DIR="${BLOB_STORAGE_DIR:-/var/lib/musilinda-blog/blob-store}"
ENV_DIR="/etc/musilinda"

API_PORT=5000
APP_PORT=5001
BLOG_PORT=5002
PYTHON_BIN="${PYTHON_BIN:-python3}"   # Ubuntu 24.04 default is 3.12; see walkthrough note.
NODE_MAJOR=20

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root (sudo ./bootstrap.sh)"
}

# Run a psql statement as the postgres superuser.
psql_super() { sudo -u postgres psql -v ON_ERROR_STOP=1 -tAc "$1"; }

# ---------------------------------------------------------------------------
# 0. Swap — an 8 GB box with no swap OOM-wedges during heavy installs
#    (unpacking the torch/deps stack, vite builds). Lightsail ships swapless.
# ---------------------------------------------------------------------------
SWAP_SIZE="${SWAP_SIZE:-4G}"
setup_swap() {
  if swapon --show --noheadings | grep -q .; then
    log "Swap already active — skipping"
    return 0
  fi
  log "Creating ${SWAP_SIZE} swapfile"
  fallocate -l "${SWAP_SIZE}" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
install_system_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git build-essential \
    nginx \
    postgresql postgresql-contrib \
    "${PYTHON_BIN}" "${PYTHON_BIN}-venv" "${PYTHON_BIN}-dev" \
    ffmpeg libsndfile1

  # Node.js 20 via NodeSource (only if not already the right major version).
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" != "${NODE_MAJOR}" ]]; then
    log "Installing Node.js ${NODE_MAJOR}"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
  fi
}

# ---------------------------------------------------------------------------
# 2. Run user + directories
# ---------------------------------------------------------------------------
setup_user_and_dirs() {
  log "Ensuring run user '${RUN_USER}' and directories"
  if ! id -u "${RUN_USER}" >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin "${RUN_USER}"
  fi
  install -d -o "${RUN_USER}" -g "${RUN_USER}" "${SRC_ROOT}"
  install -d -o "${RUN_USER}" -g "${RUN_USER}" "${BLOB_STORAGE_DIR}"
  install -d -o root -g root -m 0750 "${ENV_DIR}"
}

# ---------------------------------------------------------------------------
# 3. Postgres: two roles + two databases (idempotent)
# ---------------------------------------------------------------------------
setup_postgres() {
  log "Configuring Postgres roles and databases"
  systemctl enable --now postgresql

  _ensure_role() {  # name password
    local name="$1" pass="$2"
    if [[ "$(psql_super "SELECT 1 FROM pg_roles WHERE rolname='${name}'")" != "1" ]]; then
      psql_super "CREATE ROLE ${name} LOGIN PASSWORD '${pass}'"
    else
      psql_super "ALTER ROLE ${name} PASSWORD '${pass}'"
    fi
  }
  _ensure_db() {    # name owner
    local name="$1" owner="$2"
    if [[ "$(psql_super "SELECT 1 FROM pg_database WHERE datname='${name}'")" != "1" ]]; then
      sudo -u postgres createdb -O "${owner}" "${name}"
    fi
  }

  _ensure_role musilinda "${MUSILINDA_DB_PASSWORD:?set MUSILINDA_DB_PASSWORD in secrets.env}"
  _ensure_role blog       "${BLOG_DB_PASSWORD:?set BLOG_DB_PASSWORD in secrets.env}"
  _ensure_db   musilinda  musilinda
  _ensure_db   blog       blog
}

# ---------------------------------------------------------------------------
# 4. Per-service env files (systemd EnvironmentFile targets)
# ---------------------------------------------------------------------------
write_env_files() {
  log "Writing per-service env files to ${ENV_DIR}"

  umask 077
  cat > "${ENV_DIR}/api.env" <<EOF
SESSION_SECRET=${SESSION_SECRET:?set SESSION_SECRET in secrets.env}
EOF

  cat > "${ENV_DIR}/app_musilinda.env" <<EOF
NODE_ENV=production
PORT=${APP_PORT}
DATABASE_URL=postgresql://musilinda:${MUSILINDA_DB_PASSWORD}@localhost:5432/musilinda
AUDIO_API_BASE_URL=http://127.0.0.1:${API_PORT}
SESSION_SECRET=${SESSION_SECRET}
SENDGRID_API_KEY=${SENDGRID_API_KEY:-}
FRONTEND_URL=https://app.${DOMAIN}
EOF

  cat > "${ENV_DIR}/blog.env" <<EOF
NODE_ENV=production
PORT=${BLOG_PORT}
DATABASE_URL=postgresql://blog:${BLOG_DB_PASSWORD}@localhost:5432/blog
JWT_SECRET=${JWT_SECRET:?set JWT_SECRET in secrets.env}
BLOB_STORAGE_DIR=${BLOB_STORAGE_DIR}
EOF

  chmod 0640 "${ENV_DIR}"/*.env
  chown root:"${RUN_USER}" "${ENV_DIR}"/*.env
}

# ---------------------------------------------------------------------------
# 5. Source acquisition — stage or clone each service into SRC_ROOT
# ---------------------------------------------------------------------------
ensure_source() {  # service repo_var ref
  local svc="$1" repo="$2" ref="$3"
  local dir="${SRC_ROOT}/${svc}"
  if [[ -e "${dir}" ]] && [[ -n "$(ls -A "${dir}" 2>/dev/null)" ]]; then
    log "Source present: ${dir} (using as-is)"
    return 0
  fi
  if [[ -n "${repo}" ]]; then
    log "Cloning ${svc} from ${repo} (${ref})"
    sudo -u "${RUN_USER}" git clone --branch "${ref}" "${repo}" "${dir}"
  else
    die "No source for ${svc}: stage it at ${dir} or set ${svc^^}_REPO in secrets.env"
  fi
}

setup_sources() {
  log "Acquiring service sources"
  ensure_source api            "${API_REPO:-}"  "${API_REF:-claude/aws}"
  ensure_source app_musilinda  "${APP_REPO:-}"  "${APP_REF:-claude/aws}"
  ensure_source blog           "${BLOG_REPO:-}" "${BLOG_REF:-claude/aws}"
  ensure_source web            "${WEB_REPO:-}"  "${WEB_REF:-claude/aws}"
  chown -R "${RUN_USER}:${RUN_USER}" "${SRC_ROOT}"
}

# ---------------------------------------------------------------------------
# 6. Builds
# ---------------------------------------------------------------------------
build_api() {
  log "Building api (Python venv + model artifacts)"
  local dir="${SRC_ROOT}/api"
  sudo -u "${RUN_USER}" "${PYTHON_BIN}" -m venv "${dir}/.venv"
  sudo -u "${RUN_USER}" "${dir}/.venv/bin/pip" install --upgrade pip
  # CPU-only torch first: the default aarch64/x86 PyPI wheel drags in ~2.5 GB of
  # unused CUDA libs (this box has no GPU) and OOM-wedged the build. Installing the
  # CPU build up front satisfies torch/torchaudio so the requirements pass skips CUDA.
  sudo -u "${RUN_USER}" "${dir}/.venv/bin/pip" install --index-url https://download.pytorch.org/whl/cpu \
    torch torchaudio
  sudo -u "${RUN_USER}" "${dir}/.venv/bin/pip" install -r "${dir}/requirements.txt"
  # Gitignored model weights are fetched separately.
  sudo -u "${RUN_USER}" bash "${SCRIPT_DIR}/fetch-artifacts.sh" "${dir}"
}

_npm_build() {  # service
  local dir="${SRC_ROOT}/$1"
  # Prefer reproducible `npm ci`, but it requires a committed package-lock.json.
  # Fall back to `npm install` if the repo doesn't ship one (e.g. app_musilinda).
  if [[ -f "${dir}/package-lock.json" ]]; then
    sudo -u "${RUN_USER}" npm --prefix "${dir}" ci
  else
    warn "$1: no package-lock.json — using 'npm install' (non-reproducible; commit a lockfile)"
    sudo -u "${RUN_USER}" npm --prefix "${dir}" install
  fi
  sudo -u "${RUN_USER}" npm --prefix "${dir}" run build
}

build_app_musilinda() {
  log "Building app_musilinda (npm build + db push)"
  _npm_build app_musilinda
  sudo -u "${RUN_USER}" env DATABASE_URL="postgresql://musilinda:${MUSILINDA_DB_PASSWORD}@localhost:5432/musilinda" \
    npm --prefix "${SRC_ROOT}/app_musilinda" run db:push
}

build_blog() {
  log "Building blog (npm build + db push)"
  _npm_build blog
  sudo -u "${RUN_USER}" env DATABASE_URL="postgresql://blog:${BLOG_DB_PASSWORD}@localhost:5432/blog" \
    npm --prefix "${SRC_ROOT}/blog" run db:push
}

build_web() {
  log "Building web (static, env-driven cross-service links)"
  local dir="${SRC_ROOT}/web"
  if [[ -f "${dir}/package-lock.json" ]]; then
    sudo -u "${RUN_USER}" npm --prefix "${dir}" ci
  else
    sudo -u "${RUN_USER}" npm --prefix "${dir}" install
  fi
  # Inject this environment's learn/blog CMS URL into the landing "Learn" CTA
  # (Vite %VITE_LEARN_URL% replacement). Overrides web/client/.env's prod default.
  sudo -u "${RUN_USER}" env VITE_LEARN_URL="https://learn.${DOMAIN}" \
    npm --prefix "${dir}" run build
}

# ---------------------------------------------------------------------------
# 7. systemd units for the three long-running services
# ---------------------------------------------------------------------------
write_systemd_units() {
  log "Writing systemd units"

  cat > /etc/systemd/system/musilinda-api.service <<EOF
[Unit]
Description=Musilinda Flask inference API (gunicorn, localhost only)
After=network.target

[Service]
User=${RUN_USER}
WorkingDirectory=${SRC_ROOT}/api
EnvironmentFile=${ENV_DIR}/api.env
ExecStart=${SRC_ROOT}/api/.venv/bin/gunicorn --workers 1 --bind 127.0.0.1:${API_PORT} main:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/musilinda-app.service <<EOF
[Unit]
Description=Musilinda learning app (Express)
After=network.target postgresql.service

[Service]
User=${RUN_USER}
WorkingDirectory=${SRC_ROOT}/app_musilinda
EnvironmentFile=${ENV_DIR}/app_musilinda.env
ExecStart=/usr/bin/node dist/index.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/musilinda-blog.service <<EOF
[Unit]
Description=Musilinda blog CMS (Express)
After=network.target postgresql.service

[Service]
User=${RUN_USER}
WorkingDirectory=${SRC_ROOT}/blog
EnvironmentFile=${ENV_DIR}/blog.env
ExecStart=/usr/bin/node dist/index.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now musilinda-api.service musilinda-app.service musilinda-blog.service
  systemctl restart musilinda-api.service musilinda-app.service musilinda-blog.service
}

# ---------------------------------------------------------------------------
# 8. nginx: subdomain routing + static web
# ---------------------------------------------------------------------------
write_nginx() {
  log "Configuring nginx"
  # `vite build client` uses client/ as root, so output lands in web/client/dist.
  local web_root="${SRC_ROOT}/web/client/dist"

  cat > /etc/nginx/sites-available/musilinda.conf <<EOF
# app.${DOMAIN} -> app_musilinda
server {
    listen 80;
    server_name app.${DOMAIN};
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# learn.${DOMAIN} -> blog CMS (prod host is learn.; blog. kept as alias)
server {
    listen 80;
    server_name learn.${DOMAIN} blog.${DOMAIN};
    client_max_body_size 25m;
    location / {
        proxy_pass http://127.0.0.1:${BLOG_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# ${DOMAIN} + www -> static marketing site
server {
    listen 80 default_server;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${web_root};
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/musilinda.conf /etc/nginx/sites-enabled/musilinda.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl reload nginx
}

# ---------------------------------------------------------------------------
# 9. TLS via Let's Encrypt (certbot) — idempotent; no-op until DNS is pointed
# ---------------------------------------------------------------------------
# write_nginx() always (re)writes an HTTP-only config; certbot --nginx then
# injects the 443 server blocks + http->https redirect on top. On every redeploy
# we re-run certbot, which reuses the existing valid cert (only renews near
# expiry) and re-applies those edits — so HTTPS survives redeploys with no
# manual step. A box whose DNS isn't pointed yet simply stays HTTP (we skip any
# name that doesn't resolve to this box, so certbot never aborts the deploy).
ENABLE_TLS="${ENABLE_TLS:-true}"
TLS_EMAIL="${TLS_EMAIL:-trapadulli@gmail.com}"
setup_tls() {
  if [[ "${ENABLE_TLS}" != "true" ]]; then
    log "TLS disabled (ENABLE_TLS != true) — serving HTTP only"
    return 0
  fi
  log "Configuring TLS (Let's Encrypt via certbot)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx

  # Only request certs for names that resolve to THIS box. Otherwise certbot's
  # HTTP-01 challenge fails and would abort an otherwise-good deploy.
  local my_ip resolved d domains=()
  my_ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  for d in "app.${DOMAIN}" "learn.${DOMAIN}" "${DOMAIN}" "www.${DOMAIN}"; do
    resolved="$(getent ahostsv4 "${d}" 2>/dev/null | awk 'NR==1{print $1}')"
    if [[ -n "${resolved}" && ( -z "${my_ip}" || "${resolved}" == "${my_ip}" ) ]]; then
      domains+=(-d "${d}")
    else
      warn "TLS: ${d} -> ${resolved:-unresolved} (box is ${my_ip:-unknown}) — skipping"
    fi
  done

  if [[ ${#domains[@]} -eq 0 ]]; then
    warn "TLS: no names point at this box yet — staying HTTP. Point DNS at ${my_ip:-the box} and redeploy."
    return 0
  fi

  if certbot --nginx "${domains[@]}" \
      --non-interactive --agree-tos --keep-until-expiring --redirect \
      -m "${TLS_EMAIL}"; then
    systemctl reload nginx
    log "TLS active for:${domains[*]//-d/}"
  else
    warn "TLS: certbot failed — continuing on HTTP (check DNS propagation / LE rate limits)"
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  require_root
  setup_swap
  install_system_packages
  setup_user_and_dirs
  setup_postgres
  write_env_files
  setup_sources
  build_api
  build_app_musilinda
  build_blog
  build_web
  write_systemd_units
  write_nginx
  setup_tls
  log "Done. Services:"
  systemctl --no-pager --type=service --state=running | grep musilinda || true
  log "Test with: curl -H 'Host: app.${DOMAIN}' http://localhost/"
}

main "$@"
