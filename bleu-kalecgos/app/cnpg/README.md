# cnpg

## Rôle

Opérateur **CloudNativePG** : gestion déclarative de clusters PostgreSQL (CRD
`postgresql.cnpg.io/Cluster`). Ne déploie **que l'opérateur** ; les instances PostgreSQL sont
déclarées par les applications consommatrices (ex. [`test-nginx`](../test-nginx/README.md)).

## Fichiers

- `cnpg.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cnpg-system`
- `helm-values.yaml` — `replicaCount: 1` (mono-nœud)

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cnpg.app.yaml`, commit, push.
- **Créer une base** : déclarer un `Cluster` dans le dossier de l'app consommatrice (jamais ici).
- **Debug** : `kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg`,
  `kubectl get clusters.postgresql.cnpg.io -A`.
