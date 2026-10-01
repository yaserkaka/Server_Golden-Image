#!/usr/bin/env bash
# verify-clones.sh - prove the generalization worked on deployed clones.
#
# Logs in to every clone and checks that each one is a unique, healthy machine:
#   - machine-id present and different on every clone
#   - SSH host key different on every clone
#   - cloud-init finished, node_exporter running, SSH password login disabled
#   - every role requested for the clone was applied (none failed)
#
# Usage:  ./scripts/verify-clones.sh                      # IPs from deploy/kvm/hosts.csv
#         ./scripts/verify-clones.sh 10.10.20.21 10.10.20.22
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOSTS_FILE=${HOSTS_FILE:-${SCRIPT_DIR}/../deploy/kvm/hosts.csv}
ADMIN_USER=${ADMIN_USER:-ops}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

if [[ $# -gt 0 ]]; then
  hosts=("$@")
else
  mapfile -t hosts < <(awk -F, '!/^[[:space:]]*#/ && NF && $2 != "dhcp" {split($2, a, "/"); print a[1]}' "${HOSTS_FILE}")
fi
[[ ${#hosts[@]} -gt 0 ]] || { echo "No hosts to verify" >&2; exit 1; }

# Runs on each clone; prints key=value lines
read -r -d '' REMOTE_CHECK <<'EOF' || true
. /etc/golden-image-release 2>/dev/null || true
echo "hostname=$(hostname)"
echo "machine_id=$(cat /etc/machine-id)"
echo "cloud_init=$(cloud-init status 2>/dev/null | awk '{print $2}')"
echo "node_exporter=$(systemctl is-active prometheus-node-exporter)"
echo "password_auth=$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')"
echo "root_size=$(df -h --output=size / | tail -n1 | tr -d ' ')"
echo "image=${IMAGE_VERSION:-unknown}"
roles_dir=/var/lib/golden-image/roles
echo "roles_requested=$(grep -Ev '^[[:space:]]*(#|$)' /etc/golden-image/roles 2>/dev/null | tr '\n' ' ')"
echo "roles_done=$(find "$roles_dir" -name '*.done' -printf '%f ' 2>/dev/null | sed 's/\.done//g')"
echo "roles_failed=$(find "$roles_dir" -name '*.failed' -printf '%f ' 2>/dev/null | sed 's/\.failed//g')"
EOF

declare -A seen_machine_id=() seen_host_key=()
failures=0
fail() { echo "  FAIL: $*"; failures=$((failures + 1)); }

printf '%-16s %-10s %-10s %-6s %-15s %s\n' "HOST" "HOSTNAME" "CLOUDINIT" "ROOT" "IMAGE" "ROLES"
for host in "${hosts[@]}"; do
  if ! out=$(ssh "${SSH_OPTS[@]}" "${ADMIN_USER}@${host}" "bash -s" <<<"${REMOTE_CHECK}" 2>/dev/null); then
    printf '%-16s unreachable\n' "${host}"
    fail "${host}: cannot SSH as ${ADMIN_USER}"
    continue
  fi

  declare -A r=([hostname]="" [machine_id]="" [cloud_init]="" [node_exporter]="" [password_auth]="" [root_size]=""
                [image]="" [roles_requested]="" [roles_done]="" [roles_failed]="")
  while IFS='=' read -r key value; do
    if [[ -n ${key} ]]; then r[${key}]=${value}; fi
  done <<<"${out}"
  host_key=$(ssh-keyscan -t ed25519 "${host}" 2>/dev/null | awk '{print $3}')
  mid=${r[machine_id]}

  roles_col=$(xargs <<<"${r[roles_done]}" | tr ' ' '+')
  printf '%-16s %-10s %-10s %-6s %-15s %s\n' "${host}" "${r[hostname]}" "${r[cloud_init]}" "${r[root_size]}" \
         "${r[image]}" "${roles_col:--}"

  [[ -n ${mid} ]]                     || fail "${host}: empty machine-id"
  [[ -n ${host_key} ]]                || fail "${host}: no ed25519 host key"
  [[ ${r[cloud_init]} == "done" ]]    || fail "${host}: cloud-init status is '${r[cloud_init]}'"
  [[ ${r[node_exporter]} == active ]] || fail "${host}: node_exporter is '${r[node_exporter]}'"
  [[ ${r[password_auth]} == no ]]     || fail "${host}: SSH password authentication is '${r[password_auth]}'"

  for role in ${r[roles_requested]}; do
    [[ " ${r[roles_done]} " == *" ${role} "* ]] || fail "${host}: role '${role}' was not applied (see /var/log/golden-role.log)"
  done
  [[ -z ${r[roles_failed]// /} ]] || fail "${host}: failed role(s): ${r[roles_failed]}"

  if [[ -n ${mid} ]]; then
    if [[ -n ${seen_machine_id[${mid}]:-} ]]; then
      fail "${host}: duplicate machine-id (same as ${seen_machine_id[${mid}]})"
    fi
    seen_machine_id[${mid}]=${host}
  fi

  if [[ -n ${host_key} ]]; then
    if [[ -n ${seen_host_key[${host_key}]:-} ]]; then
      fail "${host}: duplicate SSH host key (same as ${seen_host_key[${host_key}]})"
    fi
    seen_host_key[${host_key}]=${host}
  fi
  unset r
done

echo
if [[ ${failures} -eq 0 ]]; then
  echo "PASS: ${#hosts[@]} clone(s) are unique and healthy."
else
  echo "FAILED: ${failures} problem(s) found."
  exit 1
fi
