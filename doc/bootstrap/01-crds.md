# 1. CRDs

Avant tout le reste. L'API server répond sans CNI.

| CRDs | Pourquoi au bootstrap | Repris par |
|---|---|---|
| Gateway API | le chart Cilium ne crée la GatewayClass `cilium` que si elles existent, et l'operator ne les voit qu'à son démarrage | `gateway-api-<cluster-court>` |
| Prometheus Operator (`ServiceMonitor`, `PodMonitor`…) | les composants déclarent leurs moniteurs (ArgoCD dès l'étape 4, OpenEBS…) : une CRD absente fait échouer toute leur synchro | `prometheus-operator-crds-<cluster-court>` |

Depuis la racine du dépôt, un cluster à la fois :

```sh
# malygos
C=bleu-malygos  CTX=admin@bleu-malygos

# kalecgos
C=bleu-kalecgos CTX=admin@bleu-kalecgos
```

## Installer

Version du chart lue dans l'`.app.yaml` (tenue à jour par Renovate).

```sh
kubectl --context $CTX apply --server-side -k components/gateway-api/manifests

V=$(yq '.spec.sources[0].targetRevision' clusters/$C/prometheus-operator-crds/prometheus-operator-crds.app.yaml)
helm template prometheus-operator-crds prometheus-operator-crds \
  --repo https://prometheus-community.github.io/helm-charts --version $V \
  | kubectl --context $CTX apply --server-side -f -
```

## Vérifier

```sh
kubectl --context $CTX get crd | rg -c gateway.networking     # 10
kubectl --context $CTX get crd | rg -c monitoring.coreos.com   # 10
```
