#!/bin/bash
# Self-signed TLS Certificate Generation Script
# Usage: ./generate-tls-cert.sh [NAMESPACE] [SECRET_NAME]

set -euo pipefail

NAMESPACE="${1:-istio-system}"
SECRET_NAME="${2:-titanium-tls-credential}"
CERT_DIR=$(mktemp -d)
DAYS_VALID=365

echo "Generating self-signed TLS certificate..."
echo "  Namespace: $NAMESPACE"
echo "  Secret: $SECRET_NAME"
echo "  Validity: $DAYS_VALID days"

# Generate self-signed certificate
openssl req -x509 -nodes -days $DAYS_VALID -newkey rsa:2048 \
  -keyout "$CERT_DIR/tls.key" \
  -out "$CERT_DIR/tls.crt" \
  -subj "/CN=titanium.local/O=Titanium" \
  -addext "subjectAltName=DNS:titanium.local,DNS:*.titanium.local,DNS:localhost"

# Create/Update Kubernetes TLS Secret
kubectl create secret tls "$SECRET_NAME" \
  --key="$CERT_DIR/tls.key" \
  --cert="$CERT_DIR/tls.crt" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

# Cleanup
rm -rf "$CERT_DIR"

echo ""
echo "TLS Secret '$SECRET_NAME' created in namespace '$NAMESPACE'"
echo ""
echo "Verify with:"
echo "  kubectl get secret $SECRET_NAME -n $NAMESPACE"
echo "  kubectl describe secret $SECRET_NAME -n $NAMESPACE"
