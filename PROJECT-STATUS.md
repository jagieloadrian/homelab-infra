# PROJECT-STATUS

## Zrobione (2026-10-28)

- `terraform/k3s`: instalacja k3s przez SSH. Server na RPi5 bez traefika, servicelb tylko na RPi. Agent na Wyse z `system-reserved` na pamięć. Wynik: `terraform/kubeconfig`.
- `terraform/flux`: `flux_bootstrap_git` do tego repo (`clusters/home`) i Secret `sops-age`.
- `infrastructure/`: Gateway API v1.6 CRDs, Istio ambient przez HelmReleases, Gateway `home-gateway`, namespace `apps` z labelem ambient.
- `clusters/home/platform.yaml`: Kustomization `infrastructure`.
- `clusters/home/apps/`: lista aplikacji, plik na aplikację (`_app.yaml.example`): GitRepository (read-only, tylko `.devops/`) + Kustomization (`targetNamespace: apps`, SOPS).
- `apps/<name>/`: gotowe aplikacje z Helm charta (Kustomization `apps`, `targetNamespace: apps`, SOPS), szablon `apps/_template/release.yaml.tpl`.
- `scripts/new-app.sh`: `own <name>` (rejestracja `.devops/`) i `helm <name> <repo> <chart> <wersja> [port]` (HelmRepository http/OCI, HelmRelease, HTTPRoute, AuthorizationPolicy). Przetestowany na Authelia i podinfo (OCI).
- Dokument kontraktu zaktualizowany: `.devops/`, CI commituje tag, rejestracja skryptem, sekcja „Gotowe aplikacje”, nowy diagram CI/CD, Istio 1.30.
- CI (GitHub Actions): `homelab-infra/.github/workflows/validate.yml` (terraform fmt/validate obu katalogów, kubeconform z katalogiem CRD na `kustomize build infrastructure`, `clusters/home`, `apps/`, tylko znane zmienne Flux, shellcheck + smoke `new-app.sh`, pliki `*.sops.*` zaszyfrowane, brak `.env` w gicie, klucz age). W repo aplikacji `devops.yml`: kustomize build + kubeconform `.devops/k8s`, w statistics-service dodatkowo format `config.env`, brak sekretów w nim, `secrets.sops.env` zaszyfrowany z kompletem kluczy.
- Panele UI (`docs/ui.md`): Headlamp i Capacitor lokalnie z kubeconfigiem; Kiali + Prometheus (tylko server, emptyDir, 2d) w `istio-system` przez `infrastructure/kiali.yaml`, dostęp port-forwardem.
- Weryfikacja: `terraform validate` i `fmt` w obu katalogach, `kustomize build`, `helm template` chartów Istio z użytymi values. Na żywym klastrze nic nie było jeszcze uruchamiane.

## Zrobione (2026-10-30)

- `apps/nats/`: NATS 2.15.x z JetStream (Helm, 1 replika na RPi5, PVC `local-path` 2 Gi, 256 Mi RAM, UID 10001, read-only FS), użytkownicy `statistics-service` i `collector` z hasłami z Secret `nats-auth`, AuthorizationPolicy tylko z `statistics-service` na 4222, bez HTTPRoute. Opis: `docs/nats.md`.
- Weryfikacja: `helm template` z values, `nats-server -t` na wyrenderowanym konfigu, serwer w Dockerze (UID 10001, read-only) + nats-box: stream/consumer/ack jako `statistics-service`, publish jako `collector`, odmowy (subskrypcja `stats.ingest.>` i `_INBOX.>`, `$JS.API`, anonim, złe hasło), kubeconform jak w CI.

## Decyzje

- Terraform robi tylko maszyny i bootstrap. Wszystko w klastrze idzie przez GitOps (Flux), co omija problem CRD przy planie Terraform i zgadza się z kontraktem („Git jako źródło prawdy”).
- Dwa katalogi Terraform, bo provider k8s/flux potrzebuje kubeconfiga, który powstaje dopiero w etapie k3s.
- Flux uwierzytelnia się fine-grained PAT-em po HTTPS zamiast deploy key: jeden provider mniej.
- Istio `1.30.x`, bo 1.31 jest w Helm repo tylko jako RC (kontrakt zakłada 1.31).
- Repo Flux to `homelab-infra`, a kontrakt mówi o `homelab`.
- Manifesty i sekrety (SOPS) w `.devops/` repo aplikacji, nie tutaj. CI podbija tag w `.devops/` commitem z `GITHUB_TOKEN`, więc Flux tylko czyta. Bez image automation (kontrakt zaktualizowany).
- Baza: istniejący Postgres na hoście Wyse (poza k3s), baza `statistics`, użytkownik + schema per aplikacja, w klastrze Service bez selektora + EndpointSlice (`docs/postgres.md`). Bez CNPG i bez Postgresa w klastrze.
- Wejścia jako zmienne środowiskowe: `homelab-infra/.env` (`TF_VAR_*`, poza gitem); IP Wyse trafia do klastra przez ConfigMap `cluster-vars` i `postBuild.substituteFrom` (bez IP w gicie). Aplikacje: `.devops/k8s/config.env` (jawny) + `secrets.sops.env` (SOPS dotenv) przez generatory kustomize.
- UI: Headlamp/Capacitor lokalnie (zero zasobów w klastrze, bez wystawiania konsoli admina). Kiali `auth.strategy: anonymous`, bo bez HTTPRoute; Prometheus z domyślnymi jobami charta (adnotacje `prometheus.io/*` łapią ztunnel i istiod).
- Gotowe aplikacje (Helm) żyją tutaj w `apps/<name>/`, aktualizacje przez zakres semver w HelmRelease (bez Renovate).
- Kolejka: NATS JetStream bez kontrolera NACK, stream i consumer zakłada statistics-service. Bez reloadera (checksum konfigu robi rollout). Collector ma inbox `_INBOX_collector.>`, bo `_INBOX.>` pokazywałby mu wiadomości dostarczane do statistics-service. Backup na poziomie katalogu PVC (kolejka to bufor).

## Następne kroki

- `apps/nats/secret.sops.yaml` (hasła NATS, `docs/nats.md`) po wpisaniu klucza age, przed wdrożeniem NATS; potem `NATS_USER`/`NATS_PASSWORD` i `BROKER=jetstream` w statistics-service.
- CI `devops` w statistics-service jest czerwone, dopóki nie ma `secrets.sops.env` i prawdziwego klucza age w `.sops.yaml` (celowo).
- Postawić całość według `docs/setup.md` (kroki 0–8): `.env`, klucz age w obu `.sops.yaml`, `secrets.sops.env` statistics-service, Postgres na Wyse, merge `feature-6` → `main` w obu repo aplikacji, paczki GHCR publiczne.
- Podbić Istio do 1.31.x po GA.
- Kiali: przed HTTPRoute przełączyć na `openid` przez Authelię; waypoint w `apps` dla metryk L7.
- Authelia: values (`pod.kind: Deployment`, storage, OIDC), potem forward-auth przez `extensionProviders` w istiod.
- Opcjonalnie: Renovate (major bumpy chartów), notyfikacje Flux, Secret `ghcr-pull` dla prywatnych obrazów, pierwsza aplikacja (`hello`).
