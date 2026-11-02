# Setting up the homelab from scratch

Steps 0–8, in this order. At the end, k3s runs on RPi5 + Wyse with Flux and Istio, and `http://statistics.home.arpa/` serves statistics-ui and statistics-service with a database on Postgres on Wyse. Details: [postgres.md](postgres.md), [statistics.md](statistics.md).

## 0. Tools and access

- Locally: `terraform` ≥ 1.6, `sops`, `age`, `kubectl`, `git`.
- RPi5 and Wyse: SSH key login, passwordless `sudo`.
- RPi5: append `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/cmdline.txt`, then reboot.
- DNS: wildcard `*.home.arpa` → RPi5 IP (router or Pi-hole).

## 1. Variables and secrets: what goes where

| File | Repo / location | In git | Contents |
| --- | --- | --- | --- |
| `.env` | homelab-infra, root directory | no (`.gitignore`) | Terraform inputs: host IPs, SSH, GitHub token, age key path |
| `~/.config/sops/age/keys.txt` | your computer | never | private age key, the only key to the secrets; keep a copy (e.g. in a password manager) |
| `.sops.yaml` | homelab-infra and StatisticsService, root directory | yes | public age key (`age1…`) you encrypt with |
| `.devops/helm/release.yaml` (`values.env`) | StatisticsService | yes, plain | application config → ConfigMap `statistics-service-config` |
| `.devops/helm/secrets.sops.yaml` (`secretEnv`) | StatisticsService | yes, encrypted | application passwords → Secret `statistics-service-secrets` |

Statistics-UI has no environment variables: it is a static frontend, and the gateway routes `/api/` to the service.

### homelab-infra/.env

Create a `.env` file in the homelab-infra root directory with this content and fill in the empty values:

```bash
# --- terraform/k3s ---
TF_VAR_rpi_host=                     # RPi5 IP: k3s server, target of wildcard DNS *.home.arpa
TF_VAR_wyse_host=                    # Wyse 5070 IP: k3s agent + Postgres; in the cluster as ${WYSE_IP}
TF_VAR_ssh_user=                     # user with SSH key and passwordless sudo on both hosts
TF_VAR_ssh_private_key=~/.ssh/id_ed25519
TF_VAR_wyse_system_reserved_memory=4Gi   # Wyse RAM outside pods (HA + Postgres); 8 GB → approx. 3.4 GiB for pods

# --- terraform/flux ---
TF_VAR_github_token=                 # fine-grained PAT: homelab-infra repo only, Contents: read & write
TF_VAR_age_key_file=~/.config/sops/age/keys.txt
```

Terraform reads `TF_VAR_<name>` as variable `<name>`, so load the file before every `terraform`:

```bash
set -a; . ./.env; set +a
```

`TF_VAR_wyse_host` also ends up in the cluster. `terraform/flux` stores it in ConfigMap `flux-system/cluster-vars` as `WYSE_IP`, and Flux substitutes `${WYSE_IP}` in `infrastructure/postgres.yaml`. This keeps the IP out of git.

### StatisticsService/.devops/helm/release.yaml, `values.env` (plain, already in the repo)

| Variable | Value | Meaning |
| --- | --- | --- |
| `DB_URL` | `jdbc:postgresql://postgres.apps.svc.cluster.local:5432/statistics?currentSchema=statistics` | Postgres on Wyse, database and schema `statistics` |
| `DB_USER` | `statistics` | Postgres role (step 4) |
| `ADMIN_EMAIL` | `admin@home.arpa` | e-mail of the first admin, created only when the database has no users |
| `AUTH_LOCAL` | `true` | password login; `false` = OIDC only |
| `OIDC_ISSUER` | empty | OIDC provider URL (e.g. Authelia); SSO works when `OIDC_ISSUER` and `OIDC_CLIENT_ID` are set |
| `OIDC_CLIENT_ID` | empty | client registered with the provider (PKCE, redirect `http://statistics.home.arpa/`) |
| `OIDC_NAME` | `SSO` | label on the "Sign in with …" button |
| `CORS_HOSTS` | `statistics.home.arpa` | frontend host |
| `TRUST_PROXY` | `true` | login rate limit counted by `X-Forwarded-For` from the gateway |
| `LOG_FORMAT` | `json` | JSON logs on stdout |

Changing `values.env` + push to `main` = HelmRelease upgrade, new ConfigMap and rollout (`checksum/env` annotation).

### StatisticsService/.devops/helm/secrets.sops.yaml, `secretEnv` (encrypted)

| Variable | Value |
| --- | --- |
| `DB_PASSWORD` | password of the `statistics` role, e.g. `openssl rand -hex 24`; you enter the same one in Postgres in step 4 |
| `ADMIN_PASSWORD` | password of the `ADMIN_EMAIL` admin; empty = no local admin (the first OIDC login with this e-mail becomes admin) |
| `OIDC_CLIENT_SECRET` | OIDC client secret; empty without SSO or for a public client |

You create and edit it only via `sops` (step 3), so the plain content never hits the disk.

## 2. age key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
age-keygen -y ~/.config/sops/age/keys.txt   # public key age1…
```

Put the public key in place of `age1REPLACE_WITH_YOUR_PUBLIC_KEY` in `homelab-infra/.sops.yaml` and `StatisticsService/.sops.yaml`. Make a copy of `keys.txt`: without it you cannot decrypt any secret.

## 3. statistics-service secrets

```bash
cd ~/IdeaProjects/StatisticsService
sops .devops/helm/secrets.sops.yaml   # editor; save = encrypt
```

Content:

```yaml
secretEnv:
  DB_PASSWORD: <openssl rand -hex 24>
  ADMIN_PASSWORD: <admin password>
  OIDC_CLIENT_SECRET: ""
```

Check that the values are encrypted (`ENC[...]` in `.devops/helm/secrets.sops.yaml`) and commit. View it later: `sops -d .devops/helm/secrets.sops.yaml`. Flux decrypts it into Secret `statistics-service-values`, and the HelmRelease reads it via `valuesFrom`.

Queue (`BROKER=jetstream`): first the NATS passwords in `homelab-infra/apps/nats/secret.sops.yaml`, then `NATS_USER`/`NATS_PASSWORD` in this file ([nats.md](nats.md)).

## 4. Postgres on Wyse

Following [postgres.md](postgres.md):

1. "Once: Postgres on Wyse": `listen_addresses`, `pg_hba.conf`, `statistics` database.
2. "Each application" with `<app>` = `statistics` and the `DB_PASSWORD` password from step 3 (`sops -d .devops/helm/secrets.sops.yaml | grep DB_PASSWORD`).

## 5. Repos on GitHub

1. homelab-infra: `git push` to `main` (Flux reads `clusters/home` from `main`).
2. StatisticsService and Statistics-UI: merge `feature-6/cleaning-and-refactoring` → `main` and push. The first build on `main` builds the image and commits its tag to `.devops/helm/release.yaml`. The earlier tag `main-20261028120000-abc1234` does not exist.
3. GitHub → Packages → `statistics-service` and `statistics-ui` → Package settings → visibility **Public**. The cluster pulls images without logging in; new GHCR packages are private by default.
4. Branch protection on `main` (if any) must let `github-actions[bot]` through, because CI commits the tag.

## 6. k3s

```bash
cd ~/IdeaProjects/homelab-infra
set -a; . ./.env; set +a
cd terraform/k3s
terraform init && terraform apply   # installs k3s on RPi5 and Wyse, writes terraform/kubeconfig
```

## 7. Flux

```bash
cd ../flux                          # .env already loaded in this shell
terraform init && terraform apply   # Flux, Secret sops-age, ConfigMap cluster-vars
cd ../.. && git pull                # bootstrap commits clusters/home/flux-system
```

Flux sets up Gateway API, Istio, `home-gateway`, the `apps` namespace, the `postgres` Service and both applications on its own. The first run takes a few minutes.

## 8. Verification

```bash
export KUBECONFIG=~/IdeaProjects/homelab-infra/terraform/kubeconfig
kubectl get nodes -L homelab/node                  # rpi and wyse, Ready
kubectl -n flux-system get kustomizations          # infrastructure, apps, statistics-*: Ready True
kubectl -n apps get pods                           # statistics-service, statistics-ui: Running
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://statistics@postgres.apps.svc.cluster.local:5432/statistics" -c 'show search_path'
curl -sI http://statistics.home.arpa/              # 200 from UI
```

## Troubleshooting

| Symptom | Cause / where to look |
| --- | --- |
| `infrastructure` not Ready | `kubectl -n flux-system describe kustomization infrastructure`; missing ConfigMap `cluster-vars` → step 7 |
| `statistics-service` not Ready: `secrets.sops.yaml` does not exist or decryption error | step 3; the key in `.sops.yaml` must match the `keys.txt` passed in step 7 |
| Pod `ImagePullBackOff` | GHCR package private or image not built yet (step 5) |
| statistics-service keeps restarting, readiness 503 | no connection to Postgres: `pg_hba.conf`, `listen_addresses`, firewall, password (step 4) |
| `statistics.home.arpa` not responding | DNS wildcard → RPi5 IP; `kubectl -n istio-ingress get gateway home-gateway` |
