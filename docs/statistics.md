# Statistics: statistics-service + statistics-ui

Where things live. Step-by-step setup: [setup.md](setup.md).

| | statistics-service | statistics-ui |
| --- | --- | --- |
| Repo (public) | `jagieloadrian/statistics-service` | `jagieloadrian/statistics-ui` |
| Registration here | `clusters/home/apps/statistics-service.yaml` | `clusters/home/apps/statistics-ui.yaml` |
| HelmRelease on `charts/app` (Flux reads from `main`) | `.devops/helm/` | `.devops/helm/` |
| Routing | `statistics.home.arpa/api/` | `statistics.home.arpa/` |
| Configuration | `values.env` in `.devops/helm/release.yaml` → ConfigMap | none |
| Secrets | Vault `secret/apps/statistics-service` (`secrets: true`) → ExternalSecret → Secret ([vault.md](vault.md)) | none |
| Database | Postgres on Wyse, database and schema `statistics` ([postgres.md](postgres.md)) | none |
| Queue | NATS JetStream `nats.apps.svc.cluster.local:4222` (`BROKER: jetstream`, [nats.md](nats.md)) | none |
| Deploy | CI on `main`: Jib image → tag commit to `.devops/helm/release.yaml` | CI on `main`: buildx image → tag commit to `.devops/helm/release.yaml` |

Registrations point to `.devops/helm`, not `.devops`. Next to it in `.devops/` there are compose files (`authelia-compose/`, `postgres-compose/`), which Flux cannot apply.

## Before the first deploy

- [ ] Role and schema `statistics` on Wyse ([setup.md](setup.md), step 2)
- [ ] `image:` in `.devops/helm/release.yaml` on `main` is a tag CI built and pushed to GHCR, in both repos (step 3)
- [ ] GHCR packages public; GitHub App installed + `DEPLOY_APP_CLIENT_ID` / `DEPLOY_APP_PRIVATE_KEY` + App on the ruleset bypass list where `main` is protected, or the CI Deploy step fails ([apps.md](apps.md), own app, step 3)
- [ ] Keys in Vault `secret/apps/statistics-service` (step 7). Without them the statistics-service pod won't start.
