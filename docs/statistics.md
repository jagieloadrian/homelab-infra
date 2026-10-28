# Statistics: statistics-service + statistics-ui

Kroki, żeby obie aplikacje wdrażały się z tego repo. Stan sprawdzony 2026-10-28 w lokalnych repo `StatisticsService` i `Statistics-UI`.

| | statistics-service | statistics-ui |
| --- | --- | --- |
| Repo | `jagieloadrian/statistics-service` | `jagieloadrian/statistics-ui` |
| Manifesty | `.devops/k8s/` (ma `kustomization.yaml`) | `.devops/k8s/` (ma `kustomization.yaml`) |
| Routing | `statistics.home.arpa/api/` | `statistics.home.arpa/` |
| Baza | Postgres (Exposed + Flyway): `DB_URL`, `DB_USER`, `DB_PASSWORD` | brak |
| Sekrety | Secret `statistics-service-secrets` | brak |
| Do usunięcia | `.devops/flux/image-automation.yaml`, komentarz `$imagepolicy` | to samo |

## 1. Rejestracja w homelab-infra

```bash
scripts/new-app.sh own statistics-service
scripts/new-app.sh own statistics-ui
```

W obu wygenerowanych plikach (`clusters/home/apps/statistics-*.yaml`) zmień ścieżkę na `.devops/k8s`:

```yaml
  ignore: |
    /*
    !/.devops/k8s/
...
  path: ./.devops/k8s
```

Powód: w `.devops/` leżą też pliki compose (`authelia-compose/`, `postgres-compose/`). Przy ścieżce `./.devops` Flux próbowałby je zaaplikować jako manifesty.

## 2. W obu repo aplikacji

1. Usuń `.devops/flux/` (Flux image automation nie jest używany) i komentarz `# {"$imagepolicy": ...}` przy `image:`.
2. Dodaj do workflow krok „Deploy” z README (sekcja „Własna aplikacja”) z `permissions.contents: write`. W `sed` podmień ścieżkę na `.devops/k8s/*.yaml`, bo tam jest Deployment.
3. Jeśli `main` ma branch protection, przepuść `github-actions[bot]`.

## 3. statistics-service: baza

1. Na Wyse utwórz użytkownika i schemę `statistics` według [postgres.md](postgres.md), sekcja „Każda aplikacja”.
2. `.devops/k8s/configmap.yaml`:
   ```yaml
   DB_URL: jdbc:postgresql://postgres.apps.svc.cluster.local:5432/statistics?currentSchema=statistics
   DB_USER: statistics
   ```
   Obecny `postgres.databases.svc.cluster.local:5432/statistics` wskazuje na Service, który nie istnieje.

## 4. statistics-service: sekrety (SOPS w repo aplikacji)

1. `.sops.yaml` w katalogu głównym repo:
   ```yaml
   creation_rules:
     - path_regex: \.devops/k8s/.*\.sops\.yaml$
       encrypted_regex: ^(data|stringData)$
       age: age1...   # age-keygen -y ~/.config/sops/age/keys.txt
   ```
2. `.devops/k8s/secrets.sops.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: statistics-service-secrets
     namespace: apps
   type: Opaque
   stringData:
     DB_PASSWORD: <hasło z kroku 3>
     ADMIN_PASSWORD: <hasło admina>
     OIDC_CLIENT_SECRET: ""
   ```
   Potem `sops -e -i .devops/k8s/secrets.sops.yaml` i dopisz `- secrets.sops.yaml` do `resources` w `.devops/k8s/kustomization.yaml`. Nigdy nie commituj tego pliku przed zaszyfrowaniem.
3. README serwisu mówi, że Secret jest w repo homelab. Według kontraktu sekrety leżą teraz w `.devops/` aplikacji, więc README też trzeba poprawić.

## 5. Sprawdzenie

```bash
flux get kustomizations statistics-service statistics-ui
kubectl -n apps get pods
kubectl -n apps port-forward svc/statistics-service 8080:80 &   # health nie jest pod /api/, więc bez gatewaya
curl -s localhost:8080/health/ready
curl -sI http://statistics.home.arpa/                           # UI przez gateway
```
