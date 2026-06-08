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

## Grafana access

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
