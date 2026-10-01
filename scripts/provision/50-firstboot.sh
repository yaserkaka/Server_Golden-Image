#!/usr/bin/env bash
# 50-firstboot.sh - everything a clone needs to turn itself into a unique,
# correctly sized machine on its first boot.
# The files come from the repo's files/ folder, uploaded by Packer to FILES_DIR.
set -euo pipefail
log() { printf '[firstboot] %s\n' "$*"; }

FILES_DIR=${FILES_DIR:-/tmp/files}
[[ -d ${FILES_DIR} ]] || { echo "FILES_DIR not found: ${FILES_DIR}" >&2; exit 1; }

log "Installing cloud-init defaults for clones"
install -m 0644 "${FILES_DIR}/cloud/95-golden-image.cfg" /etc/cloud/cloud.cfg.d/95-golden-image.cfg

log "Installing SSH host key fallback and root LV auto-grow"
install -m 0755 "${FILES_DIR}/sbin/grow-root-lv.sh" /usr/local/sbin/grow-root-lv
install -m 0644 "${FILES_DIR}/systemd/regenerate-ssh-host-keys.service" /etc/systemd/system/
install -m 0644 "${FILES_DIR}/systemd/grow-root-lv.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable regenerate-ssh-host-keys.service grow-root-lv.service

log "Done"
