# NATS z JetStream: kolejka ingestu

Kolejka dla pub/sub ingestu statistics-service (`BROKER=jetstream`). Gotowa aplikacja z Helm charta: `apps/nats/release.yaml`. Dostępna tylko w klastrze.

| | |
| --- | --- |
| Chart | `nats` `2.15.x` z `https://nats-io.github.io/k8s/helm/charts/`, obraz `nats:<wersja charta>-alpine` (multi-arch) |
| Pod | StatefulSet `nats`, 1 replika, bez klastra NATS, RPi5 (`homelab/node=rpi`). Przy 1 replice aktualizacja działa jak `Recreate` |
| Adres | `nats://nats.apps.svc.cluster.local:4222`: Service `nats`, `appProtocol: tcp`, bez HTTPRoute (to nie HTTP) |
| JetStream | file store na PVC `nats-js-nats-0` (`local-path`, 2 Gi), limit `max_file_store` 1 GiB; memory store 32 MiB |
| Monitoring | `:8222` tylko w headless Service `nats-headless`; AuthorizationPolicy go nie przepuszcza, probes kubeleta omijają ztunnel |
| Uruchomienie | UID 10001, read-only root FS, `drop: [ALL]`, `seccompProfile: RuntimeDefault`, ServiceAccount `nats` bez tokenu |
| RAM | 256 Mi (request = limit), `GOMEMLIMIT=200MiB`, bez sidecara reloadera. W spoczynku kilka MiB; więcej przy zaległościach w kolejce (cache bloków file store) |
| Sekrety | Secret `nats-auth` z `apps/nats/secret.sops.yaml` (hasła jako zmienne środowiskowe w `nats.conf`) |

Stream `STATS_INGEST` (subjects `stats.ingest.>`, file storage) i durable pull consumer `statistics-service` tworzy sama aplikacja przy starcie. Kontroler JetStream (NACK) nie jest potrzebny.

Zmiana `values` w `release.yaml` = nowy ConfigMap i restart poda (adnotacja z checksumą konfigu, zamiast hot reloadu przez sidecar).

## Użytkownicy

| Użytkownik | Publish | Subscribe | Kto |
| --- | --- | --- | --- |
| `statistics-service` | `$JS.API.>`, `$JS.ACK.>`, `_INBOX.>` | `stats.ingest.>`, `_INBOX.>` | statistics-service: zarządza streamem i konsumuje |
| `collector` | `stats.ingest.>` | `_INBOX_collector.>` | aplikacje zbierające dane (producenci) |

Bez hasła serwer odpowiada `Authorization Violation`, użytkownika anonimowego nie ma.

Collector publikuje na `stats.ingest.<sourceId>` z nagłówkiem `Authorization: Bearer <token źródła>`. Zwykły publish (bez potwierdzenia) nie potrzebuje żadnej subskrypcji. Publish z potwierdzeniem JetStream wymaga w kliencie prefiksu inboxa `_INBOX_collector` (opcja „custom inbox prefix” bibliotek NATS, w CLI `--inbox-prefix _INBOX_collector`). Domyślny `_INBOX.>` jest dla collectora zablokowany, bo przez niego widziałby wiadomości (razem z tokenami źródeł) dostarczane do statistics-service.

Kolejne collectory mogą dzielić użytkownika `collector`, bo źródło i tak identyfikuje token w nagłówku. Osobny użytkownik: wpis w `config.merge.authorization.users` w `release.yaml` + hasło w `nats-auth`.

Sieć (AuthorizationPolicy `nats`): port 4222 tylko z `cluster.local/ns/apps/sa/statistics-service`. Collector działający w klastrze dopisz jako `cluster.local/ns/apps/sa/<collector>` w miejscu oznaczonym komentarzem w `release.yaml`.

## Sekrety (raz, przed pierwszym wdrożeniem)

Wymaga klucza age w `.sops.yaml` ([setup.md](setup.md), krok 2).

```bash
cd ~/IdeaProjects/homelab-infra
cat > apps/nats/secret.sops.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nats-auth
stringData:
  STATS_SERVICE_PASSWORD: $(openssl rand -hex 24)
  COLLECTOR_PASSWORD: $(openssl rand -hex 24)
EOF
sops -e -i apps/nats/secret.sops.yaml
grep -q '^sops:' apps/nats/secret.sops.yaml && git add apps/nats/secret.sops.yaml
```

NATS wczytuje zmienną środowiskową jak wartość w konfigu, więc hasło nie może być samą liczbą (np. `12345` → błąd startu). Hex z `openssl` ma litery.

Odczyt haseł:

```bash
sops -d apps/nats/secret.sops.yaml
sops -d --extract '["stringData"]["STATS_SERVICE_PASSWORD"]' apps/nats/secret.sops.yaml
```

Zmiana hasła: `sops apps/nats/secret.sops.yaml`, push, potem `kubectl -n apps rollout restart statefulset/nats` (zmiana Secret sama nie restartuje poda) i nowe hasło w aplikacji.

Bez Secret pod `nats-0` stoi w `CreateContainerConfigError`, a HelmRelease `nats` po 5 min kończy się błędem. Po dodaniu Secret: `flux reconcile helmrelease nats -n apps --force`.

## statistics-service

`StatisticsService/.devops/k8s/config.env`:

```bash
BROKER=jetstream
NATS_URL=nats://nats.apps.svc.cluster.local:4222
```

`StatisticsService/.devops/k8s/secrets.sops.env` (`sops .devops/k8s/secrets.sops.env`):

```bash
NATS_USER=statistics-service
NATS_PASSWORD=<STATS_SERVICE_PASSWORD z apps/nats/secret.sops.yaml>
```

## Test

```bash
export KUBECONFIG=~/IdeaProjects/homelab-infra/terraform/kubeconfig
kubectl -n apps get pods,pvc -l app.kubernetes.io/name=nats
kubectl -n apps port-forward svc/nats 4222      # port-forward omija ztunnel i AuthorizationPolicy
```

W drugim terminalu (CLI `nats`; bez instalacji: `docker run --rm -it --network host natsio/nats-box nats ...`):

```bash
export NATS_URL=nats://localhost:4222
COLLECTOR_PASSWORD=$(sops -d --extract '["stringData"]["COLLECTOR_PASSWORD"]' apps/nats/secret.sops.yaml)
STATS_PASSWORD=$(sops -d --extract '["stringData"]["STATS_SERVICE_PASSWORD"]' apps/nats/secret.sops.yaml)

nats --user collector --password "$COLLECTOR_PASSWORD" \
  pub stats.ingest.<sourceId> --header "Authorization: Bearer <token źródła>" '<json>'
nats --user statistics-service --password "$STATS_PASSWORD" stream info STATS_INGEST
nats pub stats.ingest.x x                       # bez hasła: Authorization Violation
```

Nie pobieraj wiadomości z consumera `statistics-service` ręcznie (`nats consumer next`), bo zabierzesz je aplikacji. Czy dotarły, widać po `stream info` (liczniki) i w logach statistics-service.

## Backup

Kolejka jest buforem: wiadomości trafiają do Postgresa, a stream ma limit wieku i rozmiaru (domyślnie 7 dni, 256 MiB, ustawia aplikacja). Utrata PVC to utrata tylko nieprzetworzonych wiadomości, stream i consumer aplikacja odtworzy przy starcie. Kopia (np. przed wymianą karty/dysku RPi5), z krótką przerwą w przyjmowaniu wiadomości:

```bash
kubectl -n apps scale statefulset nats --replicas 0
ssh rpi 'cd /var/lib/rancher/k3s/storage && sudo tar -czf - *_apps_nats-js-nats-0' > nats-js-$(date +%F).tgz
kubectl -n apps scale statefulset nats --replicas 1
```

Przywracanie: to samo w drugą stronę (`replicas 0`, rozpakuj do katalogu PVC, `replicas 1`). `nats stream backup`/`restore` odpada: restore publikuje na `$JS.SNAPSHOT.>`, czego `statistics-service` nie może, a osobnego admina celowo nie ma.

## Wystawienie w LAN (niewdrożone)

Domyślnie NATS nie wychodzi poza klaster. Gdy collector ma działać na urządzeniu w LAN:

1. W `apps/nats/` dodatkowy Service `nats-lan` typu `LoadBalancer` (selector `app.kubernetes.io/instance: nats`, port 4222 → `targetPort: nats`). ServiceLB k3s wystawi go na IP RPi5: `nats://<IP RPi5>:4222`.
2. W AuthorizationPolicy `nats` druga reguła `from.source.ipBlocks` z portem 4222. Ruch z LAN nie ma tożsamości mesha, a ServiceLB robi DNAT + masquerade w podzie `svclb`, więc NATS widzi adres tego poda, nie urządzenia. Właściwy adres sprawdź w logach ztunnela (`kubectl -n istio-system logs ds/ztunnel | grep nats`), w praktyce to CIDR podów (`10.42.0.0/16`).
3. Granicą zostaje użytkownik i hasło NATS, a te idą po LAN otwartym tekstem. Przed wystawieniem włącz TLS (`config.nats.tls` w values) albo daj urządzeniom osobnych użytkowników z wąskimi uprawnieniami.
