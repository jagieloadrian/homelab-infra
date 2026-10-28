# Etap 1: k3s na RPi5 (server) + Dell Wyse 5070 (agent) przez SSH.
# Wynik: ../kubeconfig, którego używa etap terraform/flux.

terraform {
  required_version = ">= 1.6"
  required_providers {
    random = { source = "hashicorp/random", version = "~> 3.9" }
  }
}

variable "rpi_host" {
  type        = string
  description = "IP RPi5 (k3s server, cel wildcard DNS *.home.arpa)"
}

variable "wyse_host" {
  type        = string
  description = "IP Dell Wyse 5070 (k3s agent obok Home Assistant)"
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

variable "k3s_channel" {
  type    = string
  default = "stable"
}

# ponytail: na Wyse 8 GB daje ok. 3.4 GiB allocatable dla podów (twardy limit cgroup kubepods); stroić pod realny RAM i zużycie HA.
variable "wyse_system_reserved_memory" {
  type    = string
  default = "4Gi"
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

locals {
  key     = pathexpand(var.ssh_private_key)
  install = "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=${var.k3s_channel} K3S_TOKEN=${random_password.k3s_token.result} sh -s -"
}

resource "terraform_data" "rpi" {
  triggers_replace = [var.rpi_host]

  connection {
    type        = "ssh"
    host        = var.rpi_host
    user        = var.ssh_user
    private_key = file(local.key)
  }

  # traefik off: ruch wchodzi przez Istio Gateway; servicelb tylko na RPi (enablelb), więc LB = IP RPi5
  provisioner "remote-exec" {
    inline = [
      "${local.install} server --disable=traefik --tls-san=${var.rpi_host} --node-label=homelab/node=rpi --node-label=svccontroller.k3s.cattle.io/enablelb=true",
    ]
  }

  provisioner "local-exec" {
    command = "ssh -i ${local.key} -o StrictHostKeyChecking=accept-new ${var.ssh_user}@${var.rpi_host} sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/127.0.0.1/${var.rpi_host}/' > ${path.module}/../kubeconfig && chmod 600 ${path.module}/../kubeconfig"
  }
}

resource "terraform_data" "wyse" {
  depends_on       = [terraform_data.rpi]
  triggers_replace = [var.wyse_host]

  connection {
    type        = "ssh"
    host        = var.wyse_host
    user        = var.ssh_user
    private_key = file(local.key)
  }

  provisioner "remote-exec" {
    inline = [
      "${local.install} agent --server=https://${var.rpi_host}:6443 --node-label=homelab/node=wyse --kubelet-arg=system-reserved=memory=${var.wyse_system_reserved_memory}",
    ]
  }
}
