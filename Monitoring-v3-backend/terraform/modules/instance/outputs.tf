# Instance Module Outputs

output "k3s_api_endpoint" {
  description = "k3s API server endpoint (via public IP)"
  value       = "https://${cloudstack_ipaddress.master_public_ip.ip_address}:6443"
}

output "master_ip" {
  description = "k3s master node private IP address"
  value       = cloudstack_instance.k3s_master.ip_address
}

output "master_public_ip" {
  description = "k3s master node public IP address"
  value       = cloudstack_ipaddress.master_public_ip.ip_address
}

output "master_node_id" {
  description = "k3s master node VM ID"
  value       = cloudstack_instance.k3s_master.id
}

output "worker_ips" {
  description = "k3s worker node IP addresses"
  value       = cloudstack_instance.k3s_worker[*].ip_address
}

output "k3s_token" {
  description = "k3s cluster token"
  value       = random_password.k3s_token.result
  sensitive   = true
}

# Note: For actual kubeconfig, SSH into master and retrieve /etc/rancher/k3s/k3s.yaml
# These outputs are placeholders for kubernetes provider configuration
output "client_certificate" {
  description = "Placeholder for client certificate - retrieve from master:/etc/rancher/k3s/k3s.yaml"
  value       = ""
  sensitive   = true
}

output "client_key" {
  description = "Placeholder for client key - retrieve from master:/etc/rancher/k3s/k3s.yaml"
  value       = ""
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Placeholder for CA certificate - retrieve from master:/etc/rancher/k3s/k3s.yaml"
  value       = ""
  sensitive   = true
}
