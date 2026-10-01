#!/usr/bin/env bash
# 20-hardening.sh - security baseline.
# Key-only SSH, kernel/network sysctl hardening, auditd and a default-deny firewall.
set -euo pipefail
log() { printf '[hardening] %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# --- Settings (override with environment variables) -------------------------
FIREWALL_TCP_PORTS=${FIREWALL_TCP_PORTS:-"22 9100"}   # SSH, Prometheus node_exporter

# --- SSH --------------------------------------------------------------------
# The drop-in is written but sshd is deliberately NOT reloaded: Packer still
# logs in with a password for the remaining steps. The settings take effect on
# the first boot of every clone. "10-" sorts before cloud-init's "50-" file,
# and sshd keeps the first value it reads, so these settings win.
log "Installing SSH hardening drop-in"
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
chmod 0644 /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t   # fail the build if the config is invalid

# --- Kernel -----------------------------------------------------------------
log "Applying kernel and network hardening sysctl"
cat > /etc/sysctl.d/90-hardening.conf <<'EOF'
# Network
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
# Kernel
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl --system >/dev/null

# --- Auditing ---------------------------------------------------------------
log "Installing and enabling auditd"
apt-get install -y -q auditd
systemctl enable --now auditd

# --- Firewall ---------------------------------------------------------------
log "Configuring ufw: deny inbound except TCP ${FIREWALL_TCP_PORTS}"
apt-get install -y -q ufw
ufw default deny incoming
ufw default allow outgoing
for port in ${FIREWALL_TCP_PORTS}; do
  ufw allow "${port}/tcp"
done
ufw --force enable   # SSH is already allowed, so Packer's session survives
ufw status verbose

log "Done"
