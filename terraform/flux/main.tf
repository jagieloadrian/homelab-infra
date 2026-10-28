# Etap 2: bootstrap Flux do tego repo + klucz age dla SOPS (sekrety w .devops/ aplikacji).
# Reszta platformy (Gateway API, Istio ambient, Gateway, namespace apps) to YAML w clusters/ i infrastructure/.

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

# Fine-grained PAT tylko na to repo, Contents: read & write (bootstrap commituje clusters/home/flux-system).
variable "github_token" {
  type      = string
  sensitive = true
}

variable "age_key_file" {
  type    = string
  default = "~/.config/sops/age/keys.txt"
}

variable "wyse_host" {
  type        = string
  description = "IP Wyse 5070 (Postgres poza klastrem), w manifestach infrastructure/ jako $${WYSE_IP}"
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

resource "kubernetes_secret_v1" "sops_age" {
  depends_on = [flux_bootstrap_git.this]

  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data = {
    "age.agekey" = file(pathexpand(var.age_key_file))
  }
}

# Zmienne z .env podstawiane przez Flux w infrastructure/ (postBuild.substituteFrom), bez IP w gicie.
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
