# Network Module Outputs

output "network_id" {
  description = "CloudStack network ID"
  value       = cloudstack_network.main.id
}
