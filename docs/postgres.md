# Postgres on Wyse 5070

Applications in k3s use Postgres running on the Wyse host, outside the cluster. Own apps share the `statistics` database, with a separate user and schema each. mon-home-ass reads Home Assistant's `home_assistant` database. In the cluster Postgres is visible as `postgres.apps.svc.cluster.local:5432`, and the Wyse IP is set in only one place.

## Once: Postgres on Wyse

1. `postgresql.conf` (a change requires a Postgres restart):
   ```
   listen_addresses = 'localhost,<Wyse IP>'
   ```
2. `pg_hba.conf` (`SELECT pg_reload_conf();` is enough):
   ```
   host  statistics  all  10.42.0.0/16    scram-sha-256
   host  statistics  all  <RPi5 IP>/32    scram-sha-256
   ```
   | Source | Why |
   | --- | --- |
   | `10.42.0.0/16` | pod IPs (default k3s pod CIDR), including pods on the Wyse |
   | `<RPi5 IP>/32` | pods on the RPi5 leave the node with the RPi5 IP (flannel masquerade) |

   Postgres in Docker: publish port `5432:5432`. Check in the logs (`log_connections = on`) which IP the connections come from: with the Docker proxy it is sometimes the Docker network gateway. The firewall on Wyse (e.g. `ufw`) must allow 5432 from the same addresses.
3. Database. Open psql as the `postgres` superuser:
   ```bash
   ssh -t wyse sudo -u postgres psql
   ```
   Postgres in Docker: `ssh -t wyse docker exec -it <container> psql -U postgres`. Then run:
   ```sql
   CREATE DATABASE statistics;
   REVOKE ALL ON DATABASE statistics FROM PUBLIC;
   \c statistics
   REVOKE CREATE ON SCHEMA public FROM PUBLIC;
   ```
   The last line matters for Postgres < 15, which lets every role create objects in `public` by default.
4. RAM: Postgres and Home Assistant use memory outside the kubelet pool. `wyse_system_reserved_memory` in `terraform/k3s` (default `4Gi`) must cover both. More reserve means less than approx. 3.4 GiB for pods.

## Address in the cluster (already in the repo)

`infrastructure/postgres.yaml` is a Service `postgres` without a selector and an EndpointSlice with address `${WYSE_IP}`. Flux substitutes this address from ConfigMap `flux-system/cluster-vars`, which `terraform/flux` creates from `TF_VAR_wyse_host` in `.env` ([setup.md](setup.md), step 1). Changing the IP means changing `.env` and re-running `terraform apply` in `terraform/flux`.

The mesh (ambient) passes traffic to a destination outside the mesh as plain TCP. AuthorizationPolicy does not cover it, and the boundary between applications is the Postgres users.

## Each application: user and schema

Role and schema names without hyphens (e.g. `statistics`), so they do not need quoting in SQL.

Generate the role password. The output is the password: keep it for `CREATE ROLE` and for Vault (`DB_PASSWORD`).

```bash
openssl rand -hex 24
```

Open psql in the `statistics` database:

```bash
ssh -t wyse sudo -u postgres psql -d statistics
```

Postgres in Docker: `ssh -t wyse docker exec -it <container> psql -U postgres -d statistics`. Then run, with `<app>` and `<password>` filled in:

```sql
CREATE ROLE <app> LOGIN PASSWORD '<password>';
GRANT CONNECT ON DATABASE statistics TO <app>;
CREATE SCHEMA <app> AUTHORIZATION <app>;
ALTER ROLE <app> IN DATABASE statistics SET search_path = <app>;
```

The schema belongs to the application, so other roles cannot see it without a separate `GRANT`.

Test from the cluster:

```bash
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://<app>@postgres.apps.svc.cluster.local:5432/statistics" -c 'show search_path'
```

## Application side

- URL: `jdbc:postgresql://postgres.apps.svc.cluster.local:5432/statistics?currentSchema=<app>`.
- Password (the one from `CREATE ROLE`) in Vault `secret/apps/<application>` as `DB_PASSWORD`, e.g. `secret/apps/statistics-service` ([vault.md](vault.md)), never in `values.env` in `release.yaml`.
- Flyway without extra configuration uses the first schema from `search_path`, so migrations and `flyway_schema_history` land in the application's schema.

## Home Assistant database (mon-home-ass)

mon-home-ass reads the Home Assistant recorder data. Home Assistant must write its recorder to the `home_assistant` database in this Postgres (`recorder:` → `db_url` in Home Assistant's `configuration.yaml`), not to its default SQLite file.

The read-only role `mon_home_ass` and its grants: [mon-home-ass `.devops/README.md`](https://github.com/jagieloadrian/mon-home-ass/blob/main/.devops/README.md). Put its password in Vault `secret/apps/mon-home-ass` as `DB_PASSWORD`.

`pg_hba.conf` needs two more lines, from the same two sources as above, then `SELECT pg_reload_conf();`:

```
host  home_assistant  mon_home_ass  10.42.0.0/16    scram-sha-256
host  home_assistant  mon_home_ass  <RPi5 IP>/32    scram-sha-256
```

## Backup

You make the backup on the Wyse host, outside the cluster. Example `/etc/cron.d/postgres-backup`:

```
0 3 * * * postgres pg_dump -d statistics -Fc -f /srv/backup/postgres/statistics-$(date +\%F).dump && find /srv/backup/postgres -name '*.dump' -mtime +14 -delete
```

Single application: `pg_dump -n <app>`. The copy has to be moved off Wyse (RPi5, NAS, cloud), otherwise a disk failure takes the database together with the backup.
