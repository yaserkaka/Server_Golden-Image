#!/usr/bin/env bash
# 60-roles.sh - install the per-clone role system.
# The image stays generic. Each clone picks its roles at deploy time through
# cloud-init, and `golden-role apply` runs the matching scripts on first boot.
set -euo pipefail
log() { printf '[roles] %s\n' "$*"; }

FILES_DIR=${FILES_DIR:-/tmp/files}
ROLES_DIR=/usr/local/lib/golden-image/roles

log "Installing golden-role and role scripts"
install -m 0755 "${FILES_DIR}/sbin/golden-role.sh" /usr/local/sbin/golden-role
install -d -m 0755 "${ROLES_DIR}" /etc/golden-image
install -m 0644 "${FILES_DIR}"/roles/*.sh "${ROLES_DIR}/"
# Node-side helper for scripts/benchmark.sh (works once the hpc-bench role is applied)
install -m 0755 "${FILES_DIR}/sbin/hpc-bench-node.sh" /usr/local/bin/hpc-bench-node

log "Roles available in this image: $(golden-role list | tr '\n' ' ')"
log "Done"
