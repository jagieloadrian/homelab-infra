# PROJECT-STATUS

## Done (2026-10-28)

- `terraform/k3s`: k3s installation over SSH. Server on RPi5 without traefik, servicelb only on RPi. Agent on Wyse with `system-reserved` for memory. Output: `terraform/kubeconfig`.
- `terraform/flux`: `flux_bootstrap_git` to this repo (`clusters/home`).
- `infrastructure/`: Gateway API v1.6 CRDs, Istio ambient via HelmReleases, Gateway `home-gateway`, namespace `apps` with the ambient label.
- `clusters/home/platform.yaml`: Kustomization `infrastructure`.
- `clusters/home/apps/`: app list, one file per app (`_app.yaml.example`): GitRepository (read-only, only `.devops/helm/`) + Kustomization (`targetNamespace: apps`).
- `apps/<name>/`: ready-made apps from a Helm chart (Kustomization `apps`, `targetNamespace: apps`), template `apps/_template/release.yaml.tpl`.
- `scripts/new-app.sh`: `own <name>` (registration of the app repo's `.devops/helm/`) and `helm <name> <repo> <chart> <version> [port]` (HelmRepository http/OCI, HelmRelease, HTTPRoute, AuthorizationPolicy). Tested on Authelia and podinfo (OCI).
- Contract document updated: `.devops/`, CI commits the tag, registration via script, "Ready-made apps" section, new CI/CD diagram, Istio 1.30.
- CI (GitHub Actions): `homelab-infra/.github/workflows/validate.yml` (terraform fmt/validate of both directories, kubeconform with a CRD catalog on `kustomize build infrastructure`, `clusters/home`, `apps/`, only known Flux variables, shellcheck + smoke `new-app.sh`, no Secret manifests in git, no `.env` in git). In the app repos `devops.yml`: `helm template` of `charts/app` with the values from `.devops/helm/release.yaml` + kubeconform.
- UI panels (`docs/ui.md`): Headlamp and Capacitor locally with the kubeconfig; Kiali + Prometheus (server only, emptyDir, 2d) in `istio-system` via `infrastructure/kiali.yaml`, access via port-forward.
- Verification: `terraform validate` and `fmt` in both directories, `kustomize build`, `helm template` of the Istio charts with the values used. Nothing has been run on a live cluster yet.

## Done (2026-10-30)

- `apps/nats/`: NATS 2.15.x with JetStream (Helm, 1 replica on RPi5, PVC `local-path` 2 Gi, 256 Mi RAM, UID 10001, read-only FS), users `statistics-service` and `collector` with passwords from Secret `nats-auth`, AuthorizationPolicy only from `statistics-service` on 4222, no HTTPRoute. Description: `docs/nats.md`.
- Verification: `helm template` with values, `nats-server -t` on the rendered config, server in Docker (UID 10001, read-only) + nats-box: stream/consumer/ack as `statistics-service`, publish as `collector`, denials (subscription `stats.ingest.>` and `_INBOX.>`, `$JS.API`, anonymous, wrong password), kubeconform as in CI.
- Helm for own apps (2026-11-02): shared chart `charts/app` (contract: SA, Deployment, Service, HTTPRoute, AuthorizationPolicy, ConfigMap/Secret from env, rollout via `checksum/env`). App repos have only `.devops/helm/release.yaml` (HelmRelease, values inline, tag bumped by CI). Migrated: statistics-service, statistics-ui, mon-home-ass; mon-home-ass registered (private repo, `secretRef: flux-system`). CI: lint + kubeconform of the chart here, `helm template` in the apps' `devops.yml`. Fixed CI step `xargs kc` (bash function, had been failing since `apps/nats`).

## Done (2026-11-02)

- Vault + External Secrets Operator replace SOPS: Vault standalone + ESO in `infrastructure/vault.yaml`, SecretStore `vault` in `apps/secret-store.yaml`, `charts/app` value `secrets: true` → ExternalSecret `<app>-secrets` from `secret/apps/<app>`, NATS ExternalSecret `nats-auth` from `secret/apps/nats`. Nothing secret in git (CI: no Secret manifests), app CI keyless; app repos have only `.devops/helm/release.yaml`. Description: `docs/vault.md`.
- No comments in any code or config file across homelab-infra, StatisticsService, Statistics-UI and mon-home-ass; explanations live in docs and commit messages.
- Deploy readiness for a clean-slate bring-up: k3s channel `v1.36`; app GitRepositories poll once a day (`interval: 24h`), deploy now with `flux reconcile kustomization <app> -n flux-system --with-source`; Flux Kustomizations `retryInterval: 1m`; NATS HelmRelease `install.remediation.retries: -1` (waits for `secret/apps/nats`); own-app HelmReleases in the app repos `install.remediation.retries: -1` + `upgrade.remediation.retries: 3`. No `flux reconcile --force` after Vault setup.
- Docs for a from-scratch setup: prerequisites (OS, SSH/sudo, cgroups, firewall, DNS, tools), `.env` table, wait before Vault init, concrete Vault commands, verification with expected output, login check, operations (unseal after reboot, PAT rotation, backups). App guide moved from README to `docs/apps.md` (chart values, ready-made checklist, `valuesFrom` from Vault). Home Assistant database for mon-home-ass in `docs/postgres.md`. User-visible messages in `scripts/new-app.sh`, Terraform and CI in English.

## Decisions

- Terraform only does the machines and the bootstrap. Everything in the cluster goes through GitOps (Flux), which avoids the CRD problem in the Terraform plan and matches the contract ("Git as the source of truth").
- Two Terraform directories, because the k8s/flux provider needs a kubeconfig that only comes into existence in the k3s stage.
- Flux authenticates with a fine-grained PAT over HTTPS instead of a deploy key: one provider fewer.
- Istio `1.30.x`, because 1.31 is in the Helm repo only as RC (the contract assumes 1.31).
- The Flux repo is `homelab-infra`, while the contract says `homelab`.
- HelmRelease in `.devops/helm/` of the app repo, not here. CI bumps the tag in `.devops/` with a commit using `GITHUB_TOKEN`, so Flux only reads. No image automation (contract updated).
- Database: existing Postgres on the Wyse host (outside k3s), database `statistics`, user + schema per app, in the cluster a Service without a selector + EndpointSlice (`docs/postgres.md`). No CNPG and no Postgres in the cluster.
- Inputs as environment variables: `homelab-infra/.env` (`TF_VAR_*`, outside git); the Wyse IP reaches the cluster via ConfigMap `cluster-vars` and `postBuild.substituteFrom` (no IP in git).
- UI: Headlamp/Capacitor locally (zero resources in the cluster, no exposing the admin console). Kiali `auth.strategy: anonymous`, because there is no HTTPRoute; Prometheus with the chart's default jobs (`prometheus.io/*` annotations catch ztunnel and istiod).
- Ready-made apps (Helm) live here in `apps/<name>/`, updates via the semver range in the HelmRelease (no Renovate).
- Queue: NATS JetStream without the NACK controller, statistics-service creates the stream and consumer. No reloader (config checksum triggers the rollout). Collector has the inbox `_INBOX_collector.>`, because `_INBOX.>` would show it messages delivered to statistics-service. Backup at the PVC directory level (the queue is a buffer).
- One chart instead of copies of manifests in every repo: all three apps had an identical shape. The chart comes from GitRepository `flux-system` (`reconcileStrategy: Revision`), no publishing to OCI. Plain config inline in the HelmRelease instead of `config.env`.
- Secrets: SOPS (age-encrypted files in git) replaced by Vault + External Secrets Operator, because secrets should come from a secret provider, not from encrypted files anyone can clone. Vault standalone with file storage, manual unseal, 1 key share. No AuthorizationPolicy on Vault yet, because the Istio CRDs come from the same Flux layer (`infrastructure`).

## Next steps

- First live bring-up per `docs/setup.md` (steps 0–9); fix the docs wherever reality differs.
- mon-home-ass: first CI build on `main` (replaces the placeholder image tag), GHCR package public, Home Assistant recorder on Postgres `home_assistant`. NATS publishing is off for now (`NATS_URL` removed); bringing it back needs a NATS user and its principal in AuthorizationPolicy `nats`.
- statistics-service: switch to `BROKER: jetstream` when ingest is needed (`docs/nats.md`).
- Optional: Reloader for an automatic rollout on secret change; AuthorizationPolicy for Vault in a later Flux layer (after the Istio CRDs).
- Bump Istio to 1.31.x after GA.
- Kiali: before HTTPRoute switch to `openid` via Authelia; waypoint in `apps` for L7 metrics.
- Authelia: values (`pod.kind: Deployment`, storage, OIDC), then forward-auth via `extensionProviders` in istiod.
- Optional: Renovate (major chart bumps), Flux notifications, Secret `ghcr-pull` for private images, first app (`hello`).
