# Network Module - CloudStack Isolated Network

terraform {
  required_providers {
    cloudstack = {
      source  = "cloudstack/cloudstack"
      version = "~> 0.6"
    }
  }
}

resource "cloudstack_network" "main" {
  name             = var.network_name
  cidr             = var.cidr
  network_offering = var.network_offering
  zone             = var.zone
  gateway          = cidrhost(var.cidr, 1)
  startip          = cidrhost(var.cidr, 10)
  endip            = cidrhost(var.cidr, 250)
}

# Egress Firewall Rules
# NOTE: CloudStack provider v0.6.0 has a bug with egress_firewall resource
# causing plugin crashes. Egress firewall must be configured manually in
# CloudStack UI or via CloudStack CLI.
#
# Required egress rules for k3s installation:
# - TCP to 0.0.0.0/0 (for k3s download, Docker registry, etc.)
# - UDP to 0.0.0.0/0 (for DNS)
#
# Manual configuration via CloudStack UI:
# Network → Egress Rules → Add Rule:
#   Protocol: TCP, CIDR: 0.0.0.0/0
#   Protocol: UDP, CIDR: 0.0.0.0/0
