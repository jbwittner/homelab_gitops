# test-nginx

> [!IMPORTANT]
> **ARCHIVÉ le 2026-09-08** (commit `8c7d7e4`). Fichier `test-nginx.noapp.yaml` : non déployé.
>
> Composant jetable de smoke-test, sans donnée à conserver — son archivage ne casse rien. Le
> `Cluster` CNPG `pgsql-test` qu'il portait n'existe plus : les README qui le citent encore comme
> base sans chaîne de sauvegarde décrivent un objet disparu.
>
> Conservé parce qu'il reste le moyen le plus court de valider un socle fraîchement amorcé
> (StorageClass, PVC, Gateway, CNPG) — cf. [`doc/runbook-bootstrap.md`](../../doc/runbook-bootstrap.md).


## Rôle

Composant **jetable de smoke-test** : valide bout à bout le socle après un bootstrap ou un
upgrade. Aucune donnée à conserver — supprimable et reconstructible à tout moment. Trois tests
dans le ns `test-nginx` :

- **nginx** — le workload tourne et se joint ;
- **lvm-test** — un PVC sur `openebs-lvm-thin` est provisionné et monté
  ([openebs](../../cluster/infra/openebs/README.md)) ;
- **cluster-example** — un `Cluster` CNPG démarre ([cnpg](../../cluster/app/cnpg/README.md)).

## Fichiers

- `test-nginx.noapp.yaml` — Application (archétype (c), path → `manifests/`)
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
  ([doc/regles-gitops.md](../../doc/regles-gitops.md)).
