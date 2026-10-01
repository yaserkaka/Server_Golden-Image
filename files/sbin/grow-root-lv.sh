#!/usr/bin/env bash
# grow-root-lv - grow the root LVM volume to fill the disk.
# cloud-init's growpart does not handle LVM, so clones deployed with a larger
# disk than the template would otherwise keep the template's root size.
# Safe to run on every boot: it does nothing when there is no free space.
set -euo pipefail

root_dev=$(findmnt -no SOURCE /)

# Map the root device (/dev/mapper/vg-lv) to its volume group and LV name
vg="" lv=""
read -r vg lv < <(lvs --noheadings -o vg_name,lv_name,lv_dm_path 2>/dev/null |
                  awk -v dev="${root_dev}" '$3 == dev {print $1, $2}') || true
if [[ -z ${vg} ]]; then
  echo "grow-root-lv: / is not on LVM (${root_dev}), nothing to do"
  exit 0
fi
lv_path="/dev/${vg}/${lv}"
pv=$(pvs --noheadings -o pv_name -S vg_name="${vg}" | head -n1 | tr -d '[:space:]')

# 1. Grow the partition holding the PV (growpart exit 1 = NOCHANGE, which is fine)
part_file="/sys/class/block/$(basename "${pv}")/partition"
if [[ -r ${part_file} ]]; then
  disk="/dev/$(lsblk -no pkname "${pv}" | head -n1)"
  rc=0
  growpart "${disk}" "$(cat "${part_file}")" || rc=$?
  if [[ ${rc} -gt 1 ]]; then
    echo "grow-root-lv: growpart failed (rc=${rc})" >&2
    exit "${rc}"
  fi
fi

# 2. Grow the physical volume, then the root LV and its filesystem
pvresize "${pv}"
free_extents=$(vgs --noheadings -o vg_free_count "${vg}" | tr -d '[:space:]')
if [[ ${free_extents} -gt 0 ]]; then
  lvextend --resizefs -l +100%FREE "${lv_path}"
  echo "grow-root-lv: ${lv_path} extended to fill the disk"
else
  echo "grow-root-lv: ${lv_path} already fills the disk"
fi
