# Postgres na Wyse 5070

Aplikacje w k3s korzystają z Postgresa działającego na hoście Wyse, poza klastrem. Jedna baza `homelab`, dla każdej aplikacji osobny użytkownik i schema. W klastrze Postgres jest widoczny jako `postgres.apps.svc.cluster.local:5432`, a IP Wyse jest wpisane tylko w jednym miejscu.

> Nazwa bazy `homelab` jest przykładowa. Jeśli wybierzesz inną, podmień ją we wszystkich krokach.

## Raz: Postgres na Wyse

1. `postgresql.conf` (zmiana wymaga restartu Postgresa):
   ```
   listen_addresses = 'localhost,<IP Wyse>'
   ```
2. `pg_hba.conf` (wystarczy `SELECT pg_reload_conf();`):
   ```
   host  homelab  all  10.42.0.0/16    scram-sha-256   # pody (domyślny CIDR k3s), m.in. te z Wyse
   host  homelab  all  <IP RPi5>/32    scram-sha-256   # pody z RPi5 wychodzą z IP noda (masquerade flannela)
   ```
   Postgres w Dockerze: opublikuj port `5432:5432`. Sprawdź w logach (`log_connections = on`), z jakiego IP przychodzą połączenia: przy proxy Dockera bywa to brama sieci Dockera. Firewall na Wyse (np. `ufw`) musi przepuszczać 5432 z tych samych adresów.
3. Baza:
   ```sql
   CREATE DATABASE homelab;
   REVOKE ALL ON DATABASE homelab FROM PUBLIC;
   \c homelab
   REVOKE CREATE ON SCHEMA public FROM PUBLIC;   -- Postgres < 15 pozwala na to domyślnie
   ```
4. RAM: Postgres i Home Assistant zużywają pamięć spoza puli kubeleta. `wyse_system_reserved_memory` w `terraform/k3s` (domyślnie `4Gi`) musi pokryć oba. Więcej rezerwy oznacza mniej niż ok. 3.4 GiB dla podów.

## Raz: adres w klastrze

Plik `infrastructure/postgres.yaml`, dopisany do `resources` w `infrastructure/kustomization.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: apps
spec:
  ports:
    - name: tcp-postgres
      port: 5432
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: postgres-wyse
  namespace: apps
  labels:
    kubernetes.io/service-name: postgres
addressType: IPv4
ports:
  - name: tcp-postgres # musi się zgadzać z nazwą portu w Service
    port: 5432
endpoints:
  - addresses: ["<IP Wyse>"]
```

Service nie ma selektora, więc ruch idzie na adres z EndpointSlice. Mesh (ambient) przepuszcza ruch do celu spoza meshu jako zwykłe TCP. AuthorizationPolicy go nie obejmuje, a granicą między aplikacjami są użytkownicy Postgresa.

## Każda aplikacja: użytkownik i schema

Nazwy ról i schem bez myślników (np. `statistics`), wtedy nie trzeba ich cytować w SQL.

```bash
openssl rand -hex 24                          # hasło
ssh wyse sudo -u postgres psql -d homelab     # Docker: ssh wyse docker exec -it <kontener> psql -U postgres -d homelab
```

```sql
CREATE ROLE <app> LOGIN PASSWORD '<hasło>';
GRANT CONNECT ON DATABASE homelab TO <app>;
CREATE SCHEMA <app> AUTHORIZATION <app>;
ALTER ROLE <app> IN DATABASE homelab SET search_path = <app>;
```

Schema należy do aplikacji, więc inne role jej nie widzą bez osobnego `GRANT`.

Test z klastra:

```bash
kubectl -n apps run psql --rm -it --restart=Never --image=postgres:16 -- \
  psql "postgresql://<app>@postgres.apps.svc.cluster.local:5432/homelab" -c 'show search_path'
```

## Po stronie aplikacji

- URL: `jdbc:postgresql://postgres.apps.svc.cluster.local:5432/homelab?currentSchema=<app>`.
- Hasło w Secret zaszyfrowanym SOPS w `.devops/` repo aplikacji (README: „Własna aplikacja”), nigdy w ConfigMap.
- Flyway bez dodatkowej konfiguracji używa pierwszej schemy z `search_path`, więc migracje i `flyway_schema_history` lądują w schemie aplikacji.

## Backup

Backup robisz na hoście Wyse, poza klastrem. Kontrakt wymaga, żeby był opisany. Przykład `/etc/cron.d/postgres-backup`:

```
0 3 * * * postgres pg_dump -d homelab -Fc -f /srv/backup/postgres/homelab-$(date +\%F).dump && find /srv/backup/postgres -name '*.dump' -mtime +14 -delete
```

Pojedyncza aplikacja: `pg_dump -n <app>`. Kopię trzeba wynieść poza Wyse (RPi5, NAS, chmura), bo inaczej padnięcie dysku zabiera bazę razem z backupem.
