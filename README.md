# homelab-infra

Platforma z dokumentu „Homelab Platform Contract”: 2-node'owy k3s (RPi5 arm64 + Dell Wyse 5070 amd64), Istio ambient, Gateway API, Flux, SOPS (age).

| Co | Gdzie | Jak |
| --- | --- | --- |
| k3s server (RPi5, `homelab/node=rpi`) + agent (Wyse, `homelab/node=wyse`) | `terraform/k3s` | Terraform przez SSH |
| Flux, Secret `sops-age` | `terraform/flux` | Terraform (`fluxcd/flux`) |
| Gateway API v1.6 CRDs, Istio ambient (base, istiod, cni, ztunnel) | `infrastructure/` | Flux |
| Gateway `home-gateway` (`istio-ingress`), namespace `apps` z ambient | `infrastructure/platform.yaml` | Flux |
| Własne aplikacje: lista, plik na aplikację | `clusters/home/apps/` | Flux (read-only z repo aplikacji) |
| Manifesty własnych aplikacji | `.devops/` w repo aplikacji | Flux |
| Gotowe aplikacje (Helm chart, bez budowania) | `apps/<name>/` | Flux |
| NATS z JetStream: kolejka ingestu statistics-service | `apps/nats/` | Flux (Helm) |
| Rejestracja aplikacji | `scripts/new-app.sh` | skrypt |

## Stawianie od zera

Krok po kroku, razem z tym, co wpisać do `.env` i plików sekretów: **[docs/setup.md](docs/setup.md)**.

W skrócie: `.env` (wejścia Terraform) → klucz age → sekrety aplikacji → Postgres na Wyse → push → `terraform apply` w `terraform/k3s`, potem w `terraform/flux`.

## Aplikacje

Dwa rodzaje, oba w namespace `apps` (ambient mesh):

| Rodzaj | Konfig | Rejestracja | Aktualizacje |
| --- | --- | --- | --- |
| Własna (budowana w CI) | `.devops/` w repo aplikacji | `scripts/new-app.sh own <name>` | CI commituje nowy tag do `.devops/` |
| Gotowa (Helm chart: Authelia, oauth2-proxy…) | `apps/<name>/` tutaj | `scripts/new-app.sh helm <name> <repo> <chart> <wersja> [port]` | Flux sam instaluje nowe wersje z zakresu semver |

### Gotowa aplikacja (Helm chart)

```bash
scripts/new-app.sh helm authelia https://charts.authelia.com authelia 0.11.x 80
```

Powstaje `apps/authelia/release.yaml`: HelmRepository (OCI też: `oci://...`), HelmRelease, HTTPRoute `authelia.home.arpa`, AuthorizationPolicy. Potem:

1. `helm show values authelia --repo https://charts.authelia.com` i wpisz potrzebne `values` (checklista kontraktu w pliku).
2. Sekrety (hasła, klucze OIDC) jako values w Secret:
   ```bash
   cat > apps/authelia/secret.sops.yaml <<'EOF'
   apiVersion: v1
   kind: Secret
   metadata:
     name: authelia-values
   stringData:
     values.yaml: |
       # wrażliwe values charta
   EOF
   sops -e -i apps/authelia/secret.sops.yaml   # .sops.yaml: wpisz swój klucz publiczny age
   ```
   i odkomentuj `valuesFrom` w HelmRelease. Nigdy nie commituj niezaszyfrowanego pliku.
3. Commit + push. Flux wdraża w ≤ 10 min (`flux reconcile kustomization apps --with-source` od razu).

Wersja `0.11.x` oznacza, że Flux sam instaluje nowe wydania 0.11.*. Major bump to ręczna zmiana zakresu.
Authelia: chart domyślnie tworzy DaemonSet, ustaw `pod.kind: Deployment`. Forward-auth dla innych aplikacji wymaga `extensionProviders` w istiod (osobny krok).

### Własna aplikacja (`.devops/`)

Przepływ: merge do `main` → CI buduje obraz `main-<ts>-<sha7>` → CI podbija tag w `.devops/` i commituje → Flux (co 1 min) widzi commit → rollout. Rollback = `git revert` w repo aplikacji.

1. W repo aplikacji katalog `.devops/` z manifestami wg kontraktu (ServiceAccount, Deployment, Service, HTTPRoute, AuthorizationPolicy). `namespace` można pominąć, Flux wymusza `apps`.
2. Zmienne środowiskowe jako pliki dotenv obok manifestów (wzór: StatisticsService `.devops/k8s/`):
   - `config.env`: jawna konfiguracja, `configMapGenerator`,
   - `secrets.sops.env`: sekrety, `secretGenerator`, tworzone i edytowane tylko przez `sops <plik>`; Flux odszyfrowuje przy budowaniu,
   - Deployment: `envFrom` na nazwy generatorów (kustomize dopisuje hash, więc zmiana pliku robi rollout),
   - `.sops.yaml` w repo aplikacji:
     ```yaml
     creation_rules:
       - path_regex: \.devops/k8s/secrets\.sops\.env$
         age: age1...   # age-keygen -y ~/.config/sops/age/keys.txt
     ```
3. W workflow `build` z kontraktu: `permissions.contents: write` i krok po pushu obrazu:
   ```yaml
         - name: Deploy (bump image tag)
           if: github.ref == 'refs/heads/main'
           run: |
             sed -i -E "s#(image: ghcr.io/${{ github.repository_owner }}/${{ github.event.repository.name }}):[^[:space:]]+#\1:${{ steps.tag.outputs.tag }}#" .devops/*.yaml
             git config user.name 'github-actions[bot]'
             git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
             git commit -am "chore(deploy): ${{ steps.tag.outputs.tag }}"
             git pull --rebase && git push
   ```
   `.devops/*.yaml` zamień na katalog, w którym leży Deployment (np. `.devops/k8s/*.yaml`). Push z `GITHUB_TOKEN` nie odpala kolejnego workflow, więc nie ma pętli. Branch protection na `main` musi przepuszczać `github-actions[bot]`.
4. Rejestracja tutaj: `scripts/new-app.sh own hello`, commit + push.
   Prywatne repo aplikacji: dodaj `secretRef` z read-only tokenem do `GitRepository`.

## Instrukcje

- [Stawianie od zera](docs/setup.md): kolejne kroki, `.env`, klucz age, sekrety
- [Postgres na Wyse 5070](docs/postgres.md): baza poza klastrem, użytkownik + schema per aplikacja
- [Statistics](docs/statistics.md): wdrożenie statistics-service i statistics-ui
- [Panele UI](docs/ui.md): Headlamp i Capacitor lokalnie, Kiali przez port-forward
- [NATS z JetStream](docs/nats.md): kolejka dla statistics-service, użytkownicy, hasła, test, backup

## Do podbicia

- Istio `1.30.x` → `1.31.x`, gdy 1.31 wyjdzie z RC (`infrastructure/istio.yaml`).
- `wyse_system_reserved_memory` (domyślnie `4Gi`, ok. 3.4 GiB dla podów przy 8 GB RAM) pod realny RAM Wyse.
