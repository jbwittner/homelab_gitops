# test-nginx

## Rôle

Composant **jetable de smoke-test** : valide bout à bout le socle après un bootstrap ou un
upgrade. Aucune donnée à conserver — supprimable et reconstructible à tout moment. Trois tests
dans le ns `test-nginx` :

- **nginx** — le workload tourne et se joint ;
- **lvm-test** — un PVC sur `openebs-lvm-thin` est provisionné et monté
  ([openebs](../../infra/openebs/README.md)) ;
- **cluster-example** — un `Cluster` CNPG démarre ([cnpg](../cnpg/README.md)).

## Fichiers

- `test-nginx.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/kustomization.yaml` — force `namespace: test-nginx` sur toutes les ressources
- `manifests/namespace.yaml`, `manifests/test-nginx.yaml`, `manifests/test-pvc.yaml`,
  `manifests/pgsql-test.yaml`

## Contraintes

- Rien de ce qui vit ici ne doit être considéré comme durable : un `prune` ArgoCD sur ce
  composant est sans conséquence, c'est même sa raison d'être.
- Le PVC exerce volontairement le chemin `WaitForFirstConsumer` : le voir `Pending` **sans pod**
  n'est pas un échec du test.

## Opérations

- **Vérifier** :
  ```bash
  kubectl -n test-nginx get pods,pvc,clusters.postgresql.cnpg.io
  ```
  Attendu : pods `Running`, PVC `Bound`, Cluster « in healthy state ».
- **Réinitialiser un test** : retirer la ressource du manifeste, commit, push (le prune la
  supprime), puis la remettre — jamais de `kubectl delete` manuel
  ([doc/regles-gitops.md](../../../doc/regles-gitops.md)).
