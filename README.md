# homelab-infra

Platforma z dokumentu „Homelab Platform Contract”: 2-node'owy k3s (RPi5 arm64 + Dell Wyse 5070 amd64), Istio ambient, Gateway API, Flux z image automation, SOPS (age).

| Co | Gdzie | Jak |
| --- | --- | --- |
| k3s server (RPi5, `homelab/node=rpi`) + agent (Wyse, `homelab/node=wyse`) | `terraform/k3s` | Terraform przez SSH |
| Flux + image-reflector/automation, Secret `sops-age` | `terraform/flux` | Terraform (`fluxcd/flux`) |
| Gateway API v1.6 CRDs, Istio ambient (base, istiod, cni, ztunnel) | `infrastructure/` | Flux |
| Gateway `home-gateway` (`istio-ingress`), namespace `apps` z ambient | `infrastructure/platform.yaml` | Flux |
| Kustomizations `infrastructure` → `apps`, `ImageUpdateAutomation` | `clusters/home/platform.yaml` | Flux |
| Aplikacje (`apps/<app>/`) | `apps/` | Flux, obrazy podbija image automation |

## Wymagania

- Oba hosty: SSH kluczem, `sudo` bez hasła.
- RPi5: w `/boot/firmware/cmdline.txt` dopisane `cgroup_memory=1 cgroup_enable=memory`, potem reboot.
- Lokalnie: `terraform` ≥ 1.6, `age`, `sops`.
- DNS: wildcard `*.home.arpa` → IP RPi5 (router albo Pi-hole).

## Uruchomienie

```bash
# 0. Ten katalog musi być na GitHubie (Flux czyta clusters/home z main)
git push

# 1. Klucz age (prywatny trafia do klastra, publiczny do .sops.yaml)
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # wklej do .sops.yaml

# 2. k3s
cd terraform/k3s
cp terraform.tfvars.example terraform.tfvars   # uzupełnij IP i usera
terraform init && terraform apply              # zapisuje terraform/kubeconfig

# 3. Flux (PAT fine-grained: tylko to repo, Contents read & write)
cd ../flux
export TF_VAR_github_token=github_pat_...
terraform init && terraform apply
git pull                                       # bootstrap commituje clusters/home/flux-system

# 4. Sprawdzenie
export KUBECONFIG=$PWD/../kubeconfig
kubectl get nodes -L homelab/node
flux get kustomizations
kubectl -n istio-ingress get gateway home-gateway
```

## Nowa aplikacja

1. `apps/<app>/` z manifestami wg kontraktu (ServiceAccount, Deployment, Service, HTTPRoute, AuthorizationPolicy).
2. Dopisz `<app>` do `apps/kustomization.yaml`.
3. `ImageRepository` + `ImagePolicy` dla `ghcr.io/jagieloadrian/<app>` w `clusters/home/` (wzór w kontrakcie).
4. Sekrety: `sops -e -i apps/<app>/secret.sops.yaml`.

## Do podbicia

- Istio `1.30.x` → `1.31.x`, gdy 1.31 wyjdzie z RC (`infrastructure/istio.yaml`).
- `wyse_system_reserved_memory` (domyślnie `4Gi`, ok. 3.4 GiB dla podów przy 8 GB RAM) pod realny RAM Wyse.
