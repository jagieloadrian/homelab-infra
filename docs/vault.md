# Vault: application secrets

Secrets live only in Vault. Git holds `ExternalSecret`s (which Vault key to read), never values, not even encrypted. App CI needs no keys.

External Secrets Operator (ESO) copies Vault `secret/apps/<app>` (KV v2) into Secret `<app>-secrets` in namespace `apps`, and the pod gets it via `envFrom`.

| What | Where |
| --- | --- |
| Vault (standalone, file storage on a `local-path` PVC on the RPi5) + ESO | `infrastructure/vault.yaml` |
| SecretStore `vault` (namespace `apps`, read-only role `apps`) | `apps/secret-store.yaml` |
| ExternalSecret of an own app | chart `charts/app`, value `secrets: true` |
| ExternalSecret of NATS (`nats-auth`) | `apps/nats/release.yaml` |

Locally: the `vault` CLI (or run the same commands inside `kubectl -n vault exec -it vault-0 -- sh`), and `KUBECONFIG` set to `<homelab-infra checkout>/terraform/kubeconfig`.

## 1. Init (once)

Start when `kubectl -n vault get pod vault-0` shows `Running` ([setup.md](setup.md), step 5). The pod shows `Ready` even while sealed, on purpose.

```bash
kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=1 -key-threshold=1
```

It prints `Unseal Key 1` and `Initial Root Token`. Put both in a password manager. Without the unseal key, every secret is lost.

## 2. Unseal (after init and after every restart of the Vault pod)

```bash
kubectl -n vault exec -it vault-0 -- vault operator unseal
kubectl -n vault exec vault-0 -- vault status
```

Paste `Unseal Key 1` at the prompt. `vault status` must show `Sealed false`.

While Vault is sealed, the Secrets already in the cluster keep working. ESO just can't create or refresh them.

## 3. Configuration (once)

```bash
kubectl -n vault port-forward svc/vault 8200 &
export VAULT_ADDR=http://127.0.0.1:8200
vault login

vault secrets enable -path=secret kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
vault policy write apps-read - <<'EOF'
path "secret/data/apps/*" { capabilities = ["read"] }
EOF
vault write auth/kubernetes/role/apps \
  bound_service_account_names=vault-reader \
  bound_service_account_namespaces=apps \
  policies=apps-read ttl=1h
```

The port-forward runs in the background. The Vault UI is at `http://localhost:8200/ui`. `vault login` asks for the `Initial Root Token` from step 1.

ESO logs in with a token of ServiceAccount `apps/vault-reader` and can only read `secret/apps/*`.

## 4. Secrets per application

The key names are the env variable names. Generate passwords with `openssl rand -hex 24` (no `/`, `+`, `=` that break NATS config or DB URLs).

| Vault path | Keys |
| --- | --- |
| `secret/apps/statistics-service` | `DB_PASSWORD`, `ADMIN_PASSWORD`, `OIDC_CLIENT_SECRET` (may be empty), `NATS_PASSWORD` (`BROKER=jetstream`) |
| `secret/apps/mon-home-ass` | `DB_PASSWORD` |
| `secret/apps/nats` | `STATS_SERVICE_PASSWORD` (= `NATS_PASSWORD` of statistics-service), `COLLECTOR_PASSWORD` |

Commands for the first setup: [setup.md](setup.md), step 7. Examples:

```bash
vault kv put secret/apps/mon-home-ass DB_PASSWORD=-
vault kv patch secret/apps/statistics-service ADMIN_PASSWORD=-
vault kv get secret/apps/statistics-service
```

- `KEY=-` reads the value from stdin. Type it, then press Ctrl+D twice (no Enter, it would become part of the value). The value stays out of shell history.
- `kv put` replaces all keys at the path. Keys you leave out are deleted.
- `kv patch` changes one key and keeps the rest. The path must already exist (`kv put` first).

With several keys, the UI is easier (`secret/` → `apps/<app>` → JSON).

`DB_PASSWORD` must match the Postgres user's password ([postgres.md](postgres.md)), and NATS passwords must match each other ([nats.md](nats.md)).

## Change takes effect

ESO refreshes every hour, and the app reads env only at start. The annotation forces ESO to sync now; the restart makes the app read the new Secret:

```bash
kubectl -n apps annotate externalsecret <app>-secrets force-sync=$(date +%s) --overwrite
kubectl -n apps rollout restart deploy/<app>
```

For NATS: ExternalSecret `nats-auth`, restart `statefulset/nats`.

## Check

```bash
kubectl -n apps get externalsecret
```

Every ExternalSecret must show STATUS `SecretSynced` and READY `True`.

`SecretSyncedError`: Vault is sealed (step 2), the key does not exist in Vault (step 4) or the role is missing (step 3). The details are in `kubectl -n apps describe externalsecret <app>-secrets`.

## Backup and restore

The Vault data (already encrypted by Vault) is the PVC directory on the RPi5: `/var/lib/rancher/k3s/storage/pvc-*_vault_data-vault-0`. Copy it together with the unseal key (stored separately). One without the other is useless.

```bash
ssh rpi 'cd /var/lib/rancher/k3s/storage && sudo tar -czf - *_vault_data-vault-0' > vault-$(date +%F).tgz
```

Restore: stop Vault, replace the contents of the PVC directory with the backup, start Vault, then unseal (step 2) with the unseal key that belongs to this backup. On a new cluster the directory has a new `pvc-*` name; the commands below find it.

```bash
kubectl -n vault scale statefulset vault --replicas 0
ssh rpi 'cd /var/lib/rancher/k3s/storage/pvc-*_vault_data-vault-0 && sudo find . -mindepth 1 -delete && sudo tar -xzf - --strip-components=1' < vault-<date>.tgz
kubectl -n vault scale statefulset vault --replicas 1
```
