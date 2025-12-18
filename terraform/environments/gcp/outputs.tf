# Outputs for GCP Environment - Complete GitOps Automation

# Network Outputs
output "vpc_id" {
  description = "VPC Network ID"
  value       = google_compute_network.vpc.id
}

output "subnet_id" {
  description = "Subnet ID"
  value       = google_compute_subnetwork.subnet.id
}

output "master_external_ip" {
  description = "External IP address for k3s cluster access"
  value       = google_compute_address.master_external_ip.address
}

output "master_internal_ip" {
  description = "Master node internal IP"
  value       = google_compute_instance.k3s_master.network_interface[0].network_ip
}

# Cluster Access
output "cluster_endpoint" {
  description = "Kubernetes cluster API endpoint"
  value       = "https://${google_compute_address.master_external_ip.address}:6443"
}

output "argocd_url" {
  description = "ArgoCD UI URL"
  value       = "http://${google_compute_address.master_external_ip.address}:30080"
}

output "grafana_url" {
  description = "Grafana Dashboard URL"
  value       = "http://${google_compute_address.master_external_ip.address}:31300"
}

output "kiali_url" {
  description = "Kiali Dashboard URL"
  value       = "http://${google_compute_address.master_external_ip.address}:31200"
}

# Instructions
output "deployment_status" {
  description = "Deployment status and next steps"
  value = <<-EOT
    Infrastructure Deployment Complete!

    Automated Bootstrap In Progress:
    The k3s cluster is being automatically configured via startup script. This includes:
    - k3s installation (Master + ${var.worker_count} Workers)
    - ArgoCD installation
    - GitOps application deployment
    - PostgreSQL secret creation

    Bootstrap Timeline:
    - k3s installation: ~2-3 minutes
    - ArgoCD installation: ~3-5 minutes
    - Application sync: ~2-3 minutes
    Total: ~10 minutes for complete deployment

    Access Information:

    1. Kubernetes API:
       ${google_compute_address.master_external_ip.address}:6443

       Kubeconfig: ~/.kube/config-gcp (template created)
       To get actual kubeconfig with credentials:
       gcloud compute ssh ubuntu@${google_compute_instance.k3s_master.name} --zone=${var.zone} --command="sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/${google_compute_address.master_external_ip.address}/g" > ~/.kube/config-gcp

    2. ArgoCD UI:
       http://${google_compute_address.master_external_ip.address}:30080

       Get admin password:
       kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

    3. Grafana Dashboard:
       http://${google_compute_address.master_external_ip.address}:31300

    4. Kiali Dashboard:
       http://${google_compute_address.master_external_ip.address}:31200

    5. Monitor bootstrap progress:
       gcloud compute ssh ubuntu@${google_compute_instance.k3s_master.name} --zone=${var.zone}
       tail -f /var/log/k3s-bootstrap.log

    Deployed Applications (via ArgoCD GitOps):
    - titanium-prod: Main application stack
    - loki-stack: Logging and monitoring

    Verify Deployment:
    # Wait for bootstrap to complete (check log)
    gcloud compute ssh ubuntu@${google_compute_instance.k3s_master.name} --zone=${var.zone} --command="tail -f /var/log/k3s-bootstrap.log"

    # Check ArgoCD applications
    kubectl get applications -n argocd

    # Check all pods
    kubectl get pods --all-namespaces

    All applications are managed by ArgoCD!
    Any changes to https://github.com/DvwN-Lee/Monitoring-v2.git will be automatically synced.
  EOT
}
