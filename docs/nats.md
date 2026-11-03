# NATS with JetStream: ingest queue

Queue for statistics-service ingest pub/sub (`BROKER=jetstream`). Ready-made application from a Helm chart: `apps/nats/release.yaml`. Flux always deploys it, so its Vault keys are required. Available only inside the cluster.

| | |
| --- | --- |
| Chart | `nats` `2.15.x` from `https://nats-io.github.io/k8s/helm/charts/`, image `nats:<chart version>-alpine` (multi-arch) |
| Pod | StatefulSet `nats`, 1 replica, no NATS cluster, RPi5 (`homelab/node=rpi`). With 1 replica an update behaves like `Recreate` |
| Address | `nats://nats.apps.svc.cluster.local:4222`: Service `nats`, `appProtocol: tcp`, no HTTPRoute (it is not HTTP) |
| JetStream | file store on PVC `nats-js-nats-0` (`local-path`, 2 Gi), `max_file_store` limit 1 GiB; memory store 32 MiB |
| Monitoring | `:8222` only in headless Service `nats-headless`; AuthorizationPolicy does not allow it, kubelet probes bypass ztunnel |
| Runtime | UID 10001, read-only root FS, `drop: [ALL]`, `seccompProfile: RuntimeDefault`, ServiceAccount `nats` without a token |
| RAM | 256 Mi (request = limit), `GOMEMLIMIT=200MiB`, no reloader sidecar. A few MiB at idle; more with a queue backlog (file store block cache) |
| Secrets | Secret `nats-auth` from Vault `secret/apps/nats` via ExternalSecret `nats-auth` (passwords as environment variables in `nats.conf`) |

The `STATS_INGEST` stream (subjects `stats.ingest.>`, file storage) and the durable pull consumer `statistics-service` are created by the application itself at startup. The JetStream controller (NACK) is not needed.

Changing `values` in `release.yaml` = new ConfigMap and pod restart (config checksum annotation, instead of hot reload via a sidecar).

## Users

| User | Publish | Subscribe | Who |
| --- | --- | --- | --- |
| `statistics-service` | `$JS.API.>`, `$JS.ACK.>`, `_INBOX.>` | `stats.ingest.>`, `_INBOX.>` | statistics-service: manages the stream and consumes |
| `collector` | `stats.ingest.>` | `_INBOX_collector.>` | data-collecting applications (producers) |
| `mon-home-ass` | `stats.ingest.home-assistant` | `_INBOX_mon_home_ass.>` | mon-home-ass: Home Assistant statistics for the source `home-assistant` |

Without a password the server responds `Authorization Violation`; there is no anonymous user.

A collector publishes to `stats.ingest.<sourceId>` with the header `Authorization: Bearer <source token>`. A plain publish (without acknowledgement) needs no subscription. A publish with JetStream acknowledgement requires the inbox prefix `_INBOX_collector` in the client (the "custom inbox prefix" option of NATS libraries, in the CLI `--inbox-prefix _INBOX_collector`). The default `_INBOX.>` is blocked for the collector, because through it the collector would see messages (including source tokens) delivered to statistics-service.

Further collectors can share the `collector` user, because the source is identified by the token in the header anyway. A separate user, like `mon-home-ass`, limits the app to its own subject: an entry in `config.merge.authorization.users` in `release.yaml` + a password in `secret/apps/nats`.

Network (AuthorizationPolicy `nats`): port 4222 only from `cluster.local/ns/apps/sa/statistics-service` and `cluster.local/ns/apps/sa/mon-home-ass`. For another collector running in the cluster, add `cluster.local/ns/apps/sa/<collector>` under `rules[0].from[0].source.principals` of AuthorizationPolicy `nats` in `apps/nats/release.yaml`.

## Secrets (once)

Requires a configured Vault ([vault.md](vault.md), steps 1–3; [setup.md](setup.md), steps 6–7).

```bash
vault kv put secret/apps/nats \
  STATS_SERVICE_PASSWORD=$(openssl rand -hex 24) \
  COLLECTOR_PASSWORD=$(openssl rand -hex 24) \
  MON_HOME_ASS_PASSWORD=$(openssl rand -hex 24)
```

NATS reads an environment variable like a value in the config, so the password cannot be just a number (e.g. `12345` → startup error). Hex from `openssl` contains letters.

Reading the passwords:

```bash
vault kv get secret/apps/nats
vault kv get -field=STATS_SERVICE_PASSWORD secret/apps/nats
```

Changing a password: `vault kv patch secret/apps/nats COLLECTOR_PASSWORD=-`, then (a Secret change alone does not restart the pod):

```bash
kubectl -n apps annotate externalsecret nats-auth force-sync=$(date +%s) --overwrite
kubectl -n apps rollout restart statefulset/nats
```

and the new password in the application: `STATS_SERVICE_PASSWORD` is `NATS_PASSWORD` of statistics-service (below), `MON_HOME_ASS_PASSWORD` is `NATS_PASSWORD` of mon-home-ass ([mon-home-ass `.devops/README.md`](https://github.com/jagieloadrian/mon-home-ass/blob/main/.devops/README.md#statistics-publisher-nats)).

Without the keys in Vault, Secret `nats-auth` does not exist and pod `nats-0` waits in `CreateContainerConfigError`. HelmRelease `nats` keeps retrying the install (`install.remediation.retries: -1`), so it recovers on its own once the keys exist.

## statistics-service

statistics-service runs with `BROKER: jetstream`. `NATS_URL`, `NATS_USER` (`statistics-service`) and the other `NATS_*` values are in `values.env` of its `.devops/helm/release.yaml`. On start it creates the stream `STATS_INGEST` (subjects `stats.ingest.>`) and its durable consumer.

`NATS_PASSWORD` in Vault must equal `STATS_SERVICE_PASSWORD` ([setup.md](setup.md), step 7, copies it). Without it the consumer keeps retrying and logs `jetstream broker unavailable`; the HTTP API works either way.

## mon-home-ass

mon-home-ass publishes Home Assistant statistics as the user `mon-home-ass` to `stats.ingest.home-assistant`, the subject of the statistics-service source `home-assistant`. Its `NATS_PASSWORD` must equal `MON_HOME_ASS_PASSWORD` ([setup.md](setup.md), step 7). It also needs `SOURCE_TOKEN`: [mon-home-ass `.devops/README.md`](https://github.com/jagieloadrian/mon-home-ass/blob/main/.devops/README.md#statistics-publisher-nats).

## Test

```bash
export KUBECONFIG=<homelab-infra checkout>/terraform/kubeconfig
kubectl -n apps get pods,pvc -l app.kubernetes.io/name=nats
kubectl -n apps port-forward svc/nats 4222
```

The port-forward goes through the kubelet straight to the pod. It bypasses ztunnel and AuthorizationPolicy `nats`, which is why the laptop can connect. The NATS users and passwords still apply.

In a second terminal (`nats` CLI; without installing: `docker run --rm -it --network host natsio/nats-box nats ...`):

```bash
export NATS_URL=nats://localhost:4222
COLLECTOR_PASSWORD=$(vault kv get -field=COLLECTOR_PASSWORD secret/apps/nats)
STATS_PASSWORD=$(vault kv get -field=STATS_SERVICE_PASSWORD secret/apps/nats)

nats --user collector --password "$COLLECTOR_PASSWORD" \
  pub stats.ingest.<sourceId> --header "Authorization: Bearer <source token>" '<json>'
nats --user statistics-service --password "$STATS_PASSWORD" stream info STATS_INGEST
nats pub stats.ingest.x x
```

The first command publishes as `collector`, the second shows the stream counters. The last command has no password and must fail with `Authorization Violation`.

Do not pull messages from the `statistics-service` consumer manually (`nats consumer next`), because you would take them away from the application. Whether they arrived shows in `stream info` (counters) and in the statistics-service logs.

## Backup

The queue is a buffer: messages end up in Postgres, and the stream has an age and size limit (default 7 days, 256 MiB, set by the application). Losing the PVC loses only unprocessed messages; the application recreates the stream and consumer at startup. Copy (e.g. before replacing the RPi5 card/disk), with a short pause in accepting messages:

```bash
kubectl -n apps scale statefulset nats --replicas 0
ssh rpi 'cd /var/lib/rancher/k3s/storage && sudo tar -czf - *_apps_nats-js-nats-0' > nats-js-$(date +%F).tgz
kubectl -n apps scale statefulset nats --replicas 1
```

Restore: the same in reverse (`replicas 0`, extract into the PVC directory, `replicas 1`). `nats stream backup`/`restore` is not an option: restore publishes to `$JS.SNAPSHOT.>`, which `statistics-service` is not allowed to do, and there is deliberately no separate admin.

## Exposing on the LAN (not deployed)

By default NATS is not reachable outside the cluster. When a collector is to run on a device in the LAN:

1. In `apps/nats/` an additional Service `nats-lan` of type `LoadBalancer` (selector `app.kubernetes.io/instance: nats`, port 4222 → `targetPort: nats`). k3s ServiceLB exposes it on the RPi5 IP: `nats://<RPi5 IP>:4222`.
2. In AuthorizationPolicy `nats` a second rule `from.source.ipBlocks` with port 4222. LAN traffic has no mesh identity, and ServiceLB does DNAT + masquerade in the `svclb` pod, so NATS sees that pod's address, not the device's. Check the actual address in the ztunnel logs (`kubectl -n istio-system logs ds/ztunnel | grep nats`); in practice it is the pod CIDR (`10.42.0.0/16`).
3. The boundary remains the NATS user and password, and these travel over the LAN in plain text. Before exposing, enable TLS (`config.nats.tls` in values) or give the devices separate users with narrow permissions.
