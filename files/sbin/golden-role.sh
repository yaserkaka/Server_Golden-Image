#!/usr/bin/env bash
# golden-role - turn a generic clone into a specific server on first boot.
#
#   golden-role list                     roles available in this image
#   golden-role apply [--force] [ROLE..] apply roles (default: /etc/golden-image/roles)
#   golden-role status                   roles applied on this machine
#
# Roles are scripts in /usr/local/lib/golden-image/roles/<role>.sh.
# Which roles a clone gets, and their settings, come from cloud-init:
#   /etc/golden-image/roles      one role per line
#   /etc/golden-image/role.env   KEY=VALUE settings exported to every role
# Each role runs once. Re-running skips roles already applied unless --force.
set -euo pipefail

ROLES_DIR=${ROLES_DIR:-/usr/local/lib/golden-image/roles}
CONF_DIR=${CONF_DIR:-/etc/golden-image}
STATE_DIR=${STATE_DIR:-/var/lib/golden-image/roles}
LOG_FILE=${LOG_FILE:-/var/log/golden-role.log}
APT_UPDATE=${APT_UPDATE:-1}

log() { printf '[golden-role] %s\n' "$*" | tee -a "${LOG_FILE}" >&2; }
die() { log "ERROR: $*"; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

available_roles() {
  find "${ROLES_DIR}" -maxdepth 1 -name '*.sh' -printf '%f\n' 2>/dev/null | sed 's/\.sh$//' | sort
}

cmd_list() {
  available_roles
}

cmd_status() {
  local f found=0
  shopt -s nullglob
  for f in "${STATE_DIR}"/*.done "${STATE_DIR}"/*.failed; do
    found=1
    printf '%-14s %-7s %s\n' "$(basename "${f%.*}")" "${f##*.}" "$(<"${f}")"
  done
  [[ ${found} -eq 1 ]] || echo "no roles applied"
}

cmd_apply() {
  local force=0 role
  local -a roles=()

  if [[ ${1:-} == --force ]]; then force=1; shift; fi
  if [[ $# -gt 0 ]]; then
    roles=("$@")
  elif [[ -f ${CONF_DIR}/roles ]]; then
    mapfile -t roles < <(grep -Ev '^[[:space:]]*(#|$)' "${CONF_DIR}/roles" | tr -d '[:blank:]')
  fi
  if [[ ${#roles[@]} -eq 0 ]]; then
    log "no roles requested, nothing to do"
    return 0
  fi
  [[ ${EUID} -eq 0 ]] || die "apply must run as root"

  # Validate every role before changing anything
  for role in "${roles[@]}"; do
    if [[ ! ${role} =~ ^[a-z0-9-]+$ || ! -f ${ROLES_DIR}/${role}.sh ]]; then
      die "unknown role '${role}' (available: $(available_roles | tr '\n' ' '))"
    fi
  done

  install -d -m 0755 "${STATE_DIR}"
  touch "${LOG_FILE}"
  chmod 0640 "${LOG_FILE}"

  # Role settings, exported to every role script
  if [[ -f ${CONF_DIR}/role.env ]]; then
    set -a
    # shellcheck disable=SC1091
    . "${CONF_DIR}/role.env"
    set +a
  fi
  export GOLDEN_ROLES="${roles[*]}"

  if [[ ${APT_UPDATE} == 1 ]]; then
    log "refreshing package lists"
    apt-get update -q >>"${LOG_FILE}" 2>&1
  fi

  for role in "${roles[@]}"; do
    if [[ -f ${STATE_DIR}/${role}.done && ${force} -eq 0 ]]; then
      log "${role}: already applied on $(<"${STATE_DIR}/${role}.done"), skipping"
      continue
    fi
    log "${role}: applying"
    rm -f "${STATE_DIR}/${role}.done" "${STATE_DIR}/${role}.failed"
    if bash "${ROLES_DIR}/${role}.sh" 2>&1 | tee -a "${LOG_FILE}"; then
      now > "${STATE_DIR}/${role}.done"
      log "${role}: done"
    else
      now > "${STATE_DIR}/${role}.failed"
      die "${role}: FAILED (details in ${LOG_FILE})"
    fi
  done
  log "all roles applied: ${roles[*]}"
}

case ${1:-} in
  list)   cmd_list ;;
  status) cmd_status ;;
  apply)  shift; cmd_apply "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 2 ;;
esac
