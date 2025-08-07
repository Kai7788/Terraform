# main.tf
terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"

    }
  }
}


provider "docker" {}

# Shared Network
resource "docker_network" "proxy_net" {
  name   = "proxy_net"
  driver = "bridge"
}

# === Redis ===
resource "docker_container" "nextcloud_redis" {
  name    = "nextcloud_redis"
  image   = "redis:alpine"
  restart = "unless-stopped"

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}

# === MariaDB ===
resource "docker_container" "nextcloud_db" {
  name    = "nextcloud_db"
  image   = "mariadb:10.6"
  restart = "unless-stopped"

  env = [
    "MYSQL_ROOT_PASSWORD=nextcloud",
    "MYSQL_PASSWORD=nextcloud",
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

# === Nextcloud ===
resource "docker_container" "nextcloud" {
  name    = "nextcloud"
  image   = "lscr.io/linuxserver/nextcloud:latest"
  restart = "unless-stopped"

  env = [
    "PUID=33",
    "PGID=33",
    "TZ=Europe/Berlin",
    "MYSQL_HOST=nextcloud_db",
    "MYSQL_DATABASE=nextcloud",
    "MYSQL_USER=nextcloud",
    "MYSQL_PASSWORD=nextcloud",
    "REDIS_HOST=nextcloud_redis"
  ]

  dns        = ["192.168.178.150"]
  dns_search = ["fritz.box"]

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
    docker_container.nextcloud_db
  ]
}

# === YouTube Converter (backend build from local Dockerfile) ===
resource "docker_image" "yt_converter_image" {
  name = "yt_converter:latest"
  build {
    context    = "${path.module}/converter"
    dockerfile = "Dockerfile"
  }
}

resource "docker_container" "yt_converter" {
  name    = "yt_converter"
  image   = docker_image.yt_converter_image.name
  restart = "unless-stopped"

  volumes {
    host_path      = abspath("${path.module}/converter/tmp")
    container_path = "/app/tmp"
  }

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}

# === NGINX (serving as frontend and reverse proxy) ===
resource "docker_container" "nginx_proxy" {
  name    = "nginx_proxy"
  image   = "nginx:alpine"
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
}

# === Pi-hole ===
resource "docker_container" "pihole" {
  name    = "pihole"
  image   = "pihole/pihole:latest"
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
    "TZ=Europe/Berlin",
    "WEBPASSWORD=pihole",
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

  # Optional: Uncomment to use custom dnsmasq config
  # volumes {
  #   host_path      = "${path.module}/pihole/etc-dnsmasq.d"
  #   container_path = "/etc/dnsmasq.d"
  # }

  privileged = true

  networks_advanced {
    name = docker_network.proxy_net.name
  }
}
