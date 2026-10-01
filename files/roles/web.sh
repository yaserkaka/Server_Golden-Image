#!/usr/bin/env bash
# Role: web - nginx web server with a status page for this clone.
#
# Settings (role.env): none
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get install -y -q nginx

# shellcheck disable=SC1091
. /etc/golden-image-release

cat > /var/www/html/index.html <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>$(hostname)</title></head>
<body style="font-family: sans-serif; margin: 3rem;">
  <h1>$(hostname)</h1>
  <p>Cloned from <strong>${IMAGE_NAME}</strong> version <strong>${IMAGE_VERSION}</strong> (Ubuntu ${UBUNTU_VERSION})</p>
  <p>Roles: ${GOLDEN_ROLES:-web}</p>
</body>
</html>
EOF

ufw allow 80/tcp
ufw allow 443/tcp

systemctl enable nginx
systemctl restart nginx
curl -fsS -o /dev/null http://localhost/ && echo "web: nginx is serving the status page"
