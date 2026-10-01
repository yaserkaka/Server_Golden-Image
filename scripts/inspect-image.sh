#!/usr/bin/env bash
# inspect-image.sh - offline "sysprep check" of the built qcow2 image.
# Opens the image read-only with libguestfs (no VM boot) and confirms that
# nothing machine-specific was left behind.
#
# Usage:  ./scripts/inspect-image.sh [image.qcow2]
# Needs:  libguestfs-tools  (sudo apt install libguestfs-tools)
set -euo pipefail

IMAGE=${1:-output/qemu/ubuntu-2404-golden.qcow2}
BUILD_USER=${BUILD_USER:-packer}
[[ -f ${IMAGE} ]] || { echo "Image not found: ${IMAGE}" >&2; exit 1; }
command -v guestfish >/dev/null || { echo "guestfish not found: install libguestfs-tools" >&2; exit 1; }

echo "Inspecting ${IMAGE} (read-only)..."

# One guestfish session, one key=value line per check
report=$(guestfish --ro -a "${IMAGE}" -i <<'EOF'
-echo machine_id_size=
-filesize /etc/machine-id
-echo host_keys=
-glob ls /etc/ssh/ssh_host_*
-echo netplan_files=
-ls /etc/netplan
-echo cloud_instances=
-ls /var/lib/cloud/instances
-echo installer_cfg=
-glob ls /etc/cloud/cloud.cfg.d/99-installer.cfg
-echo passwd=
-cat /etc/passwd
-echo release=
-cat /etc/golden-image-release
-echo roles_installed=
-ls /usr/local/lib/golden-image/roles
-echo role_state=
-ls /var/lib/golden-image/roles
EOF
) || true

# guestfish prints each value on the line after its label; fold them together
section() { awk -v key="$1=" '$0 == key {flag=1; next} /^[a-z_]+=$/ {flag=0} flag' <<<"${report}"; }

failures=0
check() {  # check <description> <command...>
  if "${@:2}"; then echo "  PASS  $1"; else echo "  FAIL  $1"; failures=$((failures + 1)); fi
}
is_zero()  { [[ $(section "$1" | head -n1) == 0 ]]; }
is_empty() { [[ -z $(section "$1" | grep -v '^$' || true) ]]; }
no_user()  { ! section passwd | grep -q "^${BUILD_USER}:"; }
has_meta() { section release | grep -q '^IMAGE_VERSION='; }
has_roles() { section roles_installed | grep -q '\.sh$'; }

check "machine-id is empty (new ID on first boot)"   is_zero  machine_id_size
check "no SSH host keys baked in"                    is_empty host_keys
check "no installer netplan config"                  is_empty netplan_files
check "cloud-init state is clean"                    is_empty cloud_instances
check "installer cloud-init config removed"          is_empty installer_cfg
check "build user '${BUILD_USER}' removed"           no_user
check "image metadata present"                       has_meta
check "role scripts installed"                       has_roles
check "no role state baked in"                       is_empty role_state

echo
if [[ ${failures} -eq 0 ]]; then
  echo "PASS: image is generalized and ready to clone."
else
  echo "FAILED: ${failures} check(s) failed."
  exit 1
fi
