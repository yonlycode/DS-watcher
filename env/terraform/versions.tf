terraform {
  required_version = ">= 1.5.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 3.0.0"
    }
  }
}

provider "docker" {
  # Socket fourni par la variable docker_socket : auto-detecte et injecte en
  # TF_VAR_docker_socket par test-full-scenario.sh, ce qui alimente a la fois ce
  # provider ET le montage du socket dans Traefik (une seule source de verite).
  # En `terraform apply` direct sur Docker rootless, definir :
  #   TF_VAR_docker_socket=/run/user/$(id -u)/docker.sock
  host = "unix://${var.docker_socket}"
}
