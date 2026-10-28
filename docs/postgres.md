# Postgres na Wyse 5070

Aplikacje w k3s korzystają z Postgresa działającego na hoście Wyse, poza klastrem. Jedna baza `statistics`, dla każdej aplikacji osobny użytkownik i schema. W klastrze Postgres jest widoczny jako `postgres.apps.svc.cluster.local:5432`, a IP Wyse jest wpisane tylko w jednym miejscu.

## Raz: Postgres na Wyse

1. `postgresql.conf` (zmiana wymaga restartu Postgresa):
   ```
   listen_addresses = 'localhost,<IP Wyse>'
   ```
2. `pg_hba.conf` (wystarczy `SELECT pg_reload_conf();`):
   ```
   host  statistics  all  10.42.0.0/16    scram-sha-256   # pody (domyślny CIDR k3s), m.in. te z Wyse
   host  statistics  all  <IP RPi5>/32    scram-sha-256   # pody z RPi5 wychodzą z IP noda (masquerade flannela)
   ```
   Postgres w Dockerze: opublikuj port `5432:5432`. Sprawdź w logach (`log_connections = on`), z jakiego IP przychodzą połączenia: przy proxy Dockera bywa to brama sieci Dockera. Firewall na Wyse (np. `ufw`) musi przepuszczać 5432 z tych samych adresów.
3. Baza:
   ```sql
   CREATE DATABASE statistics;
   REVOKE ALL ON DATABASE statistics FROM PUBLIC;
   \c statistics
   REVOKE CREATE ON SCHEMA public FROM PUBLIC;   -- Postgres < 15 pozwala na to domyślnie
   ```
4. RAM: Postgres i Home Assistant zużywają pamięć spoza puli kubeleta. `wyse_system_reserved_memory` w `terraform/k3s` (domyślnie `4Gi`) musi pokryć oba. Więcej rezerwy oznacza mniej niż ok. 3.4 GiB dla podów.

## Adres w klastrze (już w repo)

`infrastructure/postgres.yaml` to Service `postgres` bez selektora i EndpointSlice z adresem `${WYSE_IP}`. Flux podstawia ten adres z ConfigMap `flux-system/cluster-vars`, którą `terraform/flux` tworzy z `TF_VAR_wyse_host` w `.env` ([setup.md](setup.md), krok 1). Zmiana IP to zmiana w `.env` i ponowny `terraform apply` w `terraform/flux`.

Mesh (ambient) przepuszcza ruch do celu spoza meshu jako zwykłe TCP. AuthorizationPolicy go nie obejmuje, a granicą między aplikacjami są użytkownicy Postgresa.

## Każda aplikacja: użytkownik i schema

Nazwy ról i schem bez myślników (np. `statistics`), wtedy nie trzeba ich cytować w SQL.

```bash
openssl rand -hex 24                          # hasło
ssh wyse sudo -u postgres psql -d statistics     # Docker: ssh wyse docker exec -it <kontener> psql -U postgres -d statistics
```

```sql
CREATE ROLE <app> LOGIN PASSWORD '<hasło>';
GRANT CONNECT ON DATABASE statistics TO <app>;
CREATE SCHEMA <app> AUTHORIZATION <app>;
ALTER ROLE <app> IN DATABASE statistics SET search_path = <app>;
```

Schema należy do aplikacji, więc inne role jej nie widzą bez osobnego `GRANT`.

Test z klastra:

```bash
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://<app>@postgres.apps.svc.cluster.local:5432/statistics" -c 'show search_path'
```

## Po stronie aplikacji

- URL: `jdbc:postgresql://postgres.apps.svc.cluster.local:5432/statistics?currentSchema=<app>`.
- Hasło w `.devops/k8s/secrets.sops.env` repo aplikacji (SOPS), nigdy w `config.env` ([setup.md](setup.md), krok 1).
- Flyway bez dodatkowej konfiguracji używa pierwszej schemy z `search_path`, więc migracje i `flyway_schema_history` lądują w schemie aplikacji.

## Backup

Backup robisz na hoście Wyse, poza klastrem. Kontrakt wymaga, żeby był opisany. Przykład `/etc/cron.d/postgres-backup`:

```
0 3 * * * postgres pg_dump -d statistics -Fc -f /srv/backup/postgres/statistics-$(date +\%F).dump && find /srv/backup/postgres -name '*.dump' -mtime +14 -delete
```

Pojedyncza aplikacja: `pg_dump -n <app>`. Kopię trzeba wynieść poza Wyse (RPi5, NAS, chmura), bo inaczej padnięcie dysku zabiera bazę razem z backupem.
