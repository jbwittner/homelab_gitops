# bleu-arcanagos

Cluster **en construction**, piloté en **spoke** : il n'a pas d'ArgoCD à lui, c'est celui de
[bleu-kalecgos](../bleu-kalecgos/README.md) qui le réconcilie à distance, via le
`ServiceAccount` `argocd-manager`. Tous les `.app.yaml` d'ici ciblent donc
`destination.name: bleu-arcanagos`, jamais `https://kubernetes.default.svc`.

Reconstruire le cluster : [doc/runbook-bootstrap.md](../doc/runbook-bootstrap.md) (procédure
générique) + [doc/clusters/bleu-arcanagos.md](../doc/clusters/bleu-arcanagos.md) (valeurs de ce
cluster, et ce qui manque encore).

## Infra

- [argocd-manager](infra/argocd-manager/README.md) — identité `cluster-admin` avec laquelle le
  hub pilote ce cluster (SA + binding + token non expirant)
- [cilium](infra/cilium/README.md) — CNI, Gateway API, LoadBalancer L2

## App

Aucun composant applicatif à ce jour.

## Fichiers de ce niveau

> [!WARNING]
> **Pas encore de `cluster.yaml` (tier-1) ni de `infra/infra.bootstrap.yaml` (tier-2)** : aucun
> manifeste de ce cluster n'est découvert par ArgoCD aujourd'hui. Les composants ci-dessus
> existent dans Git mais ne sont réconciliés par personne — cf. la
> [fiche cluster](../doc/clusters/bleu-arcanagos.md).
