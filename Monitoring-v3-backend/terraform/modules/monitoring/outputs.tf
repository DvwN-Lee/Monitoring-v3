# Monitoring Module Outputs

output "loki_application_name" {
  description = "Argo CD Application name for Loki stack"
  value       = kubernetes_manifest.loki_stack_application.manifest.metadata.name
}

output "loki_service_url" {
  description = "Loki service URL for log queries"
  value       = "http://loki.${var.namespace}.svc.cluster.local:3100"
}

output "loki_datasource_configmap" {
  description = "Loki datasource ConfigMap name"
  value       = kubernetes_config_map.loki_datasource.metadata[0].name
}
