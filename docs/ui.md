# UI panels

Headlamp and Capacitor run locally on the laptop with the kubeconfig, nothing runs in the cluster. Kiali has to run in the cluster (`infrastructure/kiali.yaml`), but it has no HTTPRoute, so you reach it via port-forward.

```bash
export KUBECONFIG=<homelab-infra checkout>/terraform/kubeconfig
```

## Headlamp: cluster console (like OpenShift/GKE)

Workloads, logs, exec, events, YAML editing.

```bash
flatpak install flathub io.kinvolk.Headlamp
```

Or download the AppImage from `https://github.com/kubernetes-sigs/headlamp/releases`.

The cluster is loaded from `KUBECONFIG`. Flux is visible after installing the Flux plugin (Plugin Catalog in the app).

## Capacitor: Flux UI

Kustomization/HelmRelease tree, Helm history, diff between git and the cluster.

```bash
wget -qO- https://gimlet.io/install-capacitor | bash
next --port 3333
```

With Homebrew: `brew install gimlet-io/capacitor/capacitor`. `next` is the Capacitor binary. Open `http://localhost:3333`.

## Kiali: Istio mesh

Traffic graph, service health, Istio config validation. It takes metrics from Prometheus in `istio-system` (no disk, 2 days retention, a pod restart clears them).

```bash
kubectl -n istio-system port-forward svc/kiali 20001
```

Open `http://localhost:20001`.

Login is disabled (`auth.strategy: anonymous`), because only someone who can already port-forward has access. Before exposing Kiali via HTTPRoute, switch to `openid` via Authelia.

In ambient, the graph shows L4 (TCP) traffic from ztunnel. L7 metrics (HTTP: codes, latencies) only appear after adding a waypoint in the `apps` namespace.
