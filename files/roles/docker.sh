#!/usr/bin/env bash
# Role: docker - container host with Docker Engine and Compose v2.
#
# Settings (role.env):
#   DOCKER_USERS   space-separated users added to the docker group
#                  (default: members of the sudo group)
#
# Note: ports published with `docker run -p` bypass ufw (Docker manages its own
# iptables rules), so only publish what should be reachable.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -q docker.io docker-compose-v2

# Rotate container logs so they can't fill the disk
install -d -m 0755 /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl enable docker
systemctl restart docker

users=${DOCKER_USERS:-$(getent group sudo | cut -d: -f4 | tr ',' ' ')}
for user in ${users}; do
  usermod -aG docker "${user}"
  echo "docker: added ${user} to the docker group"
done

docker version --format 'docker: engine {{.Server.Version}} ready'
docker compose version
