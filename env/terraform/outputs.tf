output "registry_url" {
  description = "URL locale du Docker Registry"
  value       = "localhost:${var.registry_port}"
}

output "traefik_http_url" {
  description = "URL HTTP de Traefik"
  value       = "http://localhost:${var.traefik_http_port}"
}

output "traefik_dashboard_url" {
  description = "URL du Dashboard Web de Traefik"
  value       = "http://localhost:${var.traefik_dashboard_port}"
}

output "docker_network_name" {
  description = "Nom du réseau Docker"
  value       = docker_network.autodeploy_net.name
}
