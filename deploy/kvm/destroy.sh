#!/usr/bin/env bash
# destroy.sh - remove the clones listed in hosts.csv (or named on the command line).
#
# Usage:  sudo ./deploy/kvm/destroy.sh                 # all hosts in hosts.csv
#         sudo ./deploy/kvm/destroy.sh node02          # specific VMs
#         sudo PURGE_BASE=1 ./deploy/kvm/destroy.sh    # also delete base image copies
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOSTS_FILE=${HOSTS_FILE:-${SCRIPT_DIR}/hosts.csv}
POOL_DIR=${POOL_DIR:-/var/lib/libvirt/images/golden-clones}
LIBVIRT_URI=${LIBVIRT_URI:-qemu:///system}
PURGE_BASE=${PURGE_BASE:-0}

log() { printf '[destroy] %s\n' "$*"; }

if [[ $# -gt 0 ]]; then
  names=("$@")
else
  mapfile -t names < <(awk -F, '!/^[[:space:]]*#/ && NF {print $1}' "${HOSTS_FILE}")
fi

for name in "${names[@]}"; do
  if virsh --connect "${LIBVIRT_URI}" dominfo "${name}" >/dev/null 2>&1; then
    log "${name}: stopping and undefining"
    virsh --connect "${LIBVIRT_URI}" destroy "${name}" >/dev/null 2>&1 || true
    virsh --connect "${LIBVIRT_URI}" undefine "${name}" >/dev/null
  else
    log "${name}: not defined"
  fi
  rm -rf "${POOL_DIR:?}/${name}"
done

if [[ ${PURGE_BASE} == 1 ]]; then
  log "Removing base image copies from ${POOL_DIR}"
  rm -f "${POOL_DIR}"/*-base-*.qcow2
fi

log "Done."
