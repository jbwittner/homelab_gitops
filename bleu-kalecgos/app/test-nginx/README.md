# test-nginx — bleu-kalecgos

## Rôle

Composant **jetable de smoke-test** : valide bout à bout la stack après bootstrap/upgrade.
Aucune donnée persistée volontairement — supprimable/reconstructible à tout moment.

Trois tests dans le namespace `test-nginx` :
- **nginx** (Deployment + Service) — cible pour tester une exposition HTTPRoute ;
- **lvm-test** (PVC `openebs-lvm-thin` + pod busybox) — valide le provisionnement LVM ;
- **cluster-example** (`Cluster` CNPG 1 instance) — valide l'opérateur CNPG + stockage.

## Source & versions

| Quoi | Valeur |
|---|---|
| Manifestes | locaux (`manifests/`) |
| Namespace | `test-nginx` (porté par `manifests/namespace.yaml`) |
| Archétype | (c) kustomize seul |

## Fichiers

- `test-nginx.app.yaml` — Application (path → `manifests/`)
- `manifests/kustomization.yaml` — force `namespace: test-nginx` sur toutes les ressources
- `manifests/namespace.yaml`, `manifests/test-nginx.yaml`, `manifests/test-pvc.yaml`,
  `manifests/pgsql-test.yaml`

## Dépendances & sync-wave

Wave 0. Dépend de : `openebs` (PVC), `cnpg` (CRD Cluster), `gateway-api`/`cilium` si on ajoute
une HTTPRoute de test.

## Opérations courantes

- **Vérifier** : `kubectl -n test-nginx get pods,pvc,clusters.postgresql.cnpg.io` —
  tout `Running`/`Bound`/`Cluster in healthy state`.
- **Réinitialiser un test** : supprimer la ressource du manifeste, commit, push (prune), puis la
  remettre — jamais de `kubectl delete` manuel.
