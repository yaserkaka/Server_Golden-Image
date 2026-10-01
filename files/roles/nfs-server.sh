#!/usr/bin/env bash
# Role: nfs-server - shared storage for the other clones (e.g. hpc-compute nodes).
#
# Settings (role.env):
#   NFS_EXPORT_DIR     directory to export          (default: /srv/shared)
#   NFS_ALLOWED_CIDR   network allowed to mount it  (default: this clone's subnet)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NFS_EXPORT_DIR=${NFS_EXPORT_DIR:-/srv/shared}
NFS_ALLOWED_CIDR=${NFS_ALLOWED_CIDR:-$(ip -o -4 route show scope link | awk '{print $1; exit}')}
[[ -n ${NFS_ALLOWED_CIDR} ]] || { echo "nfs-server: cannot work out the local subnet, set NFS_ALLOWED_CIDR" >&2; exit 1; }

apt-get install -y -q nfs-kernel-server

# Shared scratch area: everyone can write, only owners can delete (like /tmp)
install -d -m 1777 "${NFS_EXPORT_DIR}"

install -d -m 0755 /etc/exports.d
echo "${NFS_EXPORT_DIR} ${NFS_ALLOWED_CIDR}(rw,sync,no_subtree_check)" > /etc/exports.d/golden-shared.exports
systemctl enable nfs-server
systemctl restart nfs-server
exportfs -ra

ufw allow from "${NFS_ALLOWED_CIDR}" to any port 2049 proto tcp comment 'NFSv4'

exportfs -v
echo "nfs-server: exporting ${NFS_EXPORT_DIR} to ${NFS_ALLOWED_CIDR}"
