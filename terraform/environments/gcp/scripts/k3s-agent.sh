#!/bin/bash
set -e

# k3s Agent Installation Script
# This script runs on worker nodes via cloud-init

# Wait for master to be ready (최대 60회 = 10분)
echo "Waiting for k3s master at ${master_ip}:6443..."
MAX_RETRIES=60
RETRY_COUNT=0
until nc -z ${master_ip} 6443; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: k3s master not reachable after $MAX_RETRIES attempts (10 min). Aborting."
    exit 1
  fi
  echo "Master not ready, retrying in 10 seconds... ($RETRY_COUNT/$MAX_RETRIES)"
  sleep 10
done

echo "Master is ready, installing k3s agent..."

# Install k3s agent with unique node ID (for MIG auto-healing support)
# --with-node-id appends instance ID to node name, preventing password conflicts on recreation
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3s_version}" K3S_URL="https://${master_ip}:6443" K3S_TOKEN="${k3s_token}" sh -s - --with-node-id

# Wait for k3s agent to be ready
echo "Waiting for k3s agent to be ready..."
sleep 20

# Verify k3s-agent is running
systemctl status k3s-agent || true

# Mark installation complete
echo "k3s-agent-ready" > /tmp/k3s-status

echo "k3s agent installation completed"
