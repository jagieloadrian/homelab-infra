# homelab-infra

Platforma z dokumentu „Homelab Platform Contract”: 2-node'owy k3s (RPi5 arm64 + Dell Wyse 5070 amd64), Istio ambient, Gateway API, Flux, SOPS (age).

| Co | Gdzie | Jak |
| --- | --- | --- |
| k3s server (RPi5, `homelab/node=rpi`) + agent (Wyse, `homelab/node=wyse`) | `terraform/k3s` | Terraform przez SSH |
| Flux, Secret `sops-age` | `terraform/flux` | Terraform (`fluxcd/flux`) |
| Gateway API v1.6 CRDs, Istio ambient (base, istiod, cni, ztunnel) | `infrastructure/` | Flux |
| Gateway `home-gateway` (`istio-ingress`), namespace `apps` z ambient | `infrastructure/platform.yaml` | Flux |
| Lista aplikacji: plik na aplikację | `clusters/home/apps/` | Flux (read-only z repo aplikacji) |
| Manifesty aplikacji | `.devops/` w repo aplikacji | Flux |

## Wymagania

- Oba hosty: SSH kluczem, `sudo` bez hasła.
- RPi5: w `/boot/firmware/cmdline.txt` dopisane `cgroup_memory=1 cgroup_enable=memory`, potem reboot.
- Lokalnie: `terraform` ≥ 1.6, `age`, `sops`.
- DNS: wildcard `*.home.arpa` → IP RPi5 (router albo Pi-hole).

## Uruchomienie

```bash
# 0. Ten katalog musi być na GitHubie (Flux czyta clusters/home z main)
git push

# 1. Klucz age (prywatny trafia do klastra, publiczny do .sops.yaml w repo aplikacji)
age-keygen -o ~/.config/sops/age/keys.txt

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

Przepływ: merge do `main` → CI buduje obraz `main-<ts>-<sha7>` → CI podbija tag w `.devops/` i commituje → Flux (co 1 min) widzi commit → rollout. Rollback = `git revert` w repo aplikacji.

1. W repo aplikacji katalog `.devops/` z manifestami wg kontraktu (ServiceAccount, Deployment, Service, HTTPRoute, AuthorizationPolicy). `namespace` można pominąć, Flux wymusza `apps`.
2. Sekrety jako `.devops/*.sops.yaml` zaszyfrowane kluczem age; `.sops.yaml` w repo aplikacji:
   ```yaml
   creation_rules:
     - path_regex: \.devops/.*\.sops\.yaml$
       encrypted_regex: ^(data|stringData)$
       age: age1...   # age-keygen -y ~/.config/sops/age/keys.txt
   ```
3. W workflow `build` z kontraktu: `permissions.contents: write` i krok po pushu obrazu:
   ```yaml
         - name: Deploy (bump image tag)
           if: github.ref == 'refs/heads/main'
           run: |
             sed -i -E "s#(image: ghcr.io/${{ github.repository_owner }}/${{ github.event.repository.name }}):[^[:space:]]+#\1:${{ steps.tag.outputs.tag }}#" .devops/*.yaml
             git config user.name 'github-actions[bot]'
             git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
             git commit -am "chore(deploy): ${{ steps.tag.outputs.tag }}"
             git pull --rebase && git push
   ```
   Push z `GITHUB_TOKEN` nie odpala kolejnego workflow, więc nie ma pętli. Branch protection na `main` musi przepuszczać `github-actions[bot]`.
4. Rejestracja tutaj:
   ```bash
   cd clusters/home/apps
   cp _app.yaml.example hello.yaml && sed -i 's/APP/hello/g' hello.yaml
   ```
   Prywatne repo aplikacji: dodaj `secretRef` z read-only tokenem do `GitRepository`.

## Do podbicia

- Istio `1.30.x` → `1.31.x`, gdy 1.31 wyjdzie z RC (`infrastructure/istio.yaml`).
- `wyse_system_reserved_memory` (domyślnie `4Gi`, ok. 3.4 GiB dla podów przy 8 GB RAM) pod realny RAM Wyse.
