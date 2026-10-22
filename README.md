# Homelab gitops

L'intégralité d'un homelab Kubernetes, déclarée en Git et appliquée par ArgoCD. Un seul cluster
Talos, `bleu-kalecgos`, et une règle qui prime sur les autres : **aucune donnée ne rentre dans le
cluster hors GitOps** — cf. [`doc/regles-gitops.md`](doc/regles-gitops.md).

Le dépôt de référence est **GitHub**, en dépôt **privé** :
`https://github.com/jbwittner/homelab_gitops`. C'est la source que lit ArgoCD : toutes les
`repoURL` de `k8s/` y pointent, et `argocd-repo-server` s'y authentifie sous l'identité d'une
**GitHub App** en lecture seule (cf. [`k8s/infra/argocd/README.md`](k8s/infra/argocd/README.md)
§Accès au dépôt privé). Les mises à jour de dépendances sont proposées par le bot Renovate du cluster, authentifié lui aussi
en GitHub App (cf. [`k8s/app/renovate/README.md`](k8s/app/renovate/README.md)).

⚠️ **GitHub est un prérequis du GitOps au même titre que le kubeconfig.** Une panne côté GitHub, ou
la désinstallation de l'App, ne casse rien de ce qui tourne mais gèle toute réconciliation : les
Applications passent en `ComparisonError`, `argocd` compris.

## Par où commencer

| Vous voulez… | Allez voir |
|---|---|
| comprendre les règles du dépôt | [`doc/regles-gitops.md`](doc/regles-gitops.md) |
| ajouter ou modifier un composant | [`doc/conventions.md`](doc/conventions.md) |
| exposer un service, ou comprendre un 404 | [`doc/reseau.md`](doc/reseau.md) |
| reconstruire le cluster à froid | [`doc/runbook-bootstrap.md`](doc/runbook-bootstrap.md) |
| lancer un outil (sauvegarde, restauration, inspection) | [`script/README.md`](script/README.md) |

## L'arbre

```
k8s/
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

**Infrastructure** — `k8s/infra/`

| Composant | Wave | Rôle |
|---|---|---|
| [gateway-api](k8s/infra/gateway-api/README.md) | -10 | CRDs Gateway API et le `Gateway` partagé `shared-gw` |
| [sealed-secrets](k8s/infra/sealed-secrets/README.md) | -8 | déchiffrement des secrets — **seul canal actif** |
| [cert-manager](k8s/infra/cert-manager/README.md) | -5 | TLS Let's Encrypt par DNS-01 Cloudflare, les trois wildcards |
| [argocd](k8s/infra/argocd/README.md) | -1 | le moteur GitOps, self-managed |
| [cilium](k8s/infra/cilium/README.md) | 0 | CNI, LB-IPAM et L2, implémentation Gateway API |
| [openebs](k8s/infra/openebs/README.md) | 0 | stockage local LVM, `openebs-lvm-thin` |
| [velero](k8s/infra/velero/README.md) | 1 | sauvegarde vers GCS — schedule quotidienne, périmètre `hermes` |
| [openebs-monitoring](k8s/infra/openebs-monitoring/README.md) | 2 | alertes de remplissage des volumes |
| [velero-monitoring](k8s/infra/velero-monitoring/README.md) | 2 | 8 alertes sur la chaîne de sauvegarde, dont les 2 de fraîcheur rétablies le 2026-09-23 |

*Non déployés :*
- [external-secrets](k8s/infra/external-secrets/README.md) (`.noapp.yaml`) — le backend de
  secrets qu'il desservait a été retiré du dépôt.

**Applications** — `k8s/app/`

| Composant | Wave | Rôle |
|---|---|---|
| [cnpg](k8s/app/cnpg/README.md) | 0 | opérateur PostgreSQL — aucune base déclarée actuellement |
| [kube-prometheus-stack](k8s/app/kube-prometheus-stack/README.md) | 0 | Prometheus, Alertmanager, Grafana et ses dashboards |
| [hermes](k8s/app/hermes/README.md) | 0 | agent LLM en mode gateway |
| [bankwiz](k8s/app/bankwiz/README.md) | 0 | API bankwiz, environnement `dev` (branche `develop`) |
| [donetick](k8s/app/donetick/README.md) | 0 | gestionnaire de tâches et de corvées personnel, SQLite sur PVC — ⚠️ **inerte** tant que son `SealedSecret` `donetick-env` n'est pas scellé |
| [renovate](k8s/app/renovate/README.md) | 0 | mises à jour de dépendances |
| [cnpg-monitoring](k8s/app/cnpg-monitoring/README.md) | 2 | archivage WAL — ⚠️ les 3 règles de **sauvegarde** sont commentées (plus de plugin barman) |
| [hosts-monitoring](k8s/app/hosts-monitoring/README.md) | 2 | les **machines** hors cluster (disque, mémoire, conteneurs) |

*Non déployés :*
- [stress-test](k8s/app/stress-test/README.md) (`.noapp.yaml`, **2026-09-28**) — instrument de
  mesure, pas un service : charge volontairement **un** nœud pour trouver son plafond thermique et
  vérifier que `MachineSensorNearCritical` sonne pour de vrai. ⚠️ Les trois nœuds sont
  control-plane **sans taint** et le quorum etcd est de 2 sur 3 : charger deux nœuds à la fois met
  le cluster en **lecture seule**. Son état normal est `.noapp.yaml`, et le renommage est le seul
  interrupteur — un test de charge doit être un commit, pas une commande.
- [cnpg-barman-plugin](k8s/app/cnpg-barman-plugin/README.md) (`.noapp.yaml`, **2026-09-11**) —
  entièrement orphelin : zéro `Cluster` CNPG et zéro `ObjectStore` depuis le 2026-09-11.
  ⚠️ Les trois règles `CNPG*Backup*` de [cnpg-monitoring](k8s/app/cnpg-monitoring/README.md)
  sont commentées en conséquence — laissées actives elles seraient **vertes en permanence**, ce qui
  laisserait croire que les sauvegardes PostgreSQL sont surveillées alors qu'il n'y en a plus.

Les **machines** hors cluster sont surveillées par un composant distinct,
[hosts-monitoring](k8s/app/hosts-monitoring/README.md) — séparé volontairement de toute
supervision applicative : une machine précède le service qu'elle héberge et lui survit, la ranger
avec lui ferait disparaître sa supervision au `prune` du jour où on retire le service.

⚠️ Les waves n'ordonnent **qu'à l'intérieur d'un même app-of-apps** : `infra` et `app` sont deux
Applications sœurs, synchronisées en parallèle.

## Ce qui ne se reconstruit pas depuis Git

Deux choses, et elles se cumulent :

1. **La clé privée du contrôleur sealed-secrets.** Sans elle, les douze `SealedSecret` de `k8s/` sont
   des fichiers morts — accès au dépôt compris, donc ArgoCD lui-même. La rotation automatique est
   coupée : une seule clé, à sauvegarder hors ligne.
2. **La clé de compte de service GCP** du bucket de sauvegarde velero. Scellée ici, donc protégée
   par (1) — mais une clé perdue oblige à en réémettre une, pas à la récupérer.

En reprise, **la clé sealed-secrets se restaure avant toute tentative de restauration velero ou
barman** : sans elle, aucune sauvegarde n'est lisible.

## Sauvegardes

| Quoi | Par | État |
|---|---|---|
| namespace `hermes` (PVC `/opt/data`) | velero + kopia | schedule `daily`, 03:00 UTC, TTL 30 j — **seul périmètre** depuis le 2026-09-23 |
| bases PostgreSQL | cnpg-barman-plugin | **aucune base dans le cluster** depuis le 2026-09-11 ; plugin en `.noapp.yaml` |

⚠️ **La liste blanche de velero est la seule chose qui décide.** Un composant ajouté au cluster
n'est pas sauvegardé tant que son namespace n'est pas dans `includedNamespaces`, et rien ne le
signale (cf. [velero](k8s/infra/velero/README.md)).

⚠️ Les trois règles `CNPG*Backup*` sont **commentées** — actives sans base, elles seraient vertes en
permanence. Elles se remettent avec la première base recréée
(cf. [cnpg-monitoring](k8s/app/cnpg-monitoring/README.md)).

## Conventions de documentation

- Un README de composant décrit **ce que le composant est** et pourquoi il est réglé ainsi ; les
  procédures multi-étapes vont dans `doc/`, les outils dans `script/`.
- **Aucune version épinglée dans un README** : elle vit dans le `targetRevision` du
  `.app.yaml`, à un seul endroit.
- Toute commande de la documentation s'exécute **depuis la racine du dépôt**, telle quelle.