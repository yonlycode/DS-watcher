variable "network_name" {
  description = "Nom du réseau Docker partagé entre Traefik, le Registry et les applications"
  type        = string
  default     = "autodeploy-test-net"
}

variable "registry_port" {
  description = "Port hôte exposé par le Docker Registry local"
  type        = number
  default     = 5001
}

variable "traefik_http_port" {
  description = "Port HTTP d'entrée pour Traefik"
  type        = number
  default     = 9080
}

variable "traefik_dashboard_port" {
  description = "Port du dashboard Web de Traefik"
  type        = number
  default     = 9081
}

variable "docker_socket" {
  description = "Chemin du socket Docker (provider + montage dans Traefik). Auto-detecte par test-full-scenario.sh via TF_VAR_docker_socket. En apply direct sur Docker rootless : TF_VAR_docker_socket=/run/user/<uid>/docker.sock"
  type        = string
  default     = "/var/run/docker.sock"
}

variable "traefik_image" {
  description = "Image Traefik. v3.6+ requis pour Docker Engine >= 28 (v3.0 bloque : API 1.24 refusee par le demon)"
  type        = string
  default     = "traefik:v3.6"
}
