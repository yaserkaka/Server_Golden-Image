#!/usr/bin/env bash
# deploy.sh - clone VMs from the golden qcow2 image on KVM/libvirt.
#
# Each clone gets:
#   - a thin qcow2 overlay disk backed by the golden image (fast, space-efficient)
#   - its own cloud-init seed ISO (hostname, admin user + SSH key, network, roles)
# Hosts and their roles are listed in hosts.csv; role settings in roles.env.
# Re-running skips VMs that already exist.
#
# Usage:  sudo ./deploy/kvm/deploy.sh            # deploy everything in hosts.csv
#         DRY_RUN=1 ./deploy/kvm/deploy.sh       # render cloud-init files only
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

# When run through sudo, default to the invoking user's SSH key
INVOKING_HOME=${HOME}
if [[ -n ${SUDO_USER:-} ]]; then
  INVOKING_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
fi

IMAGE=${IMAGE:-${REPO_ROOT}/output/qemu/ubuntu-2404-golden.qcow2}
HOSTS_FILE=${HOSTS_FILE:-${SCRIPT_DIR}/hosts.csv}
POOL_DIR=${POOL_DIR:-/var/lib/libvirt/images/golden-clones}
LIBVIRT_URI=${LIBVIRT_URI:-qemu:///system}
LIBVIRT_NETWORK=${LIBVIRT_NETWORK:-default}
GATEWAY=${GATEWAY:-192.168.122.1}
DNS_SERVERS=${DNS_SERVERS:-192.168.122.1}
DOMAIN=${DOMAIN:-lab.local}
ADMIN_USER=${ADMIN_USER:-ops}
SSH_PUBKEY_FILE=${SSH_PUBKEY_FILE:-${INVOKING_HOME}/.ssh/id_ed25519.pub}
OS_VARIANT=${OS_VARIANT:-ubuntu24.04}
DRY_RUN=${DRY_RUN:-0}
ROLE_ENV_FILE=${ROLE_ENV_FILE:-${SCRIPT_DIR}/roles.env}
ROLES_SRC_DIR=${REPO_ROOT}/files/roles

# Only these variables are substituted; anything else (e.g. cloud-init's $UPTIME) is kept literally
# shellcheck disable=SC2016
TEMPLATE_VARS='${VM_NAME} ${INSTANCE_ID} ${VM_IP_CIDR} ${GATEWAY} ${DNS_SERVERS} ${DOMAIN} ${ADMIN_USER} ${SSH_PUBKEY} ${ROLES_BLOCK}'

log()  { printf '[deploy] %s\n' "$*"; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if [[ ${DRY_RUN} == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
  done
}

render() {  # render <template> <output>
  envsubst "${TEMPLATE_VARS}" < "${SCRIPT_DIR}/templates/$1" > "$2"
}

available_roles() {
  find "${ROLES_SRC_DIR}" -maxdepth 1 -name '*.sh' -printf '%f\n' | sed 's/\.sh$//' | sort | tr '\n' ' '
}

# roles_block "nfs-server+web" -> cloud-init YAML that hands the roles (and the
# shared settings from roles.env) to the clone and runs golden-role on first boot
roles_block() {
  local roles=$1 role
  [[ -n ${roles} ]] || return 0
  echo "write_files:"
  echo "  - path: /etc/golden-image/roles"
  echo "    permissions: \"0644\""
  echo "    content: |"
  for role in ${roles//+/ }; do echo "      ${role}"; done
  if [[ -f ${ROLE_ENV_FILE} ]]; then
    echo "  - path: /etc/golden-image/role.env"
    echo "    permissions: \"0600\""
    echo "    content: |"
    grep -Ev '^[[:space:]]*(#|$)' "${ROLE_ENV_FILE}" | sed 's/^/      /' || true
  fi
  echo "runcmd:"
  echo "  - [/usr/local/sbin/golden-role, apply]"
}

# --- Pre-flight -------------------------------------------------------------
require envsubst
if [[ ${DRY_RUN} == 1 ]]; then
  POOL_DIR="${SCRIPT_DIR}/.render"
  log "DRY_RUN=1: rendering cloud-init files into ${POOL_DIR}, no VMs will be created"
else
  require qemu-img cloud-localds virt-install virsh
  [[ -f ${IMAGE} ]] || die "golden image not found: ${IMAGE} (run 'make build-qemu' first)"
fi
[[ -f ${HOSTS_FILE} ]] || die "hosts file not found: ${HOSTS_FILE}"
[[ -f ${SSH_PUBKEY_FILE} ]] || die "SSH public key not found: ${SSH_PUBKEY_FILE} (set SSH_PUBKEY_FILE)"
SSH_PUBKEY=$(<"${SSH_PUBKEY_FILE}")
export GATEWAY DNS_SERVERS DOMAIN ADMIN_USER SSH_PUBKEY

# Check every role name before creating anything
while IFS=, read -r name _ _ _ _ roles; do
  [[ -z ${name} || ${name} == \#* ]] && continue
  roles=${roles%$'\r'}
  for role in ${roles//+/ }; do
    [[ -f ${ROLES_SRC_DIR}/${role}.sh ]] || die "${name}: unknown role '${role}' (available: $(available_roles))"
  done
done < "${HOSTS_FILE}"

mkdir -p "${POOL_DIR}"

# --- Base image -------------------------------------------------------------
# Copy the golden image into the libvirt pool once per build. The copy is named
# after the image's modification time, so rebuilding the image never changes
# the backing file of clones that already exist.
BASE_IMAGE="${POOL_DIR}/$(basename "${IMAGE}" .qcow2)-base-$( [[ -f ${IMAGE} ]] && stat -c %Y "${IMAGE}" || echo dryrun).qcow2"
if [[ ! -f ${BASE_IMAGE} ]]; then
  log "Copying golden image to ${BASE_IMAGE}"
  run cp --sparse=always "${IMAGE}" "${BASE_IMAGE}"
fi

# --- Clones -----------------------------------------------------------------
created=0
# Read the CSV on fd 3 so virsh/virt-install can't swallow the remaining lines from stdin
while IFS=, read -r name ip_cidr vcpus memory_mb disk_gb roles <&3; do
  [[ -z ${name} || ${name} == \#* ]] && continue
  disk_gb=${disk_gb%$'\r'}   # tolerate CRLF line endings
  roles=${roles%$'\r'}

  if [[ ${DRY_RUN} != 1 ]] && virsh --connect "${LIBVIRT_URI}" dominfo "${name}" >/dev/null 2>&1; then
    log "${name}: already exists, skipping"
    continue
  fi

  log "${name}: ${ip_cidr}, ${vcpus} vCPU, ${memory_mb} MB RAM, ${disk_gb} GB disk, roles: ${roles:-none}"
  vm_dir="${POOL_DIR}/${name}"
  mkdir -p "${vm_dir}"

  VM_NAME=${name}
  VM_IP_CIDR=${ip_cidr}
  INSTANCE_ID="${name}-$(date +%Y%m%d%H%M%S)"
  ROLES_BLOCK=$(roles_block "${roles}")
  export VM_NAME VM_IP_CIDR INSTANCE_ID ROLES_BLOCK
  render user-data.tpl "${vm_dir}/user-data"
  render meta-data.tpl "${vm_dir}/meta-data"
  if [[ ${ip_cidr} == dhcp ]]; then
    render network-config-dhcp.tpl "${vm_dir}/network-config"
  else
    render network-config-static.tpl "${vm_dir}/network-config"
  fi

  run cloud-localds --network-config="${vm_dir}/network-config" \
      "${vm_dir}/seed.iso" "${vm_dir}/user-data" "${vm_dir}/meta-data"

  run qemu-img create -q -f qcow2 -F qcow2 -b "${BASE_IMAGE}" \
      "${vm_dir}/disk.qcow2" "${disk_gb}G"

  run virt-install --connect "${LIBVIRT_URI}" \
      --name "${name}" \
      --memory "${memory_mb}" \
      --vcpus "${vcpus}" \
      --import \
      --disk "path=${vm_dir}/disk.qcow2,format=qcow2,bus=virtio,discard=unmap" \
      --disk "path=${vm_dir}/seed.iso,device=cdrom" \
      --network "network=${LIBVIRT_NETWORK},model=virtio" \
      --os-variant "${OS_VARIANT}" \
      --graphics none \
      --console pty,target_type=serial \
      --noautoconsole

  created=$((created + 1))
done 3< "${HOSTS_FILE}"

log "Done: ${created} VM(s) processed."
[[ ${DRY_RUN} == 1 ]] || log "Check them with: make verify   (first boot takes ~1 minute)"
