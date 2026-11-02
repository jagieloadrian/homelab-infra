# homelab-infra

Platform from the "Homelab Platform Contract" document: 2-node k3s (RPi5 arm64 + Dell Wyse 5070 amd64), Istio ambient, Gateway API, Flux, SOPS (age).

| What | Where | How |
| --- | --- | --- |
| k3s server (RPi5, `homelab/node=rpi`) + agent (Wyse, `homelab/node=wyse`) | `terraform/k3s` | Terraform over SSH |
| Flux, Secret `sops-age` | `terraform/flux` | Terraform (`fluxcd/flux`) |
| Gateway API v1.6 CRDs, Istio ambient (base, istiod, cni, ztunnel) | `infrastructure/` | Flux |
| Gateway `home-gateway` (`istio-ingress`), namespace `apps` with ambient | `infrastructure/platform.yaml` | Flux |
| Own apps: list, one file per app | `clusters/home/apps/` | Flux (read-only from app repos) |
| Shared Helm chart for own apps | `charts/app/` | Flux (HelmRelease from app repo) |
| HelmRelease + values of own apps | `.devops/helm/` in app repo | Flux |
| Ready-made apps (Helm chart, no build) | `apps/<name>/` | Flux |
| NATS with JetStream: statistics-service ingest queue | `apps/nats/` | Flux (Helm) |
| App registration | `scripts/new-app.sh` | script |

## Setup from scratch

Step by step, including what to put in `.env` and the secrets files: **[docs/setup.md](docs/setup.md)**.

In short: `.env` (Terraform inputs) → age key → app secrets → Postgres on Wyse → push → `terraform apply` in `terraform/k3s`, then in `terraform/flux`.

## Apps

Two kinds, both in namespace `apps` (ambient mesh):

| Kind | Config | Registration | Updates |
| --- | --- | --- | --- |
| Own (built in CI) | `.devops/helm/` in app repo (chart `charts/app`) | `scripts/new-app.sh own <name>` | CI commits new tag to `.devops/helm/release.yaml` |
| Ready-made (Helm chart: Authelia, oauth2-proxy…) | `apps/<name>/` here | `scripts/new-app.sh helm <name> <repo> <chart> <version> [port]` | Flux installs new versions within the semver range on its own |

### Ready-made app (Helm chart)

```bash
scripts/new-app.sh helm authelia https://charts.authelia.com authelia 0.11.x 80
```

This creates `apps/authelia/release.yaml`: HelmRepository (OCI too: `oci://...`), HelmRelease, HTTPRoute `authelia.home.arpa`, AuthorizationPolicy. Then:

1. `helm show values authelia --repo https://charts.authelia.com` and fill in the needed `values` (contract checklist in the file).
2. Secrets (passwords, OIDC keys) as values in a Secret:
   ```bash
   cat > apps/authelia/secret.sops.yaml <<'EOF'
   apiVersion: v1
   kind: Secret
   metadata:
     name: authelia-values
   stringData:
     values.yaml: |
       # sensitive chart values
   EOF
   sops -e -i apps/authelia/secret.sops.yaml   # .sops.yaml: put your age public key
   ```
   and uncomment `valuesFrom` in the HelmRelease. Never commit an unencrypted file.
3. Commit + push. Flux deploys within ≤ 10 min (`flux reconcile kustomization apps --with-source` right away).

Version `0.11.x` means Flux installs new 0.11.* releases on its own. A major bump is a manual range change.
Authelia: the chart creates a DaemonSet by default, set `pod.kind: Deployment`. Forward-auth for other apps requires `extensionProviders` in istiod (separate step).

### Own app (`.devops/helm/`)

Flow: merge to `main` → CI builds image `main-<ts>-<sha7>` → CI bumps the tag in `.devops/helm/release.yaml` and commits → Flux (every 1 min) sees the commit → HelmRelease upgrade → rollout. Rollback = `git revert` in the app repo.

Manifests are rendered by the shared chart [`charts/app`](charts/app/values.yaml) (ServiceAccount, Deployment, Service, HTTPRoute, AuthorizationPolicy, ConfigMap/Secret from env). The app repo has only values. Example: StatisticsService `.devops/helm/`.

1. `.devops/helm/release.yaml`: HelmRelease with the chart from this repo and values (described in `charts/app/values.yaml`):
   ```yaml
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: hello
   spec:
     interval: 10m
     chart:
       spec:
         chart: ./charts/app
         reconcileStrategy: Revision
         sourceRef:
           kind: GitRepository
           name: flux-system
           namespace: flux-system
     valuesFrom:                      # only when there are secrets (item 2)
       - kind: Secret
         name: hello-values
     values:
       image: ghcr.io/jagieloadrian/hello:main-00000000000000-0000000
       route:
         hostname: hello.home.arpa    # empty = no HTTPRoute
       env:                           # plain config -> ConfigMap hello-config
         LOG_FORMAT: json
   ```
   Changing `values.env` / `secretEnv` triggers a rollout (annotation `checksum/env`). `namespace` can be omitted, Flux enforces `apps`.
2. Secrets (optional) as encrypted Helm values:
   - `secrets.sops.yaml`: `secretEnv: {KEY: value}` → Secret `hello-secrets` (`envFrom`), created and edited only via `sops <file>`,
   - `kustomization.yaml` next to it (Flux decrypts at build time, the key must end in `.yaml`):
     ```yaml
     resources: [release.yaml]
     secretGenerator:
       - name: hello-values
         files: [values.yaml=secrets.sops.yaml]
         options:
           disableNameSuffixHash: true
           labels:
             reconcile.fluxcd.io/watch: Enabled
     ```
   - `.sops.yaml` in the app repo:
     ```yaml
     creation_rules:
       - path_regex: \.devops/helm/secrets\.sops\.yaml$
         age: age1...   # age-keygen -y ~/.config/sops/age/keys.txt
     ```
3. In the `build` workflow from the contract: `permissions.contents: write` and a step after the image push:
   ```yaml
         - name: Deploy (bump image tag)
           if: github.ref == 'refs/heads/main'
           run: |
             sed -i -E "s#(image: ghcr.io/${{ github.repository_owner }}/${{ github.event.repository.name }}):[^[:space:]]+#\1:${{ steps.tag.outputs.tag }}#" .devops/helm/release.yaml
             git config user.name 'github-actions[bot]'
             git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
             git commit -am "chore(deploy): ${{ steps.tag.outputs.tag }}"
             git pull --rebase && git push
   ```
   A push with `GITHUB_TOKEN` doesn't trigger another workflow, so there is no loop. Branch protection on `main` must let `github-actions[bot]` through.
   Validation in app CI (`devops.yml`, example: StatisticsService): checkout `charts/` from this repo, `helm template` with values from `release.yaml` + `kubeconform`.
4. Registration here: `scripts/new-app.sh own hello`, commit + push.
   Private app repo: add `secretRef` to `GitRepository` (example: `clusters/home/apps/mon-home-ass.yaml`).
   Local preview: `yq .spec.values .devops/helm/release.yaml | helm template hello ../homelab-infra/charts/app -f -`.

## Guides

- [Setup from scratch](docs/setup.md): steps in order, `.env`, age key, secrets
- [Postgres on Wyse 5070](docs/postgres.md): database outside the cluster, user + schema per app
- [Statistics](docs/statistics.md): deploying statistics-service and statistics-ui
- [UI panels](docs/ui.md): Headlamp and Capacitor locally, Kiali via port-forward
- [NATS with JetStream](docs/nats.md): queue for statistics-service, users, passwords, test, backup

## To bump

- Istio `1.30.x` → `1.31.x` once 1.31 is out of RC (`infrastructure/istio.yaml`).
- `wyse_system_reserved_memory` (default `4Gi`, approx. 3.4 GiB for pods with 8 GB RAM) to match the Wyse's real RAM.
