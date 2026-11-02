# Setting up the homelab from scratch

Do steps 0–9 in this order. At the end, k3s runs on the RPi5 and the Wyse with Flux and Istio. `http://statistics.home.arpa/` serves statistics-ui and statistics-service, with the database in Postgres on the Wyse. Flux also deploys NATS and mon-home-ass.

In commands, `<homelab-infra checkout>` is the directory where you cloned this repo.

## 0. Prerequisites

### Hosts

| Host | Role | OS |
| --- | --- | --- |
| Raspberry Pi 5 | k3s server, Vault, NATS, ingress gateway, target of `*.home.arpa` | Raspberry Pi OS Lite 64-bit (arm64) |
| Dell Wyse 5070 | k3s agent, Postgres, Home Assistant | Debian or Ubuntu, 64-bit |

k3s can't run on Home Assistant OS. On the Wyse, run Home Assistant and Postgres on Debian/Ubuntu (for example in Docker).

Give both hosts a fixed IP: a DHCP reservation on the router or a static address on the host. k3s, `.env` and DNS use these IPs.

### SSH and sudo

Use the same user on both hosts. From the laptop, copy your SSH key:

```bash
ssh-copy-id <user>@<RPi5 IP>
ssh-copy-id <user>@<Wyse IP>
```

On each host, allow sudo without a password. Run `sudo visudo -f /etc/sudoers.d/<user>` and add this line:

```
<user> ALL=(ALL) NOPASSWD: ALL
```

The docs use the short names `rpi` and `wyse` (`ssh rpi`, `ssh wyse`). Add them to `~/.ssh/config` on the laptop:

```
Host rpi
  HostName <RPi5 IP>
  User <user>

Host wyse
  HostName <Wyse IP>
  User <user>
```

Terraform does not use these names. It reads the IPs from `.env` (step 1).

### RPi5: memory cgroups

k3s needs memory cgroups. `/boot/firmware/cmdline.txt` holds a single line. Add `cgroup_memory=1 cgroup_enable=memory` to the end of that existing line, separated by a space. Do not add a new line. Then reboot:

```bash
ssh -t rpi sudo nano /boot/firmware/cmdline.txt
ssh rpi sudo reboot
```

### Firewall

Skip this if `ufw` and `firewalld` are off. Otherwise open:

| Host | Allow |
| --- | --- |
| RPi5 | 6443/tcp (k3s API, from the Wyse and the laptop), 80/tcp (gateway, from the LAN) |
| both | 10250/tcp (kubelet) and 8472/udp (flannel VXLAN) between the two hosts |
| both | all traffic from `10.42.0.0/16` (pods) and `10.43.0.0/16` (services) |
| Wyse | 5432/tcp (Postgres) from `10.42.0.0/16` and the RPi5 IP ([postgres.md](postgres.md)) |

Example with `ufw` on the RPi5:

```bash
sudo ufw allow 6443/tcp
sudo ufw allow 80/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 8472/udp
sudo ufw allow from 10.42.0.0/16
sudo ufw allow from 10.43.0.0/16
```

### DNS

Every `*.home.arpa` name must resolve to the RPi5 IP. With dnsmasq (many routers, Pi-hole), create a file such as `/etc/dnsmasq.d/99-home-arpa.conf` on the DNS host:

```
address=/home.arpa/<RPi5 IP>
```

Then restart dnsmasq (`sudo systemctl restart dnsmasq`, on Pi-hole `sudo systemctl restart pihole-FTL`). The Pi-hole web UI has no wildcard records, so use the file. Pi-hole v6 reads `/etc/dnsmasq.d/` only when the setting `misc.etc_dnsmasq_d` is on.

Check from the laptop. It must print the RPi5 IP:

```bash
getent hosts statistics.home.arpa
```

### Tools on the laptop

| Tool | Used for |
| --- | --- |
| `git` | this repo and the app repos |
| `terraform` ≥ 1.6 | steps 4 and 5 |
| `kubectl` | everything in the cluster |
| `flux` CLI | Flux status (`flux get ...`) |
| `vault` CLI | Vault configuration and secrets ([vault.md](vault.md), steps 3–4) |
| `openssl` | generating passwords |
| `curl` | checks |
| `helm`, `yq` | adding apps ([apps.md](apps.md)) |

## 1. Variables and secrets: what goes where

| File | Repo / location | In git | Contents |
| --- | --- | --- | --- |
| `.env` | homelab-infra, root directory | no (`.gitignore`) | Terraform inputs: host IPs, SSH, GitHub token |
| `.devops/helm/release.yaml` (`values.env`) | app repo | yes, plain | application config → ConfigMap `<app>-config` |
| Vault `secret/apps/<app>` | Vault in the cluster | never | application passwords → Secret `<app>-secrets` |
| Vault unseal key + root token | password manager | never | [vault.md](vault.md) |

### homelab-infra/.env

Create `.env` in the homelab-infra root directory and fill in the empty values:

```bash
TF_VAR_rpi_host=
TF_VAR_wyse_host=
TF_VAR_ssh_user=
TF_VAR_ssh_private_key=~/.ssh/id_ed25519
TF_VAR_wyse_system_reserved_memory=4Gi
TF_VAR_github_token=
```

| Variable | Used by | Value |
| --- | --- | --- |
| `TF_VAR_rpi_host` | `terraform/k3s` | RPi5 IP. The k3s server, and the target of the `*.home.arpa` DNS wildcard. |
| `TF_VAR_wyse_host` | `terraform/k3s`, `terraform/flux` | Wyse IP. The k3s agent and the Postgres host. In the cluster it is `${WYSE_IP}` (below). |
| `TF_VAR_ssh_user` | `terraform/k3s` | the user with SSH key login and passwordless sudo on both hosts (step 0) |
| `TF_VAR_ssh_private_key` | `terraform/k3s` | private key of that user |
| `TF_VAR_wyse_system_reserved_memory` | `terraform/k3s` | Wyse RAM kept for Home Assistant and Postgres, outside the pods. `4Gi` on an 8 GB Wyse leaves about 3.4 GiB for pods. |
| `TF_VAR_github_token` | `terraform/flux` | fine-grained PAT. Repository access: `homelab-infra` with Contents read and write (the bootstrap commits to it), `mon-home-ass` with Contents read (private repo). |
| `TF_VAR_github_owner` | `terraform/flux` | optional, only for a fork: your GitHub user. Default `jagieloadrian`. |

Terraform reads `TF_VAR_<name>` as variable `<name>`. Load the file in the shell before every `terraform` command:

```bash
set -a; . ./.env; set +a
```

`terraform/flux` stores `TF_VAR_wyse_host` in ConfigMap `flux-system/cluster-vars` as `WYSE_IP`. Flux substitutes `${WYSE_IP}` in `infrastructure/postgres.yaml`. This keeps the IP out of git.

Fork: set `TF_VAR_github_owner`, and replace `jagieloadrian` in the `url:` of `clusters/home/apps/*.yaml` and `_app.yaml.example`, and in the image names in each app repo's `.devops/helm/release.yaml`. `grep -rn jagieloadrian` finds them.

### statistics-service `values.env` (plain, already in its `.devops/helm/release.yaml`)

| Variable | Value | Meaning |
| --- | --- | --- |
| `DB_URL` | `jdbc:postgresql://postgres.apps.svc.cluster.local:5432/statistics?currentSchema=statistics` | Postgres on Wyse, database and schema `statistics` |
| `DB_USER` | `statistics` | Postgres role (step 2) |
| `ADMIN_EMAIL` | `admin@home.arpa` | e-mail of the first admin. Created only when the database has no users. |
| `AUTH_LOCAL` | `true` | password login; `false` = OIDC only |
| `OIDC_ISSUER` | empty | OIDC provider URL (e.g. Authelia). SSO works when `OIDC_ISSUER` and `OIDC_CLIENT_ID` are set. |
| `OIDC_CLIENT_ID` | empty | client registered with the provider (PKCE, redirect `http://statistics.home.arpa/`) |
| `OIDC_NAME` | `SSO` | label on the "Sign in with …" button |
| `CORS_HOSTS` | `statistics.home.arpa` | frontend host |
| `TRUST_PROXY` | `true` | login rate limit counted by `X-Forwarded-For` from the gateway |
| `LOG_FORMAT` | `json` | JSON logs on stdout |
| `BROKER` | `none` | ingest queue: `none`, `jetstream` (NATS in this cluster) or `kafka` |
| `NATS_*` | preset | address, stream, subject, consumer, limits and user of NATS, used with `BROKER=jetstream` ([nats.md](nats.md)) |
| `KAFKA_*` | preset | used only with `BROKER=kafka`. This cluster has no Kafka. |

A change in `values.env` pushed to `main` upgrades the HelmRelease: new ConfigMap and a rollout.

statistics-ui has no environment variables. It is a static frontend, and the gateway routes `/api/` to the service.

### Vault keys

| Vault path | Key | Value |
| --- | --- | --- |
| `secret/apps/statistics-service` | `DB_PASSWORD` | password of the `statistics` role (step 2) |
| | `ADMIN_PASSWORD` | password of the `ADMIN_EMAIL` admin. Empty = no local admin (the first OIDC login with this e-mail becomes admin). |
| | `OIDC_CLIENT_SECRET` | OIDC client secret. Empty without SSO or for a public client. |
| | `NATS_PASSWORD` | only with `BROKER=jetstream` ([nats.md](nats.md)) |
| `secret/apps/nats` | `STATS_SERVICE_PASSWORD`, `COLLECTOR_PASSWORD` | NATS user passwords. Required: NATS is always deployed. |
| `secret/apps/mon-home-ass` | `DB_PASSWORD` | password of the `mon_home_ass` role (step 2) |

## 2. Postgres on Wyse

Follow [postgres.md](postgres.md):

1. "Once: Postgres on Wyse": `listen_addresses`, `pg_hba.conf`, the `statistics` database.
2. "Each application" with `<app>` = `statistics`.
3. "Home Assistant database (mon-home-ass)".

Keep each role password in the password manager. They go to Vault in step 7.

## 3. GitHub: repos and images

1. homelab-infra is on GitHub, and your changes are pushed to `main`. Flux reads `clusters/home` from `main`.
2. In statistics-service, statistics-ui and mon-home-ass, open `.devops/helm/release.yaml` on `main`. The `image:` tag must be one that CI built and pushed to GHCR (GitHub → repo → Packages). A placeholder such as `main-00000000000000-0000000` means CI has not deployed yet: run the build workflow on `main`.
3. CI pushes the tag commit to `main`. If `main` is protected by a ruleset, add GitHub Actions to the ruleset's bypass list. Otherwise the Deploy step fails (this happened in statistics-service).
4. Make the GHCR packages `statistics-service`, `statistics-ui` and `mon-home-ass` public: GitHub → Packages → package → Package settings → Change visibility → Public. The cluster pulls images without logging in. A package appears only after its first successful CI build. Packages of a private repo (mon-home-ass) are private by default, but you can still make them public.

## 4. k3s

```bash
cd <homelab-infra checkout>
set -a; . ./.env; set +a
cd terraform/k3s
terraform init
terraform apply
export KUBECONFIG=<homelab-infra checkout>/terraform/kubeconfig
kubectl get nodes -L homelab/node
```

`terraform apply` installs the k3s server on the RPi5 and joins the Wyse as an agent. It writes the cluster credentials to `terraform/kubeconfig`. Keep the `KUBECONFIG` export in this shell: all later steps and the other docs need it. Both nodes must be `Ready`.

## 5. Flux

In the same shell (`.env` is loaded):

```bash
cd ../flux
terraform init
terraform apply
cd ../..
git pull
```

`terraform apply` installs Flux and creates ConfigMap `flux-system/cluster-vars`. The bootstrap commits `clusters/home/flux-system` to `main` on GitHub. `git pull` brings that commit into your checkout, so your next push does not conflict.

Flux then deploys the rest on its own: Gateway API, Istio, `home-gateway`, the `apps` namespace, the `postgres` Service, Vault + External Secrets Operator, Kiali, NATS, statistics-service, statistics-ui and mon-home-ass.

Wait until `infrastructure` shows `Ready True` (first run: a few minutes; Ctrl+C to stop watching):

```bash
flux get kustomizations --watch
kubectl -n vault get pod vault-0
```

`vault-0` must be `Running`. It shows `Ready` even while it is sealed. This is on purpose, so `infrastructure` can finish before Vault is set up.

NATS, statistics-service and mon-home-ass wait in `CreateContainerConfigError` until their secrets exist (step 7). Their HelmReleases keep retrying, so nothing needs a manual kick afterwards.

## 6. Vault: init, unseal, configuration

[vault.md](vault.md), steps 1–3.

## 7. App secrets in Vault

Use the same shell as step 6 (port-forward, `VAULT_ADDR`, `vault login`). In a new shell, repeat those three lines from [vault.md](vault.md), step 3. Each `KEY=-` reads the value from stdin: type it, then press Ctrl+D twice. Do not press Enter, it would become part of the value. The value stays out of shell history.

```bash
vault kv put secret/apps/statistics-service DB_PASSWORD=-
vault kv patch secret/apps/statistics-service ADMIN_PASSWORD=-
vault kv patch secret/apps/statistics-service OIDC_CLIENT_SECRET=""
vault kv put secret/apps/nats STATS_SERVICE_PASSWORD=$(openssl rand -hex 24) COLLECTOR_PASSWORD=$(openssl rand -hex 24)
vault kv put secret/apps/mon-home-ass DB_PASSWORD=-
```

`DB_PASSWORD` values are the role passwords from step 2. `kv put` creates the path; `kv patch` adds a key to an existing path. Details: [vault.md](vault.md), step 4.

External Secrets Operator retries on its own. To sync right away:

```bash
kubectl -n apps annotate externalsecret --all force-sync=$(date +%s) --overwrite
```

The pods start once their Secrets exist. The HelmReleases turn `Ready` within about 10 minutes (`flux get helmreleases -n apps`).

## 8. Verification

| Command | Expected |
| --- | --- |
| `kubectl get nodes -L homelab/node` | two nodes `Ready`, labels `rpi` and `wyse` |
| `flux get kustomizations` | `flux-system`, `infrastructure`, `apps`, `statistics-service`, `statistics-ui`, `mon-home-ass`: `Ready True` |
| `flux get helmreleases -A` | all `Ready True` |
| `kubectl -n apps get externalsecret` | `statistics-service-secrets`, `nats-auth`, `mon-home-ass-secrets`: `SecretSynced`, READY `True` |
| `kubectl -n apps get pods` | `statistics-service-…`, `statistics-ui-…`, `mon-home-ass-…`, `nats-0`: `Running`, all containers ready |
| `curl -sI http://statistics.home.arpa/` | `HTTP/1.1 200 OK` from statistics-ui |

Database access from the cluster. It asks for the `statistics` role password and must print `statistics`:

```bash
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://statistics@postgres.apps.svc.cluster.local:5432/statistics" -c 'show search_path'
```

## 9. Log in

Open `http://statistics.home.arpa/` in a browser. Log in with `ADMIN_EMAIL` from statistics-service's `.devops/helm/release.yaml` (`admin@home.arpa`) and `ADMIN_PASSWORD` from Vault:

```bash
vault kv get -field=ADMIN_PASSWORD secret/apps/statistics-service
```

## mon-home-ass

mon-home-ass reads Home Assistant data from Postgres. Its repo is private. Checklist, all covered by the steps above:

- [ ] PAT with Contents read on `mon-home-ass` (step 1). Its GitRepository uses `secretRef: flux-system`, the PAT stored by the bootstrap.
- [ ] Home Assistant writes to the `home_assistant` database; role `mon_home_ass` and `pg_hba.conf` lines ([postgres.md](postgres.md#home-assistant-database-mon-home-ass), step 2)
- [ ] Image tag built by CI, GHCR package public (step 3)
- [ ] `DB_PASSWORD` in Vault `secret/apps/mon-home-ass` (step 7)

Details: [mon-home-ass `.devops/README.md`](https://github.com/jagieloadrian/mon-home-ass/blob/main/.devops/README.md). URL: `http://mon-home-ass.home.arpa/`.

## Operations

| When | What to do |
| --- | --- |
| CI bumped an image tag and you want it live now | Flux checks app repos once a day. Run `flux reconcile kustomization <app> -n flux-system --with-source` (`<app>` = statistics-service, statistics-ui or mon-home-ass). |
| After every RPi5 reboot or `vault-0` restart | Vault is sealed. Check with `kubectl -n vault exec vault-0 -- vault status` (`Sealed true`), then unseal ([vault.md](vault.md), step 2). |
| GitHub PAT expires | Create a new PAT with the same access (step 1). Replace the copy Flux uses: `flux create secret git flux-system -n flux-system --url=https://github.com/jagieloadrian/homelab-infra --username=git --password=<new PAT>` (it updates the existing Secret). Put the same token in `.env` (`TF_VAR_github_token`) for later Terraform runs. |
| Vault data lost | Restore the PVC directory and unseal ([vault.md](vault.md), "Backup and restore"). |
| Postgres backup | [postgres.md](postgres.md), "Backup" |

Back up, outside the homelab:

- `.env`
- Vault unseal key and root token
- `terraform/k3s/terraform.tfstate` and `terraform/flux/terraform.tfstate`. The k3s state holds the k3s join token.

## Troubleshooting

| Symptom | Cause / where to look |
| --- | --- |
| `infrastructure` not Ready | `kubectl -n flux-system describe kustomization infrastructure`. Missing ConfigMap `cluster-vars` → step 5. |
| `ExternalSecret` not `SecretSynced` | [vault.md](vault.md), "Check": Vault sealed after a restart, key missing |
| Pod `ImagePullBackOff` | GHCR package private, or the tag in `release.yaml` was never built (step 3) |
| statistics-service keeps restarting, readiness 503 | no connection to Postgres: `pg_hba.conf`, `listen_addresses`, firewall, password (steps 2 and 7) |
| `statistics.home.arpa` not responding | DNS wildcard → RPi5 IP (step 0); `kubectl -n istio-ingress get gateway home-gateway` |
| CI Deploy step fails on `git push` | protected `main` without a bypass for GitHub Actions (step 3) |
