# Gotowa aplikacja z Helm charta. Wygenerowane przez scripts/new-app.sh.
# Do sprawdzenia: helm show values / helm template __CHART__ --repo __URL__ --version '__VERSION__'
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: __NAME__
spec:
  type: oci
  interval: 24h
  url: __URL__
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: __NAME__
spec:
  interval: 1h
  chart:
    spec:
      chart: __CHART__
      version: '__VERSION__' # zakres semver (np. 1.2.x): Flux sam instaluje nowe wydania z zakresu
      sourceRef:
        kind: HelmRepository
        name: __NAME__
  # Sekrety jako values: apps/__NAME__/secret.sops.yaml (Secret __NAME__-values, klucz values.yaml)
  # valuesFrom:
  #   - kind: Secret
  #     name: __NAME__-values
  #     valuesKey: values.yaml
  values: {}
  # Kontrakt (klucze zależą od charta):
  # - resources: requests + limits.memory == requests.memory, bez limitu CPU
  # - stateful (PVC): nodeSelector homelab/node: rpi, 1 replika
  # - ingress chartu wyłączony, ruch przez HTTPRoute niżej
  # - obraz multi-arch (amd64 + arm64), tag przypięty przez wersję charta
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: __NAME__
spec:
  parentRefs:
    - name: home-gateway
      namespace: istio-ingress
      sectionName: http
  hostnames:
    - __NAME__.home.arpa
  rules:
    - backendRefs:
        - name: __NAME__ # Service z charta: helm template ... | grep -A5 'kind: Service'
          port: __PORT__
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: __NAME__
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: __NAME__
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/istio-ingress/sa/home-gateway-istio
              # - cluster.local/ns/apps/sa/<caller-app>
