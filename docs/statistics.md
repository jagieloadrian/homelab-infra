# Statistics: statistics-service + statistics-ui

Where things live. Step-by-step setup: [setup.md](setup.md).

| | statistics-service | statistics-ui |
| --- | --- | --- |
| Repo | `jagieloadrian/statistics-service` | `jagieloadrian/statistics-ui` |
| Registration here | `clusters/home/apps/statistics-service.yaml` | `clusters/home/apps/statistics-ui.yaml` |
| HelmRelease on `charts/app` (Flux reads from `main`) | `.devops/helm/` | `.devops/helm/` |
| Routing | `statistics.home.arpa/api/` | `statistics.home.arpa/` |
| Configuration | `values.env` in `.devops/helm/release.yaml` → ConfigMap | none |
| Secrets | `.devops/helm/secrets.sops.yaml` (SOPS, `secretEnv`) → Secret | none |
| Database | Postgres on Wyse, database and schema `statistics` ([postgres.md](postgres.md)) | none |
| Queue | NATS JetStream `nats.apps.svc.cluster.local:4222` with `BROKER=jetstream` ([nats.md](nats.md)) | none |
| Deploy | CI on `main`: Jib image → tag commit to `.devops/helm/release.yaml` | CI on `main`: buildx image → tag commit to `.devops/helm/release.yaml` |

Registrations point to `.devops/helm`, not `.devops`. Next to it in `.devops/` there are compose files (`authelia-compose/`, `postgres-compose/`), which Flux cannot apply.

## Before the first deploy

- [ ] Age key in `StatisticsService/.sops.yaml` ([setup.md](setup.md), step 2)
- [ ] `.devops/helm/secrets.sops.yaml` (step 3). Without it the `statistics-service` Kustomization won't build.
- [ ] Role and schema `statistics` on Wyse (step 4)
- [ ] Merge `feature-6/cleaning-and-refactoring` → `main` in both repos, GHCR packages public (step 5)
