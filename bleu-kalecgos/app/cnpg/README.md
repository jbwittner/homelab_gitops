# cnpg — bleu-kalecgos

## Rôle

Opérateur **CloudNativePG** : gestion déclarative de clusters PostgreSQL (CRD
`postgresql.cnpg.io/Cluster`). Ce composant ne déploie **que l'opérateur** ; les instances
PostgreSQL sont déclarées par les applications consommatrices (ex. le `Cluster` de test dans
[`test-nginx`](../test-nginx/README.md)).

## Source & versions

| Quoi | Valeur |
|---|---|
| Chart | `cloudnative-pg` — https://cloudnative-pg.github.io/charts |
| Version épinglée | `0.29.0` |
| Namespace | `cnpg-system` (CreateNamespace) |
| Release Helm | `cnpg` |
| Archétype | (a) Helm + `$values` |

## Fichiers

- `cnpg.app.yaml` — Application multi-source
- `helm-values.yaml` — `replicaCount: 1` (mono-nœud)

## Dépendances & sync-wave

Wave 0. Dépend de : `openebs` (les `Cluster` provisionnent leurs PVC sur `openebs-lvm-thin`).
Requis par : toute app déclarant un `Cluster` CNPG.

## Opérations courantes

- **Upgrade** : bumper `targetRevision` dans `cnpg.app.yaml`, commit, push.
- **Créer une base** : déclarer un `Cluster` dans le dossier de l'app consommatrice (jamais ici).
- **Debug** : `kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg`,
  `kubectl get clusters.postgresql.cnpg.io -A`.
