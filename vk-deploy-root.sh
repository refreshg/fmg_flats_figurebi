#!/bin/bash
# Root-side half of the deploy, installed to /usr/local/sbin and owned by root.
#
# The deploying user is granted passwordless sudo for THIS SCRIPT ONLY. All
# paths are fixed constants below, so the caller cannot redirect the copy, the
# chown or the removal at anything else -- unlike whitelisting cp/rm/chown,
# which would be equivalent to full root.
#
# Install (run once, as root):
#   install -o root -g root -m 755 vk-deploy-root.sh /usr/local/sbin/vk-deploy-root
#   echo 'oddo ALL=(root) NOPASSWD: /usr/local/sbin/vk-deploy-root' \
#       > /etc/sudoers.d/vertikali-deploy
#   chmod 440 /etc/sudoers.d/vertikali-deploy && visudo -c
set -euo pipefail

SRC_DIR="/home/oddo/vertikali-src/vertikali"   # git checkout, fixed
ADDONS_DIR="/opt/odoo/custom-addons"
MODULE="vertikali"
DEST="$ADDONS_DIR/$MODULE"
DB="odoo"
ODOO_PY="/opt/odoo/odoo-19/venv/bin/python"
ODOO_BIN="/opt/odoo/odoo-19/odoo-bin"
ODOO_CONF="/etc/odoo/odoo.conf"

case "${1:-}" in
    install) FLAG="-i" ;;
    upgrade) FLAG="-u" ;;
    # Read-only inspection, so failures can be diagnosed without granting the
    # deploying user broader sudo rights.
    doctor)
        echo "--- addons dir ---";      ls -la "$ADDONS_DIR" 2>&1 | head
        echo "--- module files ---";    find "$DEST" -type f 2>&1 | head -20
        echo "--- addons_path ---";     grep addons_path "$ODOO_CONF" 2>&1
        echo "--- odoo user can read? ---"
        runuser -u odoo -- test -r "$DEST/__manifest__.py" \
            && echo "readable" || echo "NOT READABLE"
        echo "--- last deploy log ---"; tail -40 /tmp/vk-deploy-last.log 2>&1
        exit 0 ;;
    *) echo "usage: vk-deploy-root {install|upgrade|doctor}" >&2; exit 2 ;;
esac

[ -f "$SRC_DIR/__manifest__.py" ] || {
    echo "no module at $SRC_DIR" >&2; exit 1; }

echo "  syncing $SRC_DIR -> $DEST"
mkdir -p "$ADDONS_DIR"
rm -rf "${DEST:?}"
cp -r "$SRC_DIR" "$ADDONS_DIR/"
find "$DEST" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
chown -R odoo:odoo "$DEST"

echo "  stopping odoo"
systemctl stop odoo

# Already root here, so drop privileges with runuser: a nested `sudo -u odoo`
# would re-prompt for a password and abort the unattended run.
# Full output goes to a world-readable log so failures can be diagnosed after
# the fact -- piping straight to tail loses the traceback on error.
LOG="/tmp/vk-deploy-last.log"
set +e
runuser -u odoo -- "$ODOO_PY" "$ODOO_BIN" -c "$ODOO_CONF" -d "$DB" \
        "$FLAG" "$MODULE" --stop-after-init >"$LOG" 2>&1
RC=$?
set -e
chmod 644 "$LOG" 2>/dev/null || true
tail -30 "$LOG"
echo "  (full log: $LOG)"

echo "  starting odoo"
systemctl start odoo
sleep 3

if [ "$RC" -ne 0 ]; then
    echo "  FAILED (exit $RC) -- odoo restarted" >&2
    exit "$RC"
fi
systemctl is-active --quiet odoo && echo "  odoo running -- done" \
    || { echo "  WARNING: odoo not active" >&2; exit 1; }
