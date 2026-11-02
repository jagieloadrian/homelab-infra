# Adding apps

Two kinds, both in namespace `apps` (ambient mesh):

| Kind | Config | Registration | Updates |
| --- | --- | --- | --- |
| Own (built in CI) | `.devops/helm/release.yaml` in the app repo (chart `charts/app`) | `scripts/new-app.sh own <name>` | CI commits the new image tag to `.devops/helm/release.yaml` |
| Ready-made (Helm chart: Authelia, oauth2-proxy…) | `apps/<name>/` here | `scripts/new-app.sh helm <name> <repo> <chart> <version> [port]` | Flux installs new versions within the semver range on its own |

## Own app

Flow: merge to `main` → CI builds image `main-<ts>-<sha7>` → CI bumps the tag in `.devops/helm/release.yaml` and commits → Flux sees the commit within a minute (the app's GitRepository has `interval: 1m`) → HelmRelease upgrade → rollout. Rollback = `git revert` in the app repo.

The shared chart [`charts/app`](../charts/app) renders ServiceAccount, Deployment, Service, HTTPRoute, AuthorizationPolicy, ConfigMap from `env` and ExternalSecret. The app repo holds only values. Example: statistics-service `.devops/helm/`.

### What the app must do

- Listen on HTTP port `port` (default 8080) and serve `/health/live` and `/health/ready`.
- Run as a non-root user (the pod runs as UID 10001) with a read-only root filesystem. Only `/tmp` is writable.
- Take its config from environment variables.
- Image on GHCR, public, multi-arch (amd64 + arm64), because pods run on both nodes.

### Chart values

| Value | Default | Meaning |
| --- | --- | --- |
| `image` | none, required | `ghcr.io/<owner>/<app>:<tag>`. CI bumps the tag. |
| `port` | `8080` | container port. The app must serve `/health/live` and `/health/ready` on it. |
| `resources` | requests `cpu: 100m`, `memory: 256Mi`; limit `memory: 256Mi` | keep the memory limit equal to the request, no CPU limit |
| `tmpSize` | `64Mi` | size of the `emptyDir` on `/tmp`. The root filesystem is read-only. |
| `env` | `{}` | plain config → ConfigMap `<app>-config`, loaded as env. A change triggers a rollout. |
| `secrets` | `false` | `true` = Secret `<app>-secrets` from Vault `secret/apps/<app>`, loaded as env ([vault.md](vault.md)) |
| `route.hostname` | empty | host of the HTTPRoute on `home-gateway`. Empty = no HTTPRoute. |
| `route.pathPrefix` | `/` | path prefix routed to the app (statistics-service uses `/api/`) |

### Steps

1. `.devops/helm/release.yaml` in the app repo:
   ```yaml
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: hello
   spec:
     interval: 10m
     install:
       remediation:
         retries: -1
     upgrade:
       remediation:
         retries: 3
     chart:
       spec:
         chart: ./charts/app
         reconcileStrategy: Revision
         sourceRef:
           kind: GitRepository
           name: flux-system
           namespace: flux-system
     values:
       image: ghcr.io/jagieloadrian/hello:main-00000000000000-0000000
       route:
         hostname: hello.home.arpa
       env:
         LOG_FORMAT: json
       secrets: true
   ```
   `install.remediation.retries: -1` makes Flux retry the first install until it works, for example until the Vault keys exist. `upgrade.remediation.retries: 3` retries a failed upgrade three times. `namespace` can be omitted, Flux enforces `apps`.
2. Secrets (optional): `secrets: true`, and the keys (= env variable names) in Vault `secret/apps/<app>` ([vault.md](vault.md)). A secret change in Vault needs a restart ([vault.md](vault.md), "Change takes effect").
3. In the app's build workflow: `permissions.contents: write` and a step after the image push:
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
   A push with `GITHUB_TOKEN` does not trigger another workflow, so there is no loop. If `main` is protected by a ruleset, add GitHub Actions to its bypass list, or this push fails.
   Validation in app CI (`devops.yml`, example: statistics-service): check out `charts/` from this repo, `helm template` with the values from `release.yaml`, then `kubeconform`.
4. Register it here: `scripts/new-app.sh own hello`, commit and push. This creates `clusters/home/apps/hello.yaml`: a GitRepository that reads only `.devops/helm/` from the app repo's `main`, and a Kustomization that applies it.
   Private app repo: add `secretRef: {name: flux-system}` to the GitRepository (example: `clusters/home/apps/mon-home-ass.yaml`). The GitHub PAT needs Contents read on that repo ([setup.md](setup.md), step 1).
5. Make the GHCR package public after the first CI build ([setup.md](setup.md), step 3).

Local preview of the rendered manifests, from the app repo:

```bash
yq .spec.values .devops/helm/release.yaml | helm template hello <homelab-infra checkout>/charts/app -f -
```

## Ready-made app (Helm chart)

```bash
scripts/new-app.sh helm authelia https://charts.authelia.com authelia 0.11.x 80
```

This creates `apps/authelia/release.yaml`: HelmRepository (OCI too: `oci://...`), HelmRelease, HTTPRoute `authelia.home.arpa`, AuthorizationPolicy that admits only the gateway.

1. Read the chart's values: `helm show values authelia --repo https://charts.authelia.com`. Fill in `values` in the HelmRelease, following the checklist below.
2. Secrets as chart values: see "Secrets from Vault" below. No Secret in git.
3. Commit and push. Flux deploys within 10 minutes; `flux reconcile kustomization apps --with-source` applies it right away.

Version `0.11.x` means Flux installs new 0.11.* releases on its own. A major bump is a manual change of the range.

### Checklist

The keys depend on the chart. Check the result with `helm template authelia --repo https://charts.authelia.com --version '0.11.x' -f <your values>`.

- Resources: memory request = memory limit, no CPU limit.
- Stateful (uses a PVC): `nodeSelector` `homelab/node: rpi`, 1 replica.
- The chart's own ingress is off. Traffic goes through the generated HTTPRoute.
- The image is multi-arch (amd64 + arm64). The chart version pins the image tag.
- `backendRefs` `name` in the HTTPRoute must be the chart's Service name. Find it with `helm template authelia --repo https://charts.authelia.com | grep -A5 'kind: Service'`. Set `port` to that Service's port.
- Other apps that call this one: add `cluster.local/ns/apps/sa/<caller-app>` under `rules[0].from[0].source.principals` of the AuthorizationPolicy.

### Secrets from Vault

Put the secret part of the values in Vault as one key, `values.yaml`, in `secret/apps/<name>`. `@file` reads the value from a file; delete the file afterwards:

```bash
vault kv put secret/apps/authelia values.yaml=@authelia-secret-values.yaml
```

Add an ExternalSecret `<name>-values` to `apps/<name>/release.yaml` (same shape as `nats-auth` in `apps/nats/release.yaml`):

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: authelia-values
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: vault
  target:
    name: authelia-values
  dataFrom:
    - extract:
        key: apps/authelia
```

and `valuesFrom` in the HelmRelease `spec`, next to `values`:

```yaml
  valuesFrom:
    - kind: Secret
      name: authelia-values
      valuesKey: values.yaml
```

For the same key, inline `values` win over `valuesFrom`, so keep secret keys only in Vault.

### Authelia notes

The chart creates a DaemonSet by default: set `pod.kind: Deployment`. Forward-auth for other apps needs `extensionProviders` in istiod (a separate step).
