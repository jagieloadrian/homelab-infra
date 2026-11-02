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
      version: '__VERSION__'
      sourceRef:
        kind: HelmRepository
        name: __NAME__
  values: {}
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
        - name: __NAME__
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
