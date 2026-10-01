#!/usr/bin/env bash
# prepare.sh - first Packer provisioner.
# Waits for the freshly installed system to settle so the provisioning
# scripts in scripts/provision/ can use apt without lock conflicts.
set -euo pipefail

log() { printf '[prepare] %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

log "Waiting for cloud-init to finish first boot"
cloud-init status --wait >/dev/null || true   # exit 2 = finished with warnings

log "Pausing background apt jobs for this boot so they don't hold the dpkg lock"
systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null; do
  log "apt/dpkg still running, waiting..."
  sleep 5
done

# needrestart would restart sshd after later apt runs, activating the hardened
# (key-only) SSH config while Packer still needs password logins. List-only
# mode for the build; generalize.sh removes this override.
if [[ -d /etc/needrestart ]]; then
  log "Setting needrestart to list-only for the build"
  mkdir -p /etc/needrestart/conf.d
  echo "\$nrconf{restart} = 'l';" > /etc/needrestart/conf.d/99-packer-build.conf
fi

log "Refreshing package lists"
apt-get update -q

log "Done"
