# Stawianie homelaba od zera

Kroki 0–8, w tej kolejności. Na końcu działa k3s na RPi5 + Wyse z Fluxem i Istio, a pod `http://statistics.home.arpa/` statistics-ui i statistics-service z bazą na Postgresie na Wyse. Szczegóły: [postgres.md](postgres.md), [statistics.md](statistics.md).

## 0. Narzędzia i dostęp

- Lokalnie: `terraform` ≥ 1.6, `sops`, `age`, `kubectl`, `git`.
- RPi5 i Wyse: logowanie po SSH kluczem, `sudo` bez hasła.
- RPi5: w `/boot/firmware/cmdline.txt` dopisz `cgroup_memory=1 cgroup_enable=memory`, potem reboot.
- DNS: wildcard `*.home.arpa` → IP RPi5 (router albo Pi-hole).

## 1. Zmienne i sekrety: co i gdzie

| Plik | Repo / miejsce | W gicie | Zawartość |
| --- | --- | --- | --- |
| `.env` | homelab-infra, katalog główny | nie (`.gitignore`) | wejścia Terraform: IP hostów, SSH, token GitHub, ścieżka klucza age |
| `~/.config/sops/age/keys.txt` | Twój komputer | nigdy | prywatny klucz age, jedyny klucz do sekretów; trzymaj kopię (np. w menedżerze haseł) |
| `.sops.yaml` | homelab-infra i StatisticsService, katalog główny | tak | publiczny klucz age (`age1…`), którym szyfrujesz |
| `.devops/k8s/config.env` | StatisticsService | tak, jawny | konfiguracja aplikacji → ConfigMap `statistics-service-config` |
| `.devops/k8s/secrets.sops.env` | StatisticsService | tak, zaszyfrowany | hasła aplikacji → Secret `statistics-service-secrets` |

Statistics-UI nie ma zmiennych środowiskowych: to statyczny frontend, a `/api/` kieruje do serwisu gateway.

### homelab-infra/.env

Utwórz plik `.env` w katalogu głównym homelab-infra z tą treścią i uzupełnij puste wartości:

```bash
# --- terraform/k3s ---
TF_VAR_rpi_host=                     # IP RPi5: k3s server, cel wildcard DNS *.home.arpa
TF_VAR_wyse_host=                    # IP Wyse 5070: k3s agent + Postgres; w klastrze jako ${WYSE_IP}
TF_VAR_ssh_user=                     # user z SSH kluczem i sudo bez hasła na obu hostach
TF_VAR_ssh_private_key=~/.ssh/id_ed25519
TF_VAR_wyse_system_reserved_memory=4Gi   # RAM Wyse poza podami (HA + Postgres); 8 GB → ok. 3.4 GiB dla podów

# --- terraform/flux ---
TF_VAR_github_token=                 # fine-grained PAT: tylko repo homelab-infra, Contents: read & write
TF_VAR_age_key_file=~/.config/sops/age/keys.txt
```

Terraform czyta `TF_VAR_<nazwa>` jako zmienną `<nazwa>`, więc przed każdym `terraform` załaduj plik:

```bash
set -a; . ./.env; set +a
```

`TF_VAR_wyse_host` trafia też do klastra. `terraform/flux` zapisuje go w ConfigMap `flux-system/cluster-vars` jako `WYSE_IP`, a Flux podstawia `${WYSE_IP}` w `infrastructure/postgres.yaml`. Dzięki temu IP nie jest w gicie.

### StatisticsService/.devops/k8s/config.env (jawny, już w repo)

| Zmienna | Wartość | Znaczenie |
| --- | --- | --- |
| `DB_URL` | `jdbc:postgresql://postgres.apps.svc.cluster.local:5432/statistics?currentSchema=statistics` | Postgres na Wyse, baza i schema `statistics` |
| `DB_USER` | `statistics` | rola w Postgresie (krok 4) |
| `ADMIN_EMAIL` | `admin@home.arpa` | e-mail pierwszego admina, tworzonego tylko gdy w bazie nie ma użytkowników |
| `AUTH_LOCAL` | `true` | logowanie hasłem; `false` = tylko OIDC |
| `OIDC_ISSUER` | pusty | URL dostawcy OIDC (np. Authelia); SSO działa, gdy ustawione są `OIDC_ISSUER` i `OIDC_CLIENT_ID` |
| `OIDC_CLIENT_ID` | pusty | klient zarejestrowany u dostawcy (PKCE, redirect `http://statistics.home.arpa/`) |
| `OIDC_NAME` | `SSO` | napis na przycisku „Sign in with …” |
| `CORS_HOSTS` | `statistics.home.arpa` | host frontendu |
| `TRUST_PROXY` | `true` | limit logowań liczony po `X-Forwarded-For` z gatewaya |
| `LOG_FORMAT` | `json` | logi JSON na stdout |

Zmiana tego pliku + push do `main` = nowy ConfigMap i rollout.

### StatisticsService/.devops/k8s/secrets.sops.env (zaszyfrowany)

| Zmienna | Wartość |
| --- | --- |
| `DB_PASSWORD` | hasło roli `statistics`, np. `openssl rand -hex 24`; to samo wpiszesz w Postgresie w kroku 4 |
| `ADMIN_PASSWORD` | hasło admina `ADMIN_EMAIL`; pusty = bez lokalnego admina (adminem zostaje pierwsze logowanie przez OIDC z tym e-mailem) |
| `OIDC_CLIENT_SECRET` | sekret klienta OIDC; pusty bez SSO albo dla klienta publicznego |

Tworzysz i edytujesz go tylko przez `sops` (krok 3), więc jawna treść nigdy nie trafia na dysk.

## 2. Klucz age

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # klucz publiczny age1…
```

Wpisz klucz publiczny w miejsce `age1REPLACE_WITH_YOUR_PUBLIC_KEY` w `homelab-infra/.sops.yaml` i `StatisticsService/.sops.yaml`. Zrób kopię `keys.txt`: bez niego nie odszyfrujesz żadnego sekretu.

## 3. Sekrety statistics-service

```bash
cd ~/IdeaProjects/StatisticsService
sops .devops/k8s/secrets.sops.env   # edytor; zapis = szyfrowanie
```

Treść:

```bash
DB_PASSWORD=<openssl rand -hex 24>
ADMIN_PASSWORD=<hasło admina>
OIDC_CLIENT_SECRET=
```

Sprawdź, że plik jest zaszyfrowany (`grep sops_version .devops/k8s/secrets.sops.env`), i zrób commit. Podgląd później: `sops -d .devops/k8s/secrets.sops.env`.

Kolejka (`BROKER=jetstream`): najpierw hasła NATS w `homelab-infra/apps/nats/secret.sops.yaml`, potem `NATS_USER`/`NATS_PASSWORD` w tym pliku ([nats.md](nats.md)).

## 4. Postgres na Wyse

Według [postgres.md](postgres.md):

1. „Raz: Postgres na Wyse”: `listen_addresses`, `pg_hba.conf`, baza `statistics`.
2. „Każda aplikacja” z `<app>` = `statistics` i hasłem `DB_PASSWORD` z kroku 3 (`sops -d .devops/k8s/secrets.sops.env | grep DB_PASSWORD`).

## 5. Repo na GitHubie

1. homelab-infra: `git push` na `main` (Flux czyta `clusters/home` z `main`).
2. StatisticsService i Statistics-UI: merge `feature-6/cleaning-and-refactoring` → `main` i push. Pierwszy build na `main` buduje obraz i commituje jego tag do `.devops/k8s`. Wcześniejszy tag `main-20261028120000-abc1234` nie istnieje.
3. GitHub → Packages → `statistics-service` i `statistics-ui` → Package settings → widoczność **Public**. Klaster pobiera obrazy bez logowania; nowe paczki GHCR są domyślnie prywatne.
4. Branch protection na `main` (jeśli jest) musi przepuszczać `github-actions[bot]`, bo CI commituje tag.

## 6. k3s

```bash
cd ~/IdeaProjects/homelab-infra
set -a; . ./.env; set +a
cd terraform/k3s
terraform init && terraform apply   # instaluje k3s na RPi5 i Wyse, zapisuje terraform/kubeconfig
```

## 7. Flux

```bash
cd ../flux                          # .env już załadowany w tej powłoce
terraform init && terraform apply   # Flux, Secret sops-age, ConfigMap cluster-vars
cd ../.. && git pull                # bootstrap commituje clusters/home/flux-system
```

Flux sam stawia Gateway API, Istio, `home-gateway`, namespace `apps`, Service `postgres` i obie aplikacje. Pierwsze uruchomienie trwa kilka minut.

## 8. Sprawdzenie

```bash
export KUBECONFIG=~/IdeaProjects/homelab-infra/terraform/kubeconfig
kubectl get nodes -L homelab/node                  # rpi i wyse, Ready
kubectl -n flux-system get kustomizations          # infrastructure, apps, statistics-*: Ready True
kubectl -n apps get pods                           # statistics-service, statistics-ui: Running
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://statistics@postgres.apps.svc.cluster.local:5432/statistics" -c 'show search_path'
curl -sI http://statistics.home.arpa/              # 200 z UI
```

## Gdy coś nie działa

| Objaw | Przyczyna / gdzie patrzeć |
| --- | --- |
| `infrastructure` nie Ready | `kubectl -n flux-system describe kustomization infrastructure`; brak ConfigMap `cluster-vars` → krok 7 |
| `statistics-service` nie Ready: `secrets.sops.env` nie istnieje albo błąd deszyfrowania | krok 3; klucz w `.sops.yaml` musi pasować do `keys.txt` przekazanego w kroku 7 |
| Pod `ImagePullBackOff` | paczka GHCR prywatna albo obraz jeszcze się nie zbudował (krok 5) |
| statistics-service restartuje się, readiness 503 | brak połączenia z Postgresem: `pg_hba.conf`, `listen_addresses`, firewall, hasło (krok 4) |
| `statistics.home.arpa` nie odpowiada | DNS wildcard → IP RPi5; `kubectl -n istio-ingress get gateway home-gateway` |
