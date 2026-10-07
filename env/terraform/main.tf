resource "docker_network" "autodeploy_net" {
  name   = var.network_name
  driver = "bridge"
}

# Image Docker du Registry officiel v2
resource "docker_image" "registry" {
  name         = "registry:2"
  keep_locally = true
}

# Conteneur Registry Local (Accessible sur localhost:5001)
resource "docker_container" "registry" {
  name  = "test-registry"
  image = docker_image.registry.image_id

  ports {
    internal = 5000
    external = var.registry_port
  }

  networks_advanced {
    name = docker_network.autodeploy_net.name
    aliases = ["test-registry"]
  }

  restart = "unless-stopped"
}

# Image Traefik v3 (v3.6+ requis pour Docker Engine >= 28, voir variables.tf)
resource "docker_image" "traefik" {
  name         = var.traefik_image
  keep_locally = true
}

# Conteneur Reverse Proxy Traefik
resource "docker_container" "traefik" {
  name  = "test-traefik"
  image = docker_image.traefik.image_id

  command = [
    "--api.insecure=true",
    "--providers.docker=true",
    "--providers.docker.exposedbydefault=false",
    "--providers.docker.network=${var.network_name}",
    "--entrypoints.web.address=:80"
  ]

  volumes {
    host_path      = var.docker_socket
    container_path = "/var/run/docker.sock"
    read_only      = true
  }

  ports {
    internal = 80
    external = var.traefik_http_port
  }

  ports {
    internal = 8080
    external = var.traefik_dashboard_port
  }

  networks_advanced {
    name = docker_network.autodeploy_net.name
    aliases = ["test-traefik"]
  }

  restart = "unless-stopped"
}
