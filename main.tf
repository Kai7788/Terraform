terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
  }
}

provider "docker" {}

############################
# Variables
############################

variable "mysql_root_password" {
  type      = string
  sensitive = true
}

variable "mysql_password" {
  type      = string
  sensitive = true
  default   = "nextcloud"
}

variable "pihole_webpassword" {
  type      = string
  sensitive = true
}

variable "woodpecker_agent_secret" {
  type      = string
  sensitive = true
}

variable "woodpecker_forgejo_client" {
  type      = string
  sensitive = true
}

variable "woodpecker_forgejo_secret" {
  type      = string
  sensitive = true
}

variable "woodpecker_host" {
  type    = string
  default = "ci.lan"
}

variable "forgejo_host" {
  type    = string
  default = "git.lan"
}

variable "timezone" {
  type    = string
  default = "Europe/Berlin"
}

############################
# Networks
############################

resource "docker_network" "proxy_net" {
  name   = "proxy_net"
  driver = "bridge"
}

resource "docker_network" "tor_net" {
  name   = "tor_net"
  driver = "bridge"
}

############################
# Images
############################

resource "docker_image" "redis" {
  name = "redis:alpine"
}

resource "docker_image" "mariadb" {
  name = "mariadb:10.6"
}

resource "docker_image" "nextcloud" {
  name = "lscr.io/linuxserver/nextcloud:latest"
}

resource "docker_image" "nginx" {
  name = "nginx:alpine"
}

resource "docker_image" "pihole" {
  name = "pihole/pihole:latest"
}

resource "docker_image" "tor_simple" {
  name = "osminogin/tor-simple:latest"
}

resource "docker_image" "woodpecker_server" {
  name = "woodpeckerci/woodpecker-server:v3"
}

resource "docker_image" "woodpecker_agent" {
  name = "woodpeckerci/woodpecker-agent:v3"
}

resource "docker_image" "forgejo" {
  name = "codeberg.org/forgejo/forgejo:14"
}

############################
# Shared volumes
############################

resource "docker_volume" "woodpecker_server_data" {
  name = "woodpecker_server_data"
}

############################
# Redis
############################

resource "docker_container" "nextcloud_redis" {
  name    = "nextcloud_redis"
  image   = docker_image.redis.image_id
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}

############################
# MariaDB
############################

resource "docker_container" "nextcloud_db" {
  name    = "nextcloud_db"
  image   = docker_image.mariadb.image_id
  restart = "unless-stopped"

  env = [
    "MYSQL_ROOT_PASSWORD=${var.mysql_root_password}",
    "MYSQL_PASSWORD=${var.mysql_password}",
    "MYSQL_DATABASE=nextcloud",
    "MYSQL_USER=nextcloud"
  ]

  command = [
    "--transaction-isolation=READ-COMMITTED",
    "--binlog-format=ROW"
  ]

  volumes {
    host_path      = "/mnt/nextcloud_data/db"
    container_path = "/var/lib/mysql"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}

############################
# Nextcloud
############################

resource "docker_container" "nextcloud" {
  name    = "nextcloud"
  image   = docker_image.nextcloud.image_id
  restart = "unless-stopped"

  env = [
    "PUID=33",
    "PGID=33",
    "TZ=${var.timezone}",
    "MYSQL_HOST=nextcloud_db",
    "MYSQL_DATABASE=nextcloud",
    "MYSQL_USER=nextcloud",
    "MYSQL_PASSWORD=${var.mysql_password}",
    "REDIS_HOST=nextcloud_redis"
  ]

  dns        = ["192.168.178.150"]
  dns_search = ["lan", "fritz.box"]

  volumes {
    host_path      = "/mnt/nextcloud_data"
    container_path = "/data"
  }

  volumes {
    host_path      = "/mnt/nextcloud_data/config"
    container_path = "/config"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }

  depends_on = [
    docker_container.nextcloud_db,
    docker_container.nextcloud_redis
  ]
}

############################
# Forgejo (local git server)
############################

resource "docker_container" "forgejo" {
  name    = "forgejo"
  image   = docker_image.forgejo.image_id
  restart = "unless-stopped"

  env = [
    "USER_UID=1000",
    "USER_GID=1000",
    "TZ=${var.timezone}",

    "FORGEJO__server__DOMAIN=${var.forgejo_host}",
    "FORGEJO__server__ROOT_URL=http://${var.forgejo_host}/",
    "FORGEJO__server__HTTP_PORT=3000",

    "FORGEJO__server__SSH_DOMAIN=${var.forgejo_host}",
    "FORGEJO__server__SSH_PORT=2222",
    "FORGEJO__server__START_SSH_SERVER=false",

    "FORGEJO__webhook__ALLOWED_HOST_LIST=ci.lan,192.168.178.150",

    "FORGEJO__service__DISABLE_REGISTRATION=true",
    "FORGEJO__service__REQUIRE_SIGNIN_VIEW=false"
  ]

  ports {
    internal = 22
    external = 2222
  }

  volumes {
    host_path      = abspath("${path.module}/forgejo")
    container_path = "/data"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}

############################
# Woodpecker Server
############################

resource "docker_container" "woodpecker_server" {
  name    = "woodpecker_server"
  image   = docker_image.woodpecker_server.image_id
  restart = "unless-stopped"

  env = [
    "WOODPECKER_OPEN=true",
    "WOODPECKER_HOST=http://${var.woodpecker_host}",
    "WOODPECKER_AGENT_SECRET=${var.woodpecker_agent_secret}",

    # Local Forgejo integration
    "WOODPECKER_GITEA=true",
    "WOODPECKER_GITEA_URL=http://${var.forgejo_host}",
    "WOODPECKER_GITEA_CLIENT=${var.woodpecker_forgejo_client}",
    "WOODPECKER_GITEA_SECRET=${var.woodpecker_forgejo_secret}"
  ]

  volumes {
    volume_name    = docker_volume.woodpecker_server_data.name
    container_path = "/var/lib/woodpecker"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }

  depends_on = [
    docker_container.forgejo
  ]
}

############################
# Woodpecker Agent
############################

resource "docker_container" "woodpecker_agent" {
  name    = "woodpecker_agent"
  image   = docker_image.woodpecker_agent.image_id
  restart = "unless-stopped"

  env = [
    "WOODPECKER_SERVER=woodpecker_server:9000",
    "WOODPECKER_AGENT_SECRET=${var.woodpecker_agent_secret}",
    "WOODPECKER_MAX_WORKFLOWS=1",
    "WOODPECKER_BACKEND_DOCKER_NETWORK=${docker_network.proxy_net.name}"
  ]

  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }

  depends_on = [
    docker_container.woodpecker_server
  ]
}

############################
# NGINX reverse proxy
############################

resource "docker_container" "nginx_proxy" {
  name    = "nginx_proxy"
  image   = docker_image.nginx.image_id
  restart = "unless-stopped"

  ports {
    internal = 80
    external = 80
  }

  ports {
    internal = 443
    external = 443
  }

  volumes {
    host_path      = abspath("${path.module}/nginx.conf")
    container_path = "/etc/nginx/nginx.conf"
  }

  volumes {
    host_path      = abspath("${path.module}/certs")
    container_path = "/etc/nginx/certs"
  }

  volumes {
    host_path      = abspath("${path.module}/frontend")
    container_path = "/usr/share/nginx/html"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }

  depends_on = [
    docker_container.nextcloud,
    docker_container.pihole,
    docker_container.forgejo,
    docker_container.woodpecker_server
  ]
}

############################
# Pi-hole
############################

resource "docker_container" "pihole" {
  name    = "pihole"
  image   = docker_image.pihole.image_id
  restart = "unless-stopped"

  ports {
    internal = 53
    external = 53
    protocol = "tcp"
  }

  ports {
    internal = 53
    external = 53
    protocol = "udp"
  }

  ports {
    internal = 853
    external = 853
    protocol = "tcp"
  }

  ports {
    internal = 853
    external = 853
    protocol = "udp"
  }

  env = [
    "TZ=${var.timezone}",
    "WEBPASSWORD=${var.pihole_webpassword}",
    "FTLCONF_dns_listeningMode=all",
    "PIHOLE_DNS_=1.1.1.1;8.8.8.8",
    "VIRTUAL_HOST=pihole.raspberry",
    "VIRTUAL_PORT=80"
  ]

  dns = [
    "1.1.1.1",
    "8.8.8.8"
  ]

  volumes {
    host_path      = abspath("${path.module}/pihole/etc-pihole")
    container_path = "/etc/pihole"
  }

  volumes {
    host_path      = abspath("${path.module}/pihole/etc-dnsmasq.d")
    container_path = "/etc/dnsmasq.d"
  }

  privileged = true

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}

############################
# Tor Relay
############################

resource "docker_container" "tor_relay" {
  name    = "tor_relay"
  image   = docker_image.tor_simple.image_id
  restart = "unless-stopped"

  ports {
    internal = 9001
    external = 9001
    protocol = "tcp"
  }

  volumes {
    host_path      = abspath("${path.module}/tor/torrc")
    container_path = "/etc/tor/torrc"
  }

  volumes {
    host_path      = abspath("${path.module}/tor/data")
    container_path = "/var/lib/tor"
  }

  networks_advanced {
    name = docker_network.tor_net.name
  }
}
