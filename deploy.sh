#!/bin/bash
# Deploy vertikali from git to the Odoo server.
#
#   ./deploy.sh          pull latest main and upgrade the module
#   ./deploy.sh install  first-time install
#
# Run this ON THE SERVER as a user with sudo rights.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/vertikali-src}"
REPO_URL="https://github.com/refreshg/fmg_flats_figurebi.git"
ADDONS_DIR="/opt/odoo/custom-addons"
MODULE="vertikali"
DB="odoo"
ODOO_BIN="/opt/odoo/odoo-19/odoo-bin"
ODOO_PY="/opt/odoo/odoo-19/venv/bin/python"
ODOO_CONF="/etc/odoo/odoo.conf"

MODE="${1:-upgrade}"
case "$MODE" in
    install) FLAG="-i" ;;
    upgrade) FLAG="-u" ;;
    *) echo "usage: $0 [install|upgrade]" >&2; exit 2 ;;
esac

echo "==> 1/5 fetching source"
if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" fetch --quiet origin
    git -C "$REPO_DIR" reset --hard --quiet origin/main
else
    git clone --quiet "$REPO_URL" "$REPO_DIR"
fi
echo "    $(git -C "$REPO_DIR" log --oneline -1)"

# bash reads this file as it executes, so a pull that changes deploy.sh would
# otherwise keep running the pre-pull version. Re-exec once if we changed.
if [ -z "${VK_REEXEC:-}" ] && [ -f "$REPO_DIR/deploy.sh" ]; then
    if ! cmp -s "$0" "$REPO_DIR/deploy.sh"; then
        echo "    deploy.sh changed -- restarting with the new version"
        chmod +x "$REPO_DIR/deploy.sh"
        VK_REEXEC=1 exec "$REPO_DIR/deploy.sh" "$MODE"
    fi
fi

# Refuse to deploy a tree that would not load: catches truncated pastes and
# bad merges before the service is stopped.
echo "==> 2/5 validating"
for f in __init__.py __manifest__.py models/product_template.py \
         views/menus.xml views/product_template_views.xml \
         security/ir.model.access.csv; do
    [ -f "$REPO_DIR/$MODULE/$f" ] || { echo "    MISSING: $f" >&2; exit 1; }
done
# Uses system python3: the odoo venv is not readable by the deploying user.
python3 - "$REPO_DIR/$MODULE" <<'PYEOF'
import ast, pathlib, sys, xml.dom.minidom as md
root = pathlib.Path(sys.argv[1])
for p in root.rglob("*.py"):
    ast.parse(p.read_text(encoding="utf-8"), filename=str(p))
for p in root.rglob("*.xml"):
    md.parse(str(p))
print("    python + xml OK")
PYEOF

# Preferred path: a root-owned wrapper with fixed paths, granted to this user
# through a single NOPASSWD sudoers entry, so the deploy can run unattended
# without handing out cp/rm/chown as root. See vk-deploy-root.sh for setup.
ROOT_HELPER="/usr/local/sbin/vk-deploy-root"

if [ -x "$ROOT_HELPER" ]; then
    echo "==> 3/5 sync + ${MODE} via root helper (service stops briefly)"
    sudo "$ROOT_HELPER" "$MODE"
    echo "==> 5/5 done"
    exit 0
fi

echo "==> 3/5 syncing to $ADDONS_DIR"
sudo mkdir -p "$ADDONS_DIR"
sudo rm -rf "${ADDONS_DIR:?}/$MODULE"
sudo cp -r "$REPO_DIR/$MODULE" "$ADDONS_DIR/"
sudo find "$ADDONS_DIR/$MODULE" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
sudo chown -R odoo:odoo "$ADDONS_DIR/$MODULE"

echo "==> 4/5 ${MODE}ing module (service stops briefly)"
sudo systemctl stop odoo
set +e
sudo -u odoo "$ODOO_PY" "$ODOO_BIN" -c "$ODOO_CONF" -d "$DB" \
     $FLAG "$MODULE" --stop-after-init 2>&1 | tail -25
RC=${PIPESTATUS[0]}
set -e
sudo systemctl start odoo

echo "==> 5/5 result"
if [ "$RC" -ne 0 ]; then
    echo "    FAILED (exit $RC) -- service restarted, module left as-is" >&2
    exit "$RC"
fi
sleep 3
sudo systemctl is-active --quiet odoo \
    && echo "    odoo is running -- $MODE complete" \
    || { echo "    WARNING: odoo is not active" >&2; exit 1; }
