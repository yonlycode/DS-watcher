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
