# homelab-infra

Homelab platform: 2-node k3s (RPi5 arm64 + Dell Wyse 5070 amd64), Istio ambient, Gateway API, Flux, Vault + External Secrets Operator. Apps get HTTP routes on `*.home.arpa`, secrets from Vault, and a database in Postgres on the Wyse.

| What | Where | How |
| --- | --- | --- |
| k3s server (RPi5, `homelab/node=rpi`) + agent (Wyse, `homelab/node=wyse`) | `terraform/k3s` | Terraform over SSH |
| Flux | `terraform/flux` | Terraform (`fluxcd/flux`) |
| Gateway API v1.6 CRDs, Istio ambient (base, istiod, cni, ztunnel) | `infrastructure/` | Flux |
| Gateway `home-gateway` (`istio-ingress`), namespace `apps` with ambient | `infrastructure/platform.yaml` | Flux |
| Vault + External Secrets Operator: app secrets | `infrastructure/vault.yaml` | Flux |
| Own apps: list, one file per app | `clusters/home/apps/` | Flux (read-only from app repos) |
| Shared Helm chart for own apps | `charts/app/` | Flux (HelmRelease from app repo) |
| HelmRelease + values of own apps | `.devops/helm/` in app repo | Flux |
| Ready-made apps (Helm chart, no build) | `apps/<name>/` | Flux |
| NATS with JetStream: statistics-service ingest queue | `apps/nats/` | Flux (Helm) |
| App registration | `scripts/new-app.sh` | script |

## Guides

- [Setup from scratch](docs/setup.md): prerequisites, `.env`, steps in order, operations
- [Adding apps](docs/apps.md): own apps on `charts/app`, ready-made Helm charts
- [Vault](docs/vault.md): app secrets, init, unseal, backup
- [Postgres on Wyse 5070](docs/postgres.md): database outside the cluster, user + schema per app
- [Statistics](docs/statistics.md): statistics-service and statistics-ui
- [NATS with JetStream](docs/nats.md): queue for statistics-service, users, passwords, test, backup
- [UI panels](docs/ui.md): Headlamp and Capacitor locally, Kiali via port-forward

## To bump

- Istio `1.30.x` → `1.31.x` once 1.31 is out of RC (`infrastructure/istio.yaml`).
- `wyse_system_reserved_memory` (default `4Gi`, about 3.4 GiB for pods with 8 GB RAM) to match the Wyse's real RAM.
