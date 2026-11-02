# Statistics: statistics-service + statistics-ui

Gdzie co leży. Stawianie krok po kroku: [setup.md](setup.md).

| | statistics-service | statistics-ui |
| --- | --- | --- |
| Repo | `jagieloadrian/statistics-service` | `jagieloadrian/statistics-ui` |
| Rejestracja tutaj | `clusters/home/apps/statistics-service.yaml` | `clusters/home/apps/statistics-ui.yaml` |
| HelmRelease na `charts/app` (Flux czyta z `main`) | `.devops/helm/` | `.devops/helm/` |
| Routing | `statistics.home.arpa/api/` | `statistics.home.arpa/` |
| Konfiguracja | `values.env` w `.devops/helm/release.yaml` → ConfigMap | brak |
| Sekrety | `.devops/helm/secrets.sops.yaml` (SOPS, `secretEnv`) → Secret | brak |
| Baza | Postgres na Wyse, baza i schema `statistics` ([postgres.md](postgres.md)) | brak |
| Kolejka | NATS JetStream `nats.apps.svc.cluster.local:4222` przy `BROKER=jetstream` ([nats.md](nats.md)) | brak |
| Deploy | CI na `main`: obraz Jib → commit tagu do `.devops/helm/release.yaml` | CI na `main`: obraz buildx → commit tagu do `.devops/helm/release.yaml` |

Rejestracje wskazują na `.devops/helm`, nie na `.devops`. Obok w `.devops/` leżą pliki compose (`authelia-compose/`, `postgres-compose/`), których Flux nie może aplikować.

## Do zrobienia przed pierwszym deployem

- [ ] Klucz age w `StatisticsService/.sops.yaml` ([setup.md](setup.md), krok 2)
- [ ] `.devops/helm/secrets.sops.yaml` (krok 3). Bez niego Kustomization `statistics-service` się nie zbuduje.
- [ ] Rola i schema `statistics` na Wyse (krok 4)
- [ ] Merge `feature-6/cleaning-and-refactoring` → `main` w obu repo, paczki GHCR publiczne (krok 5)
