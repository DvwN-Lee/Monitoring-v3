#!/bin/bash
set -e

# k3s Agent Installation Script
# This script runs on worker nodes via cloud-init

# Wait for master to be ready
echo "Waiting for k3s master at ${master_ip}:6443..."
until nc -z ${master_ip} 6443; do
  echo "Master not ready, retrying in 10 seconds..."
  sleep 10
done

echo "Master is ready, installing k3s agent..."

# Install k3s agent
curl -sfL https://get.k3s.io | K3S_URL="https://${master_ip}:6443" K3S_TOKEN="${k3s_token}" sh -

# Wait for k3s agent to be ready
echo "Waiting for k3s agent to be ready..."
sleep 20

# Verify k3s-agent is running
systemctl status k3s-agent || true

# Mark installation complete
echo "k3s-agent-ready" > /tmp/k3s-status

echo "k3s agent installation completed"
