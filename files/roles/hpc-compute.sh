#!/usr/bin/env bash
# Role: hpc-compute - HPC compute node.
# OpenMPI, Slurm compute daemon, munge, HPC performance profile, cluster-network
# trust and (optionally) shared storage from an nfs-server clone.
#
# Settings (role.env):
#   CLUSTER_CIDR      cluster network trusted for MPI/Slurm traffic (default: this clone's subnet)
#   NFS_SERVER        NFS server address; if set, its export is mounted at NFS_MOUNT
#   NFS_EXPORT_DIR    exported path on the server                   (default: /srv/shared)
#   NFS_MOUNT         local mount point                             (default: /shared)
#   HPC_TUNED_PROFILE tuned profile for compute work                (default: throughput-performance)
#   MUNGE_KEY_B64     base64 cluster munge key (all Slurm nodes must share it)
#
# slurmd starts once the cluster's /etc/slurm/slurm.conf is in place.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CLUSTER_CIDR=${CLUSTER_CIDR:-$(ip -o -4 route show scope link | awk '{print $1; exit}')}
NFS_EXPORT_DIR=${NFS_EXPORT_DIR:-/srv/shared}
NFS_MOUNT=${NFS_MOUNT:-/shared}
HPC_TUNED_PROFILE=${HPC_TUNED_PROFILE:-throughput-performance}

apt-get install -y -q openmpi-bin libopenmpi-dev slurmd slurm-client munge \
                      nfs-common numactl hwloc

# --- Performance -------------------------------------------------------------
tuned-adm profile "${HPC_TUNED_PROFILE}"
echo "hpc-compute: tuned profile $(tuned-adm active | awk -F': ' '{print $2}')"

# --- Cluster network ------------------------------------------------------------
# MPI ranks and Slurm use dynamic ports between nodes, so trust the cluster subnet
if [[ -n ${CLUSTER_CIDR} ]]; then
  ufw allow from "${CLUSTER_CIDR}" comment 'HPC cluster network'
  echo "hpc-compute: trusting cluster network ${CLUSTER_CIDR}"
fi

# --- Munge (Slurm authentication) --------------------------------------------
if [[ -n ${MUNGE_KEY_B64:-} ]]; then
  base64 -d <<<"${MUNGE_KEY_B64}" > /etc/munge/munge.key
  chown munge:munge /etc/munge/munge.key
  chmod 0400 /etc/munge/munge.key
  echo "hpc-compute: installed cluster munge key"
fi
systemctl enable munge
systemctl restart munge

# --- Shared storage -----------------------------------------------------------
if [[ -n ${NFS_SERVER:-} ]]; then
  install -d -m 0755 "${NFS_MOUNT}"
  if ! grep -qsE "[[:space:]]${NFS_MOUNT}[[:space:]]" /etc/fstab; then
    echo "${NFS_SERVER}:${NFS_EXPORT_DIR} ${NFS_MOUNT} nfs4 defaults,_netdev,noatime 0 0" >> /etc/fstab
  fi
  systemctl daemon-reload
  # The NFS server may be booting at the same time, so retry for up to 5 minutes
  for attempt in $(seq 1 30); do
    if mountpoint -q "${NFS_MOUNT}" || mount "${NFS_MOUNT}" 2>/dev/null; then
      echo "hpc-compute: ${NFS_SERVER}:${NFS_EXPORT_DIR} mounted at ${NFS_MOUNT}"
      break
    fi
    echo "hpc-compute: waiting for NFS server ${NFS_SERVER} (attempt ${attempt}/30)"
    sleep 10
  done
  mountpoint -q "${NFS_MOUNT}" || { echo "hpc-compute: could not mount ${NFS_MOUNT}" >&2; exit 1; }
fi

mpirun --version | head -n1
echo "hpc-compute: node ready (add it to slurm.conf on the controller to start slurmd)"
