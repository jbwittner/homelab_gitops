# test-nginx

## Rôle

Composant **jetable de smoke-test** : valide bout à bout la stack après bootstrap/upgrade.
Aucune donnée persistée — supprimable/reconstructible à tout moment. Trois tests (ns
`test-nginx`) : **nginx** (exposition), **lvm-test** (PVC `openebs-lvm-thin`),
**cluster-example** (`Cluster` CNPG).

## Fichiers

- `test-nginx.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/kustomization.yaml` — force `namespace: test-nginx` sur toutes les ressources
- `manifests/namespace.yaml`, `manifests/test-nginx.yaml`, `manifests/test-pvc.yaml`,
  `manifests/pgsql-test.yaml`

## Opérations

- **Vérifier** : `kubectl -n test-nginx get pods,pvc,clusters.postgresql.cnpg.io` —
  tout `Running`/`Bound`/`Cluster in healthy state`.
- **Réinitialiser un test** : supprimer la ressource du manifeste, commit, push (prune), puis la
  remettre — jamais de `kubectl delete` manuel.
