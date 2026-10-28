# PROJECT-STATUS

## Zrobione (2026-10-28)

- `terraform/k3s`: instalacja k3s przez SSH. Server na RPi5 bez traefika, servicelb tylko na RPi. Agent na Wyse z `system-reserved` na pamięć. Wynik: `terraform/kubeconfig`.
- `terraform/flux`: `flux_bootstrap_git` do tego repo (`clusters/home`) i Secret `sops-age`.
- `infrastructure/`: Gateway API v1.6 CRDs, Istio ambient przez HelmReleases, Gateway `home-gateway`, namespace `apps` z labelem ambient.
- `clusters/home/platform.yaml`: Kustomization `infrastructure`.
- `clusters/home/apps/`: lista aplikacji, plik na aplikację (`_app.yaml.example`): GitRepository (read-only, tylko `.devops/`) + Kustomization (`targetNamespace: apps`, SOPS).
- Weryfikacja: `terraform validate` i `fmt` w obu katalogach, `kustomize build`, `helm template` chartów Istio z użytymi values. Na żywym klastrze nic nie było jeszcze uruchamiane.

## Decyzje

- Terraform robi tylko maszyny i bootstrap. Wszystko w klastrze idzie przez GitOps (Flux), co omija problem CRD przy planie Terraform i zgadza się z kontraktem („Git jako źródło prawdy”).
- Dwa katalogi Terraform, bo provider k8s/flux potrzebuje kubeconfiga, który powstaje dopiero w etapie k3s.
- Flux uwierzytelnia się fine-grained PAT-em po HTTPS zamiast deploy key: jeden provider mniej.
- Istio `1.30.x`, bo 1.31 jest w Helm repo tylko jako RC (kontrakt zakłada 1.31).
- Repo Flux to `homelab-infra`, a kontrakt mówi o `homelab`.
- Manifesty i sekrety (SOPS) w `.devops/` repo aplikacji, nie tutaj. CI podbija tag w `.devops/` commitem z `GITHUB_TOKEN`, więc Flux tylko czyta. Bez image automation, co odbiega od kontraktu: jego sekcja CI/CD i zasada „sekrety w repo homelab” są do aktualizacji.

## Następne kroki

- Push, potem `terraform apply` w `k3s` i `flux`, potem weryfikacja na klastrze (kroki w README).
- Podbić Istio do 1.31.x po GA.
- Zaktualizować dokument kontraktu (CI/CD, sekrety, `.devops/`).
- Opcjonalnie: Renovate, notyfikacje Flux, Secret `ghcr-pull` dla prywatnych obrazów, pierwsza aplikacja (`hello`).
