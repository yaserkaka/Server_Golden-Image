#!/usr/bin/env bash
# 40-node-exporter.sh - Prometheus node_exporter on :9100.
# Ubuntu's package is used so security fixes arrive through apt like everything else.
set -euo pipefail
log() { printf '[node-exporter] %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive

log "Installing prometheus-node-exporter"
apt-get install -y -q --no-install-recommends prometheus-node-exporter
systemctl enable --now prometheus-node-exporter

log "Done"
