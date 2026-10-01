#!/usr/bin/env bash
# 10-common.sh - baseline OS configuration.
# Packages, latest patches, timezone, time sync, journald limits,
# automatic security updates and image metadata.
set -euo pipefail
log() { printf '[common] %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

# --- Settings (override with environment variables) -------------------------
TIMEZONE=${TIMEZONE:-UTC}
JOURNALD_MAX_USE=${JOURNALD_MAX_USE:-500M}
PACKAGES=(
  bash-completion chrony cloud-guest-utils curl git htop jq lsof
  nfs-common rsync tmux tree unattended-upgrades unzip vim wget
)
REMOVE_PACKAGES=(snapd)

# --- Packages ---------------------------------------------------------------
log "Installing baseline packages"
apt-get update -q
apt-get install -y -q "${PACKAGES[@]}"

log "Removing unwanted packages: ${REMOVE_PACKAGES[*]}"
apt-get purge -y -q "${REMOVE_PACKAGES[@]}"

log "Upgrading to the latest patch level"
apt-get upgrade -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold

# --- Time -------------------------------------------------------------------
log "Setting timezone to ${TIMEZONE} and enabling chrony"
timedatectl set-timezone "${TIMEZONE}"
systemctl enable --now chrony

# --- Automatic security updates ---------------------------------------------
log "Enabling automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Journald ---------------------------------------------------------------
log "Capping journald disk usage at ${JOURNALD_MAX_USE}"
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-golden-image.conf <<EOF
[Journal]
SystemMaxUse=${JOURNALD_MAX_USE}
Compress=yes
EOF
systemctl restart systemd-journald

# --- Image metadata (traceability for every clone) ---------------------------
log "Writing /etc/golden-image-release"
cat > /etc/golden-image-release <<EOF
# Shell-sourceable: . /etc/golden-image-release && echo "\$IMAGE_VERSION"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-2404-golden}"
IMAGE_VERSION="${IMAGE_VERSION:-dev}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
BUILD_HYPERVISOR="${BUILD_HYPERVISOR:-unknown}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
chmod 0644 /etc/golden-image-release

cat > /etc/update-motd.d/05-golden-image <<'EOF'
#!/bin/sh
. /etc/golden-image-release
printf '\n  Golden image: %s  version %s  (Ubuntu %s)\n' "$IMAGE_NAME" "$IMAGE_VERSION" "$UBUNTU_VERSION"
roles=$(find /var/lib/golden-image/roles -name '*.done' -printf '%f ' 2>/dev/null | sed 's/\.done//g')
printf '  Roles: %s\n\n' "${roles:-none}"
EOF
chmod 0755 /etc/update-motd.d/05-golden-image

log "Done"
