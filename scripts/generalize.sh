#!/usr/bin/env bash
# generalize.sh - the Linux equivalent of Windows "sysprep /generalize".
#
# Removes everything that makes this machine unique so every VM cloned from
# the image boots as a brand-new machine:
#   - machine-id            (Windows: SID)
#   - SSH host keys         (regenerated on first boot)
#   - cloud-init state      (first-boot config runs again on every clone)
#   - installer network/datasource config, hostname, logs, history, caches
# The temporary build user is deleted by Packer's shutdown_command, right
# before power-off, because Packer is still logged in as that user here.
set -euo pipefail

log() { printf '[generalize] %s\n' "$*"; }
[[ ${EUID} -eq 0 ]] || { echo "generalize.sh must run as root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

log "1/8 Removing unused packages and package caches"
apt-get autoremove -y -q --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/needrestart/conf.d/99-packer-build.conf

log "2/8 Resetting cloud-init so every clone runs first boot again"
cloud-init clean --logs --seed
# Installer leftovers: they pin the datasource, disable cloud-init networking,
# and enable SSH password logins. Clones must get all of this from cloud-init.
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg \
      /etc/cloud/cloud.cfg.d/90-installer-network.cfg \
      /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg \
      /etc/cloud/ds-identify.cfg \
      /etc/ssh/sshd_config.d/50-cloud-init.conf

log "3/8 Removing installer network config and role state (clones get theirs from cloud-init)"
rm -f /etc/netplan/*.yaml
rm -f /etc/golden-image/roles /etc/golden-image/role.env
rm -rf /var/lib/golden-image/roles

log "4/8 Resetting machine identity"
truncate -s 0 /etc/machine-id          # empty file => new ID generated on first boot
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret

log "5/8 Removing SSH host keys (regenerated on first boot)"
rm -f /etc/ssh/ssh_host_*

log "6/8 Resetting hostname"
echo "localhost" > /etc/hostname
sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts

log "7/8 Clearing logs, temp files and shell history"
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -path /var/log/journal -prune -o -type f \
     \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -print0 | xargs -0r rm -f
find /var/log -path /var/log/journal -prune -o -type f -print0 | xargs -0r truncate -s 0
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
rm -f /root/.bash_history /home/*/.bash_history
unset HISTFILE

log "8/8 Releasing unused disk blocks (smaller image)"
fstrim -av || true
sync

log "Image generalized. Packer will now delete the build user and power off."
