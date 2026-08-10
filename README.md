# homelab_gitops

Dépôt GitOps du homelab. Un cluster actif — **bleu-kalecgos** (mono-nœud `vert-eranikus`) — et un
cluster en cours de construction, **bleu-arcanagos**. Chacun est piloté intégralement par
**ArgoCD** en app-of-apps.

> **Règle non négociable** : aucune donnée n'est poussée au cluster hors GitOps —
> [doc/regles-gitops.md](doc/regles-gitops.md).

> **Commandes** : toute commande de cette documentation se lance **depuis la racine du clone**,
> telle quelle, sans `cd` préalable.

## Structure

```
homelab_gitops/
├── bleu-kalecgos/    # cluster actif (app-of-apps) — infra/ + app/
├── bleu-arcanagos/   # cluster en construction (spoke) — app-of-apps prête, hub pas encore branché
├── doc/              # règles, conventions, runbook
│   └── clusters/     # une fiche par cluster (valeurs : réseau, disque, secrets)
├── renovate.json     # politique de mise à jour des dépendances (cooldown 7 j, automerge)
├── .claude/skills/   # skills projet
└── archive/          # anciens clusters, hors périmètre actif
```

## Clusters

- [bleu-kalecgos](bleu-kalecgos/README.md) — cluster actif et **hub** ArgoCD (liste des
  composants déployés) — [fiche](doc/clusters/bleu-kalecgos.md)
- [bleu-arcanagos](bleu-arcanagos/README.md) — en construction, **spoke** piloté par l'ArgoCD du
  hub ; chaîne app-of-apps en place, reste à enregistrer le cluster dans le hub —
  [fiche](doc/clusters/bleu-arcanagos.md)

## Documentation

- [doc/regles-gitops.md](doc/regles-gitops.md) — règles GitOps (kubectl, secrets, gestes
  impératifs assumés)
- [doc/conventions.md](doc/conventions.md) — layout des composants, naming, archétypes,
  sync-waves, pattern `helm-values`, convention des secrets
- [doc/reseau.md](doc/reseau.md) — exposition réseau (Gateway API, `shared-gw`, listeners, TLS)
- [doc/runbook-bootstrap.md](doc/runbook-bootstrap.md) — bootstrap / disaster recovery complet,
  depuis un cluster vierge sans CNI — **procédure générique, tous clusters**
- [doc/clusters/](doc/clusters/) — une fiche par cluster : les valeurs que le runbook
  paramètre (nœud, pool L2, wildcard DNS, disque, inventaire des SealedSecrets)
- [.claude/skills/README.md](.claude/skills/README.md) — skills projet (dont vérification des règles)

## Bootstrap / disaster recovery

Le [runbook](doc/runbook-bootstrap.md) part d'un **cluster Kubernetes vierge, sans CNI** et va
jusqu'à la stack complète. Trois gestes manuels seulement (Cilium, `apply -k` d'ArgoCD,
restauration de la clé sealed-secrets) ; tout le reste converge par sync-waves. Un cluster
**spoke** en fait deux : Cilium, puis la pose du `ServiceAccount` `argocd-manager` — il
n'installe pas d'ArgoCD, celui du hub le pilote. La procédure est générique : le cluster visé se
choisit via `export CLUSTER=…`, ses valeurs vivent dans [doc/clusters/](doc/clusters/).

> [!CAUTION]
> Le seul élément **non reconstructible** depuis ce dépôt est la **clé privée sealed-secrets**.
> Sans son backup (coffre, hors cluster, hors Git), tous les `SealedSecret` committés sont morts
> et il faut re-provisionner chaque credential amont. C'est un prérequis du runbook.
