# cnpg

## Rôle

Opérateur **CloudNativePG** : gestion déclarative de clusters PostgreSQL (CRD
`postgresql.cnpg.io/Cluster`). Ne déploie **que l'opérateur** ; les instances PostgreSQL sont
déclarées par les applications consommatrices — aujourd'hui
[`forgejo`](../forgejo/README.md), [`authentik`](../authentik/README.md) et
[`test-nginx`](../test-nginx/README.md).

## Fichiers

- `cnpg.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cnpg-system`
- `helm-values.yaml` — `replicaCount: 1` (mono-nœud)

## Contraintes

- **Aucun `Cluster` ne se déclare ici.** Une base vit dans le dossier de l'application qui la
  consomme, avec son cycle de vie.
- L'opérateur génère lui-même le service `<cluster>-rw` et le secret `<cluster>-app` (identifiants
  applicatifs) : les consommateurs les référencent par `secretKeyRef`, ils ne sont jamais scellés.

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cnpg.app.yaml`, commit, push.
- **Créer une base** : déclarer un `Cluster` dans le `manifests/` de l'app consommatrice.
- **Debug** :
  ```bash
  kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg
  kubectl get clusters.postgresql.cnpg.io -A
  kubectl -n <ns> describe cluster <name>      # events : bootstrap, failover, backup
  ```
