# bleu-arcanagos

Cluster **en construction**, piloté en **spoke** : il n'a pas d'ArgoCD à lui, c'est celui de
[bleu-kalecgos](../bleu-kalecgos/README.md) qui le réconcilie à distance, via le
`ServiceAccount` `argocd-manager`. Deux conséquences sur tout composant ajouté ici :

- les `.app.yaml` feuilles ciblent `destination.name: bleu-arcanagos`, jamais
  `bleu-kalecgos` — qui déploierait **sur le hub** ;
- leur `metadata.name` porte le préfixe du cluster (`bleu-arcanagos-cilium`) : toutes les
  Applications des deux clusters cohabitent dans le namespace `argocd` du hub.

Reconstruire le cluster : [doc/runbook-bootstrap.md](../doc/runbook-bootstrap.md) (procédure
générique) + [doc/clusters/bleu-arcanagos.md](../doc/clusters/bleu-arcanagos.md) (valeurs de ce
cluster, et ce qui manque encore).

## Infra

Le socle. L'ordre de déploiement est porté par les sync-waves, pas par cette liste.

- [argocd-manager](infra/argocd-manager/README.md) — identité `cluster-admin` avec laquelle le
  hub pilote ce cluster (SA + binding + token non expirant)
- [cilium](infra/cilium/README.md) — CNI, Gateway API, LoadBalancer L2

## App

Aucun composant applicatif à ce jour — `app/app.bootstrap.yaml` existe et attend le premier.

## Fichiers de ce niveau

- `cluster.yaml` — Application **tier-1**, appliquée à la main **sur le hub** au bootstrap ;
  découvre les `*.bootstrap.yaml`
- `infra/infra.bootstrap.yaml`, `app/app.bootstrap.yaml` — tier-2, découvrent chacun leurs
  `*.app.yaml`

> [!WARNING]
> **Rien n'est encore réconcilié** : le tier-1 ne peut être appliqué qu'une fois le cluster
> enregistré dans le hub (SealedSecret `cluster-bleu-arcanagos`, cf.
> [argocd-manager](infra/argocd-manager/README.md)). Sans lui, les `destination.name:
> bleu-arcanagos` ne résolvent pas et les Applications restent en erreur.
