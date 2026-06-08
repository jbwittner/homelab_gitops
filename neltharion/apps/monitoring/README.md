# monitoring — kube-prometheus-stack

Wave 4. Full monitoring stack via [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) (chart `86.2.0`).

## What runs

| Component | Role |
|-----------|------|
| Prometheus | Metrics collection & TSDB |
| Grafana | Dashboards — `https://grafana.wittnerlab.com` |
| Alertmanager | Alert routing |
| node-exporter | Host-level metrics (DaemonSet) |
| kube-state-metrics | Kubernetes object metrics |

## Storage

All three stateful components use `local-path` PVCs:

| Component | Size |
|-----------|------|
| Prometheus | 10 Gi |
| Grafana | 2 Gi |
| Alertmanager | 1 Gi |

### Monitoring des volumes

> ⚠️ **local-path crée des PV de type `hostPath`** : le kubelet n'émet donc PAS
> `kubelet_volume_stats_*` → **pas d'usage disque par-PVC**. De plus la taille du PVC
> n'est **pas appliquée** (bind-mount : un PVC peut remplir tout le disque). La métrique
> pertinente est l'usage du filesystem sous-jacent **`/var/mnt/data`** (XFS dédié), exposé
> par node-exporter (`node_filesystem_*`). De vraies stats par-PVC nécessiteraient un CSI
> (TopoLVM, OpenEBS, Longhorn) à la place de local-path.

- **Alertes** : déjà couvertes par les règles node-exporter du chart
  (`NodeFilesystemAlmostOutOfSpace`, `NodeFilesystemSpaceFillingUp`, + variantes inodes),
  qui s'appliquent à tous les filesystems dont `/var/mnt/data`.
- **Dashboard** : `volumes-dashboard.configmap.yaml` (ConfigMap `grafana_dashboard=1`,
  uid `homelab-volumes`, titre « Volumes / local-path ») — usage de `/var/mnt/data`,
  estimation jours-avant-saturation, inventaire PVC (kube-state-metrics) et taille TSDB
  Prometheus. Coexiste avec les dashboards upstream.

## Grafana access

Exposé via une **IngressRoute Traefik** (`ingress-route.yaml`) + un **Certificate cert-manager**
(`certificate.yaml`, secret `grafana-tls`, ClusterIssuer `letsencrypt-prod`), comme whoami/argocd.
L'Ingress généré par le chart est désactivé (`grafana.ingress.enabled: false`) : un Ingress
standard reste `Progressing` dans Argo car le service Traefik (ClusterIP) ne lui publie aucun
`status.loadBalancer.ingress`.

URL: `https://grafana.wittnerlab.com`

Username: `admin`

Password (auto-generated secret):
```bash
kubectl get secret monitoring-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Argo CD notes

- `SkipDryRunOnMissingResource=true` is set because the chart installs its own CRDs (PrometheusRule, ServiceMonitor, etc.) during the same sync.
- If persistent diffs appear on admission webhooks after chart upgrades, add an `ignoreDifferences` block to `monitoring.app.yaml`.
