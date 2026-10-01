#!/usr/bin/env bash
# Role: k8s-node - Kubernetes node ready for `kubeadm init` or `kubeadm join`.
# Disables swap, loads kernel modules, sets networking sysctl, installs containerd
# (systemd cgroups) and kubeadm/kubelet/kubectl from pkgs.k8s.io.
#
# Settings (role.env):
#   K8S_VERSION   Kubernetes minor version channel (default: v1.37)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

K8S_VERSION=${K8S_VERSION:-v1.37}

# --- Swap off (kubelet requirement) --------------------------------------------
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/# disabled for kubelet: /' /etc/fstab
rm -f /swap.img
echo "k8s-node: swap disabled"

# --- Kernel modules and sysctl -------------------------------------------------
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/92-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

# --- containerd ----------------------------------------------------------------
apt-get install -y -q containerd gpg
install -d -m 0755 /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml ||
  echo "k8s-node: WARNING could not enable SystemdCgroup, check /etc/containerd/config.toml" >&2
systemctl enable containerd
systemctl restart containerd

# --- kubeadm, kubelet, kubectl --------------------------------------------------
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" |
  gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -q
apt-get install -y -q kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# --- Firewall ------------------------------------------------------------------
ufw default allow routed                       # pod-to-pod traffic is forwarded
ufw allow 6443/tcp       comment 'k8s API server'
ufw allow 2379:2380/tcp  comment 'etcd'
ufw allow 10250/tcp      comment 'kubelet'
ufw allow 10257/tcp      comment 'kube-controller-manager'
ufw allow 10259/tcp      comment 'kube-scheduler'
ufw allow 30000:32767/tcp comment 'NodePort services'
ufw allow 8472/udp       comment 'Flannel VXLAN'
ufw allow 4789/udp       comment 'Calico VXLAN'
ufw allow 179/tcp        comment 'Calico BGP'

echo "k8s-node: $(kubeadm version -o short) ready"
echo "k8s-node: next step -> 'kubeadm init' on the first control plane, 'kubeadm join ...' on the others"
