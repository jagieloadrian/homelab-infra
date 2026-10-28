# PROJECT-STATUS

## Zrobione (2026-10-28)

- `terraform/k3s`: instalacja k3s przez SSH. Server na RPi5 bez traefika, servicelb tylko na RPi. Agent na Wyse z `system-reserved` na pamięć. Wynik: `terraform/kubeconfig`.
- `terraform/flux`: `flux_bootstrap_git` z kontrolerami image automation do tego repo (`clusters/home`) i Secret `sops-age`.
- `infrastructure/`: Gateway API v1.6 CRDs, Istio ambient przez HelmReleases, Gateway `home-gateway`, namespace `apps` z labelem ambient.
- `clusters/home/platform.yaml`: Kustomizations `infrastructure` → `apps` (z deszyfrowaniem SOPS) i wspólny `ImageUpdateAutomation`.
- Weryfikacja: `terraform validate` i `fmt` w obu katalogach, `kustomize build`, `helm template` chartów Istio z użytymi values. Na żywym klastrze nic nie było jeszcze uruchamiane.

## Decyzje

- Terraform robi tylko maszyny i bootstrap. Wszystko w klastrze idzie przez GitOps (Flux), co omija problem CRD przy planie Terraform i zgadza się z kontraktem („Git jako źródło prawdy”).
- Dwa katalogi Terraform, bo provider k8s/flux potrzebuje kubeconfiga, który powstaje dopiero w etapie k3s.
- Flux uwierzytelnia się fine-grained PAT-em po HTTPS zamiast deploy key: jeden provider mniej.
- Istio `1.30.x`, bo 1.31 jest w Helm repo tylko jako RC (kontrakt zakłada 1.31).
- Repo Flux to `homelab-infra`, a kontrakt mówi o `homelab`.

## Następne kroki

- Push, potem `terraform apply` w `k3s` i `flux`, potem weryfikacja na klastrze (kroki w README).
- Wpisać klucz publiczny age do `.sops.yaml`.
- Podbić Istio do 1.31.x po GA.
- Opcjonalnie: Renovate, notyfikacje Flux, Secret `ghcr-pull` dla prywatnych obrazów, pierwsza aplikacja (`hello`).
