# Statistics: statistics-service + statistics-ui

Gdzie co leży. Stawianie krok po kroku: [setup.md](setup.md).

| | statistics-service | statistics-ui |
| --- | --- | --- |
| Repo | `jagieloadrian/statistics-service` | `jagieloadrian/statistics-ui` |
| Rejestracja tutaj | `clusters/home/apps/statistics-service.yaml` | `clusters/home/apps/statistics-ui.yaml` |
| Manifesty (Flux czyta z `main`) | `.devops/k8s/` | `.devops/k8s/` |
| Routing | `statistics.home.arpa/api/` | `statistics.home.arpa/` |
| Konfiguracja | `.devops/k8s/config.env` → ConfigMap | brak |
| Sekrety | `.devops/k8s/secrets.sops.env` (SOPS) → Secret | brak |
| Baza | Postgres na Wyse, baza i schema `statistics` ([postgres.md](postgres.md)) | brak |
| Deploy | CI na `main`: obraz Jib → commit tagu do `.devops/k8s` | CI na `main`: obraz buildx → commit tagu do `.devops/k8s` |

Rejestracje wskazują na `.devops/k8s`, nie na `.devops`. Obok w `.devops/` leżą pliki compose (`authelia-compose/`, `postgres-compose/`), których Flux nie może aplikować.

## Do zrobienia przed pierwszym deployem

- [ ] Klucz age w `StatisticsService/.sops.yaml` ([setup.md](setup.md), krok 2)
- [ ] `.devops/k8s/secrets.sops.env` (krok 3). Bez niego Kustomization `statistics-service` się nie zbuduje.
- [ ] Rola i schema `statistics` na Wyse (krok 4)
- [ ] Merge `feature-6/cleaning-and-refactoring` → `main` w obu repo, paczki GHCR publiczne (krok 5)
