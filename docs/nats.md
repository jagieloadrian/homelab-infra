# NATS with JetStream: ingest queue

Queue for statistics-service ingest pub/sub (`BROKER=jetstream`). Ready-made application from a Helm chart: `apps/nats/release.yaml`. Available only inside the cluster.

| | |
| --- | --- |
| Chart | `nats` `2.15.x` from `https://nats-io.github.io/k8s/helm/charts/`, image `nats:<chart version>-alpine` (multi-arch) |
| Pod | StatefulSet `nats`, 1 replica, no NATS cluster, RPi5 (`homelab/node=rpi`). With 1 replica an update behaves like `Recreate` |
| Address | `nats://nats.apps.svc.cluster.local:4222`: Service `nats`, `appProtocol: tcp`, no HTTPRoute (it is not HTTP) |
| JetStream | file store on PVC `nats-js-nats-0` (`local-path`, 2 Gi), `max_file_store` limit 1 GiB; memory store 32 MiB |
| Monitoring | `:8222` only in headless Service `nats-headless`; AuthorizationPolicy does not allow it, kubelet probes bypass ztunnel |
| Runtime | UID 10001, read-only root FS, `drop: [ALL]`, `seccompProfile: RuntimeDefault`, ServiceAccount `nats` without a token |
| RAM | 256 Mi (request = limit), `GOMEMLIMIT=200MiB`, no reloader sidecar. A few MiB at idle; more with a queue backlog (file store block cache) |
| Secrets | Secret `nats-auth` from `apps/nats/secret.sops.yaml` (passwords as environment variables in `nats.conf`) |

The `STATS_INGEST` stream (subjects `stats.ingest.>`, file storage) and the durable pull consumer `statistics-service` are created by the application itself at startup. The JetStream controller (NACK) is not needed.

Changing `values` in `release.yaml` = new ConfigMap and pod restart (config checksum annotation, instead of hot reload via a sidecar).

## Users

| User | Publish | Subscribe | Who |
| --- | --- | --- | --- |
| `statistics-service` | `$JS.API.>`, `$JS.ACK.>`, `_INBOX.>` | `stats.ingest.>`, `_INBOX.>` | statistics-service: manages the stream and consumes |
| `collector` | `stats.ingest.>` | `_INBOX_collector.>` | data-collecting applications (producers) |

Without a password the server responds `Authorization Violation`; there is no anonymous user.

A collector publishes to `stats.ingest.<sourceId>` with the header `Authorization: Bearer <source token>`. A plain publish (without acknowledgement) needs no subscription. A publish with JetStream acknowledgement requires the inbox prefix `_INBOX_collector` in the client (the "custom inbox prefix" option of NATS libraries, in the CLI `--inbox-prefix _INBOX_collector`). The default `_INBOX.>` is blocked for the collector, because through it the collector would see messages (including source tokens) delivered to statistics-service.

Further collectors can share the `collector` user, because the source is identified by the token in the header anyway. A separate user: an entry in `config.merge.authorization.users` in `release.yaml` + a password in `nats-auth`.

Network (AuthorizationPolicy `nats`): port 4222 only from `cluster.local/ns/apps/sa/statistics-service`. Add a collector running in the cluster as `cluster.local/ns/apps/sa/<collector>` at the spot marked with a comment in `release.yaml`.

## Secrets (once, before the first deployment)

Requires the age key in `.sops.yaml` ([setup.md](setup.md), step 2).

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

NATS reads an environment variable like a value in the config, so the password cannot be just a number (e.g. `12345` → startup error). Hex from `openssl` contains letters.

Reading the passwords:

```bash
sops -d apps/nats/secret.sops.yaml
sops -d --extract '["stringData"]["STATS_SERVICE_PASSWORD"]' apps/nats/secret.sops.yaml
```

Changing a password: `sops apps/nats/secret.sops.yaml`, push, then `kubectl -n apps rollout restart statefulset/nats` (a Secret change alone does not restart the pod) and the new password in the application.

Without the Secret, pod `nats-0` is stuck in `CreateContainerConfigError`, and HelmRelease `nats` fails after 5 min. After adding the Secret: `flux reconcile helmrelease nats -n apps --force`.

## statistics-service

`StatisticsService/.devops/helm/release.yaml`, `values.env`:

```yaml
BROKER: jetstream
NATS_URL: nats://nats.apps.svc.cluster.local:4222
```

`StatisticsService/.devops/helm/secrets.sops.yaml`, `secretEnv` (`sops .devops/helm/secrets.sops.yaml`):

```yaml
NATS_USER: statistics-service
NATS_PASSWORD: <STATS_SERVICE_PASSWORD from apps/nats/secret.sops.yaml>
```

## Test

```bash
export KUBECONFIG=~/IdeaProjects/homelab-infra/terraform/kubeconfig
kubectl -n apps get pods,pvc -l app.kubernetes.io/name=nats
kubectl -n apps port-forward svc/nats 4222      # port-forward bypasses ztunnel and AuthorizationPolicy
```

In a second terminal (`nats` CLI; without installing: `docker run --rm -it --network host natsio/nats-box nats ...`):

```bash
export NATS_URL=nats://localhost:4222
COLLECTOR_PASSWORD=$(sops -d --extract '["stringData"]["COLLECTOR_PASSWORD"]' apps/nats/secret.sops.yaml)
STATS_PASSWORD=$(sops -d --extract '["stringData"]["STATS_SERVICE_PASSWORD"]' apps/nats/secret.sops.yaml)

nats --user collector --password "$COLLECTOR_PASSWORD" \
  pub stats.ingest.<sourceId> --header "Authorization: Bearer <source token>" '<json>'
nats --user statistics-service --password "$STATS_PASSWORD" stream info STATS_INGEST
nats pub stats.ingest.x x                       # without password: Authorization Violation
```

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
