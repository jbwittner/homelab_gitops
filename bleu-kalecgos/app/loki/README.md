# loki

## Rôle

Stockage et requêtage des **logs** du cluster : la moitié « logs » de l'observabilité, à côté de
[kube-prometheus-stack](../kube-prometheus-stack/README.md) pour les métriques. Les logs sont
poussés par [alloy](../alloy/README.md) et lus depuis Grafana (datasource `Loki`, déclarée dans
les values du kube-prometheus-stack).

Déployé en mode **SingleBinary** sur un PVC `filesystem` : les modes SimpleScalable et Distributed
du chart exigent du stockage objet, hors sujet sur un cluster mono-nœud. Non exposé sur le
`shared-gw` — l'API Loki n'a pas d'authentification (`auth_enabled: false`) et n'est jointe qu'en
intra-cluster par Grafana et Alloy.

## Fichiers

- `loki.app.yaml` — Application ArgoCD multi-sources : chart Helm + values (`$values`) +
  `manifests/`. `ServerSideApply=true` (ConfigMaps de config volumineux).
- `helm-values.yaml` — mode SingleBinary, stockage filesystem + `schemaConfig` tsdb/v13,
  rétention 15 j via le compactor, PVC `openebs-lvm-thin`, caches memcached et canary coupés,
  ServiceMonitor activé.
- `manifests/namespace.yaml` — namespace `loki` (pas de label PSA : Loki tourne non-root).
- `manifests/kustomization.yaml` — assemblage.

## Opérations

### Rétention

Deux réglages **indissociables** dans `helm-values.yaml` :
`loki.limits_config.retention_period` (fenêtre interrogeable) et
`loki.compactor.retention_enabled: true` (suppression réelle sur disque). Sans le second, le PVC
grossit sans fin même si les vieilles lignes deviennent invisibles. La valeur est alignée sur la
rétention Prometheus, pour que les deux datasources couvrent la même période.

### Surveiller le remplissage du PVC

```bash
kubectl -n loki get pvc
kubectl -n loki exec loki-0 -- df -h /var/loki
```

Le PVC est extensible à chaud (`allowVolumeExpansion` sur `openebs-lvm-thin`) : augmenter `size`
dans `helm-values.yaml`, commit, push.

### État / debug

```bash
kubectl -n loki get pods,svc
kubectl -n loki logs sts/loki
kubectl -n loki port-forward svc/loki-gateway 3100:80   # puis /ready, /metrics, /loki/api/v1/labels
```

Aucun log n'arrive alors que Loki est `Ready` → le problème est côté collecteur, voir
[alloy](../alloy/README.md).

Le ServiceMonitor n'est rendu par le chart que si la CRD `monitoring.coreos.com/v1/ServiceMonitor`
est vue à la génération des manifestes — s'il manque (`kubectl -n loki get servicemonitor` vide),
les métriques Loki ne sont simplement pas scrapées, l'ingestion, elle, continue.

### Suppression des données

Le PVC est volontairement conservé si le StatefulSet disparaît
(`enableStatefulSetAutoDeletePVC: false`) : purger l'historique est un geste manuel explicite
(`kubectl -n loki delete pvc …`), pas un effet de bord d'un `prune` ArgoCD.
