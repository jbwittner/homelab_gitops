# homelab_gitops

L'intégralité d'un homelab Kubernetes, déclarée en Git et appliquée par ArgoCD. Un seul cluster
Talos, `bleu-kalecgos`, et une règle qui prime sur les autres : **aucune donnée ne rentre dans le
cluster hors GitOps** — cf. [`doc/regles-gitops.md`](doc/regles-gitops.md).

## Par où commencer

| Vous voulez… | Allez voir |
|---|---|
| comprendre les règles du dépôt | [`doc/regles-gitops.md`](doc/regles-gitops.md) |
| ajouter ou modifier un composant | [`doc/conventions.md`](doc/conventions.md) |
| exposer un service, ou comprendre un 404 | [`doc/reseau.md`](doc/reseau.md) |
| reconstruire le cluster à froid | [`doc/runbook-bootstrap.md`](doc/runbook-bootstrap.md) |
| restaurer la forge après un sinistre | [`doc/forgejo-pra.md`](doc/forgejo-pra.md) |
| lancer un outil (sauvegarde, restauration, exercice) | [`script/README.md`](script/README.md) |

## L'arbre

```
cluster/
├── root.yaml                 TIER 1 — apply manuel, une seule fois
├── infra/
│   ├── infra.bootstrap.yaml  TIER 2 — glob {*.app.yaml,*.appset.yaml}
│   └── <composant>/
└── app/
    ├── app.bootstrap.yaml    TIER 2 — idem
    └── <composant>/
doc/                          règles, conventions, réseau, runbooks
script/                       les outils, tous ici et nulle part ailleurs
archive/                      composants retirés du déploiement, conservés pour mémoire
```

⚠️ **Le suffixe fait tout.** Un composant en `*.app.yaml` est déployé ; en `*.noapp.yaml` il est
invisible pour le tier-2 — et **rien ne le signale**. C'est l'état voulu pour `external-secrets` et
pour tout ce qui est dans `archive/`.

## Composants déployés

**Infrastructure** — `cluster/infra/`

| Composant | Wave | Rôle |
|---|---|---|
| [gateway-api](cluster/infra/gateway-api/README.md) | -10 | CRDs Gateway API et le `Gateway` partagé `shared-gw` |
| [sealed-secrets](cluster/infra/sealed-secrets/README.md) | -8 | déchiffrement des secrets — **seul canal actif** |
| [cert-manager](cluster/infra/cert-manager/README.md) | -5 | TLS Let's Encrypt par DNS-01 Cloudflare, les deux wildcards |
| [argocd](cluster/infra/argocd/README.md) | -1 | le moteur GitOps, self-managed |
| [cilium](cluster/infra/cilium/README.md) | 0 | CNI, LB-IPAM et L2, implémentation Gateway API |
| [openebs](cluster/infra/openebs/README.md) | 0 | stockage local LVM, `openebs-lvm-thin` |
| [velero](cluster/infra/velero/README.md) | 1 | sauvegarde de namespaces vers GCS |
| [openebs-monitoring](cluster/infra/openebs-monitoring/README.md) | 2 | alertes de remplissage des volumes |
| [velero-monitoring](cluster/infra/velero-monitoring/README.md) | 2 | alertes sur les sauvegardes |

*Non déployé :* [external-secrets](cluster/infra/external-secrets/README.md) (`.noapp.yaml`) — le
backend de secrets qu'il desservait a été retiré du dépôt.

**Applications** — `cluster/app/`

| Composant | Wave | Rôle |
|---|---|---|
| [cnpg-barman-plugin](cluster/app/cnpg-barman-plugin/README.md) | -1 | archivage WAL vers un objectstore, pour CNPG |
| [cnpg](cluster/app/cnpg/README.md) | 0 | opérateur PostgreSQL |
| [kube-prometheus-stack](cluster/app/kube-prometheus-stack/README.md) | 0 | Prometheus, Alertmanager, Grafana et ses dashboards |
| [forgejo](cluster/app/forgejo/README.md) | 0 | la forge, seul service **public** |
| [hermes](cluster/app/hermes/README.md) | 0 | agent LLM en mode gateway |
| [renovate](cluster/app/renovate/README.md) | 0 | mises à jour de dépendances |
| [cnpg-monitoring](cluster/app/cnpg-monitoring/README.md) | 2 | alertes sur la chaîne de sauvegarde PostgreSQL |
| [forgejo-monitoring](cluster/app/forgejo-monitoring/README.md) | 2 | alertes de disponibilité de la forge |

⚠️ Les waves n'ordonnent **qu'à l'intérieur d'un même app-of-apps** : `infra` et `app` sont deux
Applications sœurs, synchronisées en parallèle.

## Ce qui ne se reconstruit pas depuis Git

Deux choses, et elles se cumulent :

1. **La clé privée du contrôleur sealed-secrets.** Sans elle, les onze `SealedSecret` du dépôt sont
   des fichiers morts — accès au dépôt compris, donc ArgoCD lui-même. La rotation automatique est
   coupée : une seule clé, à sauvegarder hors ligne.
2. **Les clés de compte de service GCP** des deux buckets de sauvegarde. Scellées ici, donc
   protégées par (1) — mais une clé perdue oblige à en réémettre, pas à les récupérer.

En reprise, **la clé sealed-secrets se restaure avant toute tentative de restauration velero ou
barman** : sans elle, aucune sauvegarde n'est lisible.

## Sauvegardes

| Quoi | Par | Vers | Cadence |
|---|---|---|---|
| namespace `forgejo` (PVC applicatif) | velero + kopia | `gs://homelab-velero-backups-…` | 03:00 UTC, rétention 30 j |
| base `forgejo-db` (base + WAL continu) | cnpg-barman-plugin | `gs://homelab-cnpg-backups-…/forgejo/` | 02:00 UTC, rétention 30 j |

L'ordre est load-bearing : la base à 02:00 **avant** le PVC à 03:00. Le plan de reprise et son
exercice sont dans [`doc/forgejo-pra.md`](doc/forgejo-pra.md) et
[`doc/forgejo-pra-exercice.md`](doc/forgejo-pra-exercice.md).

## Conventions de documentation

- Un README de composant décrit **ce que le composant est** et pourquoi il est réglé ainsi ; les
  procédures multi-étapes vont dans `doc/`, les outils dans `script/`.
- **Aucune version épinglée dans un README** : elle vit dans le `targetRevision` du
  `.app.yaml`, à un seul endroit.
- Toute commande de la documentation s'exécute **depuis la racine du dépôt**, telle quelle.
