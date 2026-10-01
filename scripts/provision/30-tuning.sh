#!/usr/bin/env bash
# 30-tuning.sh - OS performance tuning.
# A tuned profile plus a few sysctl settings for general server workloads.
set -euo pipefail
log() { printf '[tuning] %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# --- Settings (override with environment variables) -------------------------
# virtual-guest for VMs; throughput-performance for bare-metal compute nodes
TUNED_PROFILE=${TUNED_PROFILE:-virtual-guest}

log "Installing tuned and applying profile '${TUNED_PROFILE}'"
apt-get install -y -q tuned
systemctl enable --now tuned
tuned-adm profile "${TUNED_PROFILE}"
tuned-adm active

# tuned re-applies /etc/sysctl.d after its own values, so these win
log "Applying performance sysctl"
# (sysctl.d does not allow comments after a value, so they sit on their own lines)
cat > /etc/sysctl.d/91-performance.conf <<'EOF'
# Prefer dropping page cache over swapping
vm.swappiness = 10
# Keep dentry/inode caches longer
vm.vfs_cache_pressure = 50
# Larger listen backlog for busy services
net.core.somaxconn = 4096
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 2097152
EOF
sysctl --system >/dev/null

log "Done"
