# Architecture

How the parts fit together. Setup steps: [setup.md](setup.md).

## Machines

| Machine | Role | Runs |
| --- | --- | --- |
| Raspberry Pi 5 (arm64, `homelab/node=rpi`) | k3s server | Istio control plane, Vault, NATS, app pods |
| Dell Wyse 5070 (amd64, `homelab/node=wyse`) | k3s agent | app pods; outside k3s: Postgres and Home Assistant |

Postgres is not in the cluster. Service `postgres.apps` points at the Wyse IP ([postgres.md](postgres.md)).

## Requests and data

```mermaid
flowchart LR
    Browser[browser in the LAN] --> GW["home-gateway (Istio)<br/>*.home.arpa"]
    GW -->|"statistics.home.arpa/"| UI[statistics-ui]
    GW -->|"statistics.home.arpa/api/"| SS[statistics-service]
    GW -->|"mon-home-ass.home.arpa"| MHA[mon-home-ass]
    Devices[devices, collectors] -->|"HTTP push /api/v2/ingest"| GW
    MHA -->|"stats.ingest.home-assistant"| NATS[(NATS JetStream<br/>stream STATS_INGEST)]
    NATS --> SS
    subgraph wyse[Wyse, outside k3s]
        HA[Home Assistant] --> PGHA[(Postgres: home_assistant)]
        PGS[(Postgres: statistics)]
    end
    MHA -->|read-only| PGHA
    SS --> PGS
```

- The browser loads statistics-ui and calls statistics-service on the same host under `/api/`, so no CORS is needed.
- Data gets into statistics-service in two ways: HTTP push from devices, or messages from NATS. mon-home-ass reads Home Assistant's 5-minute statistics and publishes them every 60 s. Details: [statistics-service README, "How data gets in"](https://github.com/jagieloadrian/statistics-service#how-data-gets-in).
- Inside the cluster Istio ambient encrypts pod-to-pod traffic. AuthorizationPolicies decide which ServiceAccount may call what: the gateway → apps, statistics-service and mon-home-ass → NATS.

## Delivery

```mermaid
flowchart LR
    Dev[push to main of an app repo] --> CI[GitHub Actions]
    CI -->|image| GHCR[(GHCR)]
    CI -->|"commit: new image tag in .devops/helm/release.yaml<br/>(as GitHub App)"| AppRepo[app repo main]
    Infra[homelab-infra main] --> Flux
    AppRepo -->|"once a day or flux reconcile"| Flux[Flux in k3s]
    Flux -->|"HelmRelease with charts/app"| Pods[app pods]
    GHCR -->|pull| Pods
```

- homelab-infra holds the platform and the shared chart `charts/app`. Each app repo holds only its HelmRelease and values in `.devops/helm/` ([apps.md](apps.md)).
- Flux reads homelab-infra every minute and app repos once a day. To deploy right away: `flux reconcile kustomization <app> -n flux-system --with-source`.

## Secrets

```mermaid
flowchart LR
    You[you: vault kv put] --> Vault[(Vault<br/>secret/apps/app)]
    Vault -->|"SecretStore vault<br/>(ServiceAccount vault-reader)"| ESO[External Secrets Operator]
    ESO -->|every hour| Secret[Secret app-secrets]
    Secret -->|envFrom| Pod[app pod]
```

Git holds only which Vault path to read, never values. After a restart Vault is sealed and has to be unsealed by hand; Secrets already in the cluster keep working meanwhile ([vault.md](vault.md)).
