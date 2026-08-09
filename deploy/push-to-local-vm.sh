#!/usr/bin/env bash
#
# push-to-local-vm.sh <service> — push one service's current working tree into the running
# Multipass VM, rebuild it, and restart its systemd unit. The local dev loop:
# edit on the Mac -> reflect on the VM (and in the Capacitor sim pointing at the VM).
#
#   ./deploy/push-to-local-vm.sh app_musilinda
#   ./deploy/push-to-local-vm.sh blog
#   ./deploy/push-to-local-vm.sh web            # static; rebuilds dist, no restart
#   ./deploy/push-to-local-vm.sh api            # pip install (in case deps changed) + restart
#
# Pushes tracked files + uncommitted edits (via `git stash create`); node_modules/.venv
# on the VM are kept (extracts over the existing dir). If package.json / requirements.txt
# gained NEW deps, run `npm ci` / `pip install` in the VM once — this script only builds.
#
set -euo pipefail

SVC="${1:?usage: push-to-local-vm.sh <api|app_musilinda|blog|web>}"
VM_NAME="${VM_NAME:-musilinda}"
SRC_ROOT="/srv/musilinda"
RUN_USER="musilinda"
# web landing "Learn" CTA target for the local VM (override if needed)
LEARN_URL="${VITE_LEARN_URL:-https://learn.musilinda.test}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$SVC" in api|app_musilinda|blog|web) ;; *) echo "unknown service: $SVC (api|app_musilinda|blog|web)" >&2; exit 1 ;; esac
cd "$REPO_ROOT"
[[ -d "$SVC" ]] || { echo "no such service dir: $REPO_ROOT/$SVC" >&2; exit 1; }
multipass info "$VM_NAME" >/dev/null 2>&1 || { echo "VM '$VM_NAME' not running" >&2; exit 1; }

echo "==> archiving $SVC working tree (tracked + uncommitted)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SHA="$(git -C "$SVC" stash create || true)"   # empty if nothing uncommitted
git -C "$SVC" archive "${SHA:-HEAD}" -o "$TMP/$SVC.tar"

echo "==> transferring + extracting over $SRC_ROOT/$SVC (node_modules kept)"
multipass transfer "$TMP/$SVC.tar" "$VM_NAME:/home/ubuntu/$SVC.tar"
multipass exec "$VM_NAME" -- sudo bash -c "
  tar xf /home/ubuntu/$SVC.tar -C $SRC_ROOT/$SVC
  chown -R $RUN_USER:$RUN_USER $SRC_ROOT/$SVC
"

echo "==> rebuild + restart"
case "$SVC" in
  api)
    multipass exec "$VM_NAME" -- sudo -u "$RUN_USER" "$SRC_ROOT/api/.venv/bin/pip" install -q -r "$SRC_ROOT/api/requirements.txt"
    multipass exec "$VM_NAME" -- sudo systemctl restart musilinda-api
    ;;
  app_musilinda)
    multipass exec "$VM_NAME" -- sudo -u "$RUN_USER" npm --prefix "$SRC_ROOT/app_musilinda" run build
    multipass exec "$VM_NAME" -- sudo systemctl restart musilinda-app
    ;;
  blog)
    multipass exec "$VM_NAME" -- sudo -u "$RUN_USER" npm --prefix "$SRC_ROOT/blog" run build
    multipass exec "$VM_NAME" -- sudo systemctl restart musilinda-blog
    ;;
  web)
    multipass exec "$VM_NAME" -- sudo -u "$RUN_USER" env VITE_LEARN_URL="$LEARN_URL" npm --prefix "$SRC_ROOT/web" run build
    echo "   (web is static — nginx serves web/client/dist, no service restart)"
    ;;
esac

echo "==> done: $SVC pushed to $VM_NAME. Reload the app in the sim/browser."
