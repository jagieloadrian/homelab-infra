terraform {
  required_version = ">= 1.6"
  required_providers {
    flux       = { source = "fluxcd/flux", version = "~> 1.10" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.4" }
  }
}

variable "kubeconfig" {
  type    = string
  default = "../kubeconfig"
}

variable "github_owner" {
  type    = string
  default = "jagieloadrian"
}

variable "github_repository" {
  type    = string
  default = "homelab-infra"
}

variable "github_token" {
  type      = string
  sensitive = true
}

variable "wyse_host" {
  type        = string
  description = "Wyse 5070 IP (Postgres outside the cluster), $${WYSE_IP} in the infrastructure/ manifests"
}

provider "kubernetes" {
  config_path = var.kubeconfig
}

provider "flux" {
  kubernetes = {
    config_path = var.kubeconfig
  }
  git = {
    url    = "https://github.com/${var.github_owner}/${var.github_repository}.git"
    branch = "main"
    http = {
      username = "git"
      password = var.github_token
    }
  }
}

resource "flux_bootstrap_git" "this" {
  path = "clusters/home"
}

resource "kubernetes_config_map_v1" "cluster_vars" {
  depends_on = [flux_bootstrap_git.this]

  metadata {
    name      = "cluster-vars"
    namespace = "flux-system"
  }

  data = {
    WYSE_IP = var.wyse_host
  }
}
