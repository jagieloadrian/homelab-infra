# Setting up the homelab from scratch

Steps 0–7, in this order. At the end, k3s runs on RPi5 + Wyse with Flux and Istio, and `http://statistics.home.arpa/` serves statistics-ui and statistics-service with a database on Postgres on Wyse. Details: [postgres.md](postgres.md), [statistics.md](statistics.md).

## 0. Tools and access

- Locally: `terraform` ≥ 1.6, `kubectl`, `git`; optionally `vault` CLI ([vault.md](vault.md)).
- RPi5 and Wyse: SSH key login, passwordless `sudo`.
- RPi5: append `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/cmdline.txt`, then reboot.
- DNS: wildcard `*.home.arpa` → RPi5 IP (router or Pi-hole).

## 1. Variables and secrets: what goes where

| File | Repo / location | In git | Contents |
| --- | --- | --- | --- |
| `.env` | homelab-infra, root directory | no (`.gitignore`) | Terraform inputs: host IPs, SSH, GitHub token |
| `.devops/helm/release.yaml` (`values.env`) | StatisticsService | yes, plain | application config → ConfigMap `statistics-service-config` |
| Vault `secret/apps/statistics-service` | Vault in the cluster | never | application passwords → Secret `statistics-service-secrets` (`secrets: true`) |
| Vault unseal key + root token | password manager | never | [vault.md](vault.md) |

Statistics-UI has no environment variables: it is a static frontend, and the gateway routes `/api/` to the service.

### homelab-infra/.env

Create a `.env` file in the homelab-infra root directory with this content and fill in the empty values:

```bash
TF_VAR_rpi_host=
TF_VAR_wyse_host=
TF_VAR_ssh_user=
TF_VAR_ssh_private_key=~/.ssh/id_ed25519
TF_VAR_wyse_system_reserved_memory=4Gi

TF_VAR_github_token=
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
| `DB_USER` | `statistics` | Postgres role (step 2) |
| `ADMIN_EMAIL` | `admin@home.arpa` | e-mail of the first admin, created only when the database has no users |
| `AUTH_LOCAL` | `true` | password login; `false` = OIDC only |
| `OIDC_ISSUER` | empty | OIDC provider URL (e.g. Authelia); SSO works when `OIDC_ISSUER` and `OIDC_CLIENT_ID` are set |
| `OIDC_CLIENT_ID` | empty | client registered with the provider (PKCE, redirect `http://statistics.home.arpa/`) |
| `OIDC_NAME` | `SSO` | label on the "Sign in with …" button |
| `CORS_HOSTS` | `statistics.home.arpa` | frontend host |
| `TRUST_PROXY` | `true` | login rate limit counted by `X-Forwarded-For` from the gateway |
| `LOG_FORMAT` | `json` | JSON logs on stdout |

Changing `values.env` + push to `main` = HelmRelease upgrade, new ConfigMap and rollout (`checksum/env` annotation).

### Vault `secret/apps/statistics-service` (step 6)

| Variable | Value |
| --- | --- |
| `DB_PASSWORD` | password of the `statistics` role, the same one you set in Postgres in step 2 |
| `ADMIN_PASSWORD` | password of the `ADMIN_EMAIL` admin; empty = no local admin (the first OIDC login with this e-mail becomes admin) |
| `OIDC_CLIENT_SECRET` | OIDC client secret; empty without SSO or for a public client |

Queue (`BROKER=jetstream`): additionally `NATS_PASSWORD` here and the NATS passwords in `secret/apps/nats` ([nats.md](nats.md)).

## 2. Postgres on Wyse

Following [postgres.md](postgres.md):

1. "Once: Postgres on Wyse": `listen_addresses`, `pg_hba.conf`, `statistics` database.
2. "Each application" with `<app>` = `statistics`. Pick the password (`openssl rand -hex 24`) and keep it in the password manager: the same one goes to Vault `secret/apps/statistics-service` as `DB_PASSWORD` in step 6.

## 3. Repos on GitHub

1. homelab-infra: `git push` to `main` (Flux reads `clusters/home` from `main`).
2. StatisticsService and Statistics-UI: merge `feature-6/cleaning-and-refactoring` → `main` and push. The first build on `main` builds the image and commits its tag to `.devops/helm/release.yaml`. The earlier tag `main-20261028120000-abc1234` does not exist.
3. GitHub → Packages → `statistics-service` and `statistics-ui` → Package settings → visibility **Public**. The cluster pulls images without logging in; new GHCR packages are private by default.
4. Branch protection on `main` (if any) must let `github-actions[bot]` through, because CI commits the tag.

## 4. k3s

```bash
cd ~/IdeaProjects/homelab-infra
set -a; . ./.env; set +a
cd terraform/k3s
terraform init && terraform apply
```

## 5. Flux

```bash
cd ../flux
terraform init && terraform apply
cd ../.. && git pull
```

Flux sets up Gateway API, Istio, `home-gateway`, the `apps` namespace, the `postgres` Service, Vault + External Secrets Operator and both applications on its own. The first run takes a few minutes.

## 6. Vault: init, unseal, configuration, secrets

[vault.md](vault.md), steps 1–4: init and unseal Vault, configure it, put the keys of `secret/apps/statistics-service` (step 1 above, `DB_PASSWORD` from step 2) and, with `BROKER=jetstream`, of `secret/apps/nats`.

Until then the statistics-service pod waits in `CreateContainerConfigError` (no Secret `statistics-service-secrets`) and its HelmRelease fails after 5 min. After the ExternalSecret syncs: `flux reconcile helmrelease statistics-service -n apps --force`.

## 7. Verification

```bash
export KUBECONFIG=~/IdeaProjects/homelab-infra/terraform/kubeconfig
kubectl get nodes -L homelab/node
kubectl -n flux-system get kustomizations
kubectl -n apps get externalsecret
kubectl -n apps get pods
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://statistics@postgres.apps.svc.cluster.local:5432/statistics" -c 'show search_path'
curl -sI http://statistics.home.arpa/
```

## Troubleshooting

| Symptom | Cause / where to look |
| --- | --- |
| `infrastructure` not Ready | `kubectl -n flux-system describe kustomization infrastructure`; missing ConfigMap `cluster-vars` → step 5 |
| `ExternalSecret` not `SecretSynced` | [vault.md](vault.md), "Check" (Vault sealed after a restart, key missing) |
| Pod `ImagePullBackOff` | GHCR package private or image not built yet (step 3) |
| statistics-service keeps restarting, readiness 503 | no connection to Postgres: `pg_hba.conf`, `listen_addresses`, firewall, password (steps 2 and 6) |
| `statistics.home.arpa` not responding | DNS wildcard → RPi5 IP; `kubectl -n istio-ingress get gateway home-gateway` |
