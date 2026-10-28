# Panele UI

Headlamp i Capacitor działają lokalnie na laptopie z kubeconfigiem, w klastrze nic nie stoi. Kiali musi działać w klastrze (`infrastructure/kiali.yaml`), ale nie ma HTTPRoute, więc wchodzi się do niego przez port-forward.

```bash
export KUBECONFIG=~/IdeaProjects/homelab-infra/terraform/kubeconfig
```

## Headlamp: konsola klastra (jak OpenShift/GKE)

Workloady, logi, exec, zdarzenia, edycja YAML.

```bash
flatpak install flathub io.kinvolk.Headlamp   # albo AppImage z github.com/kubernetes-sigs/headlamp/releases
```

Klaster wczytuje się z `KUBECONFIG`. Fluxa widać po doinstalowaniu wtyczki Flux (Plugin Catalog w aplikacji).

## Capacitor: UI do Fluxa

Drzewo Kustomization/HelmRelease, historia Helma, diff między gitem a klastrem.

```bash
brew install gimlet-io/capacitor/capacitor     # albo: wget -qO- https://gimlet.io/install-capacitor | bash
next --port 3333                               # http://localhost:3333
```

## Kiali: mesh Istio

Graf ruchu, zdrowie usług, walidacja konfiguracji Istio. Metryki bierze z Prometheusa w `istio-system` (bez dysku, 2 dni retencji, restart poda je czyści).

```bash
kubectl -n istio-system port-forward svc/kiali 20001   # http://localhost:20001
```

Logowanie jest wyłączone (`auth.strategy: anonymous`), bo dostęp ma tylko ktoś, kto już może robić port-forward. Przed wystawieniem Kiali przez HTTPRoute trzeba przełączyć na `openid` przez Authelię.

W ambient graf pokazuje ruch L4 (TCP) z ztunnela. Metryki L7 (HTTP: kody, latencje) pojawią się dopiero po dodaniu waypointa w namespace `apps`.
