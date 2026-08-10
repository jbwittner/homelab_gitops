# loki

## Rôle

Stockage et requêtage des **logs** du cluster : la moitié « logs » de l'observabilité, à côté de
[kube-prometheus-stack](../kube-prometheus-stack/README.md) pour les métriques. Les logs sont
poussés par [alloy](../alloy/README.md) et lus depuis Grafana (datasource `Loki`, déclarée dans
les values du kube-prometheus-stack).

Déployé en mode **SingleBinary** sur un PVC `filesystem` : les modes SimpleScalable et Distributed
du chart exigent du stockage objet, hors sujet sur un cluster mono-nœud. Non exposé sur
`shared-gw` — l'API Loki n'a pas d'authentification (`auth_enabled: false`) et n'est jointe qu'en
intra-cluster par Grafana et Alloy.

## Fichiers

- `loki.app.yaml` — Application (archétype (b) : chart + `$values` + `manifests/`),
  `ServerSideApply=true` (ConfigMaps de configuration volumineux)
- `helm-values.yaml` — mode SingleBinary, `replication_factor: 1`, stockage filesystem +
  `schemaConfig` tsdb/v13, rétention via le compactor, PVC sur `openebs-lvm-thin`, caches
  memcached et canary coupés, ServiceMonitor activé
- `manifests/namespace.yaml` — ns `loki` (pas de label PSA : Loki tourne non-root)
- `manifests/kustomization.yaml` — assemblage

## Contraintes

- **`replication_factor: 1`** : avec un seul ingester, un facteur > 1 laisse le ring sous son
  quorum en permanence et les écritures sont refusées.
- **`schemaConfig` explicite obligatoire** depuis Loki 3.x : le chart refuse de rendre sans, la
  date `from` étant propre à chaque installation. Ne jamais réécrire l'entrée existante — en
  ajouter une nouvelle avec une date future si le schéma doit changer.
- Les composants du mode distribué (`read`/`write`/`backend`) restent à 0 replica, sinon le chart
  échoue au rendu (« Cannot run scalable targets without an object storage backend »).
- Le ServiceMonitor porte le label `release: kube-prometheus-stack`, sinon il n'est pas
  sélectionné par le Prometheus du stack.

## Opérations

### Rétention

Deux réglages **indissociables** dans `helm-values.yaml` :
`loki.limits_config.retention_period` (fenêtre interrogeable) et
`loki.compactor.retention_enabled: true` (suppression réelle sur disque). Sans le second, le PVC
grossit sans fin même si les vieilles lignes deviennent invisibles. La valeur est alignée sur la
rétention Prometheus, pour que les deux datasources couvrent la même période quand on corrèle un
incident.

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
les métriques Loki ne sont simplement pas scrapées ; l'ingestion, elle, continue.

### Suppression des données

Le PVC est volontairement conservé si le StatefulSet disparaît
(`enableStatefulSetAutoDeletePVC: false`) : purger l'historique est un geste manuel explicite
(`kubectl -n loki delete pvc …`), pas un effet de bord d'un `prune` ArgoCD.
