# homelab_gitops

Dépôt GitOps du homelab. Deux clusters, **un seul ArgoCD** : **bleu-kalecgos** (mono-nœud
`vert-eranikus`) est le **hub** et pilote **bleu-arcanagos**, un **spoke** en cours de
construction. Tout est déployé en app-of-apps depuis un arbre unique, `cluster/`.

> **Règle non négociable** : aucune donnée n'est poussée au cluster hors GitOps —
> [doc/regles-gitops.md](doc/regles-gitops.md).

> **Commandes** : toute commande de cette documentation se lance **depuis la racine du clone**,
> telle quelle, sans `cd` préalable.

## Structure

```
homelab_gitops/
├── cluster/              # arbre de déploiement UNIQUE, tous clusters confondus
│   ├── root.yaml         #   tier 1 — appliqué à la main une fois, sur le hub
│   ├── infra/            #   socle (CNI, GitOps, TLS, réseau, stockage, secrets)
│   └── app/              #   applicatif (observabilité, SSO, base de données, outillage)
├── doc/                  # règles, conventions, runbook
│   └── clusters/         # une fiche par cluster (valeurs : réseau, disque, secrets)
├── renovate.json         # politique de mise à jour des dépendances (cooldown 7 j, automerge)
├── .claude/skills/       # skills projet
└── archive/              # anciens clusters, hors périmètre actif
```

Il n'y a **pas** de dossier par cluster : c'est chaque composant qui désigne sa cible. Un
composant déployé sur plusieurs clusters est un `ApplicationSet` avec un sous-dossier par cluster
(`<name>/<cluster>/`) et un `common/` pour ce qui est partagé. Détail :
[doc/conventions.md](doc/conventions.md).

## Clusters

| Cluster | Rôle | Fiche |
|---|---|---|
| `bleu-kalecgos` | **hub** — héberge l'unique ArgoCD, la clé sealed-secrets et le `Gateway` `shared-gw` | [fiche](doc/clusters/bleu-kalecgos.md) |
| `bleu-arcanagos` | **spoke** — piloté par l'ArgoCD du hub ; enregistré, CNI en place, reste à équiper | [fiche](doc/clusters/bleu-arcanagos.md) |

## Composants

Index unique du repo — un composant ajouté ou supprimé est reflété ici **dans le même commit**.

### `cluster/infra/` — socle

| Composant | Cible(s) | Rôle |
|---|---|---|
| [argocd](cluster/infra/argocd/README.md) | hub | Le contrôleur GitOps lui-même, self-managed (wave -1) |
| [argocd-manager](cluster/infra/argocd-manager/README.md) | spokes (appset) | Identité `cluster-admin` avec laquelle le hub pilote un cluster distant (wave -20) |
| [cilium](cluster/infra/cilium/README.md) | tous (appset) | CNI, remplacement de kube-proxy, Gateway API, LB annoncé en L2 |
| [gateway-api](cluster/infra/gateway-api/README.md) | hub | CRDs Gateway API + le `Gateway` partagé `shared-gw` (wave -10) |
| [sealed-secrets](cluster/infra/sealed-secrets/README.md) | hub | Déchiffre les `SealedSecret` du repo — canal de secrets n°1 (wave -8) |
| [external-secrets](cluster/infra/external-secrets/README.md) | tous (appset) | Tire les secrets d'openbao en `Secret` natifs — canal n°2 (wave -7) |
| [cert-manager](cluster/infra/cert-manager/README.md) | hub | Moteur d'émission TLS (wave -5) |
| [cert-manager-config](cluster/infra/cert-manager-config/README.md) | hub | `ClusterIssuer` Let's Encrypt DNS-01 + certificats wildcard (wave -4) |
| [openebs](cluster/infra/openebs/README.md) | hub | Stockage LocalPV-LVM, StorageClass par défaut du cluster |
| [openbao](cluster/infra/openbao/README.md) | hub | Coffre de secrets (raft intégré) + agent injector — contenu hors Git, descellement manuel (wave 1) |

### `cluster/app/` — applicatif

| Composant | Cible(s) | Rôle |
|---|---|---|
| [authentik](cluster/app/authentik/README.md) | hub | Fournisseur d'identité (SSO OIDC d'ArgoCD et de Grafana) |
| [cnpg](cluster/app/cnpg/README.md) | hub | Opérateur CloudNativePG — les bases des applications |
| [kube-prometheus-stack](cluster/app/kube-prometheus-stack/README.md) | hub | Prometheus, Alertmanager, Grafana, exporters, dashboards maison |
| [loki](cluster/app/loki/README.md) | hub | Stockage et requêtage des logs |
| [alloy](cluster/app/alloy/README.md) | hub | Collecte des logs des pods → Loki |
| [renovate](cluster/app/renovate/README.md) | hub | CronJob de mise à jour des dépendances de ce repo |
| [test-nginx](cluster/app/test-nginx/README.md) | hub | Smoke test permanent : stockage (PVC) + CNPG |

## Documentation

- [doc/regles-gitops.md](doc/regles-gitops.md) — règles GitOps (kubectl, secrets, gestes
  impératifs assumés)
- [doc/conventions.md](doc/conventions.md) — chaîne de découverte, `Application` vs
  `ApplicationSet`, layout des composants, naming, archétypes, sync-waves, pattern `helm-values`,
  convention des secrets
- [doc/reseau.md](doc/reseau.md) — exposition réseau (Gateway API, `shared-gw`, listeners, TLS)
- [doc/secrets.md](doc/secrets.md) — architecture des secrets : les deux canaux, le modèle d'objets
  ESO (`ClusterSecretStore` / `ExternalSecret` / `Secret`), un store par cluster, rotation
- [doc/runbook-bootstrap.md](doc/runbook-bootstrap.md) — bootstrap / disaster recovery complet,
  depuis un cluster vierge sans CNI — **procédure générique, tous clusters**
- [doc/clusters/](doc/clusters/) — une fiche par cluster : les valeurs que le runbook
  paramètre (nœud, pool L2, wildcard DNS, disque, inventaire des SealedSecrets)
- [.claude/skills/README.md](.claude/skills/README.md) — skills projet (dont vérification des règles)

## Bootstrap / disaster recovery

Le [runbook](doc/runbook-bootstrap.md) part d'un **cluster Kubernetes vierge, sans CNI** et va
jusqu'à la stack complète. Trois gestes manuels seulement pour le hub (Cilium, `apply -k`
d'ArgoCD, restauration de la clé sealed-secrets) ; tout le reste converge par sync-waves. Un
cluster **spoke** en fait deux : Cilium, puis la pose du `ServiceAccount` `argocd-manager` — il
n'installe pas d'ArgoCD, celui du hub le pilote. L'`apply -f cluster/root.yaml` du tier-1 est un
geste **unique pour le repo**, pas par cluster. La procédure est générique : le cluster visé se
choisit via `export CLUSTER=…`, ses valeurs vivent dans [doc/clusters/](doc/clusters/).

> [!CAUTION]
> Deux éléments sont **non reconstructibles** depuis ce dépôt, et leur backup (coffre, hors
> cluster, hors Git) est un prérequis du runbook :
>
> 1. La **clé privée sealed-secrets** du hub. Sans elle, tous les `SealedSecret` committés sont
>    morts — y compris le Secret d'enregistrement des clusters spokes — et il faut
>    re-provisionner chaque credential amont.
> 2. Les **clés de descellement d'openbao** et le contenu de son PVC. Le coffre est le seul
>    composant dont les données ne vivent pas dans Git : voir
>    [cluster/infra/openbao](cluster/infra/openbao/README.md) pour les snapshots raft.
