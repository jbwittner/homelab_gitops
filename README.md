# Homelab gitops

L'intégralité d'un homelab Kubernetes, déclarée en Git et appliquée par ArgoCD. Un seul cluster
Talos, `bleu-kalecgos`, et une règle qui prime sur les autres : **aucune donnée ne rentre dans le
cluster hors GitOps** — cf. [`doc/regles-gitops.md`](doc/regles-gitops.md).

Le dépôt de référence est la forge auto-hébergée
(`https://forgejo.wittner.tech/jbwittner/homelab_gitops`), **miroitée sur un dépôt GitHub privé**.
C'est aussi la source que lit ArgoCD : les 32 `repoURL` de `cluster/` y pointent, et
`argocd-repo-server` s'y authentifie avec un jeton `read:repository` (cf.
[`cluster/infra/argocd/README.md`](cluster/infra/argocd/README.md) §Accès au dépôt privé).

**La forge tourne hors du cluster**, en Docker sur une machine dédiée, et ce n'est pas un choix
d'hébergement : tant qu'elle était un composant `cluster/app/`, en faire la source du GitOps aurait
donné une dépendance circulaire — ArgoCD lisant un dépôt servi par un composant qu'ArgoCD déploie,
et un cluster à froid sans plus aucune source. Cf.
[`doc/forgejo-docker-bascule-et-sauvegarde.md`](doc/forgejo-docker-bascule-et-sauvegarde.md).

Le miroir GitHub reste la copie hors site qui survit à la perte de la machine de la forge — c'est
depuis lui qu'on repart alors, au prix d'une réécriture des `repoURL`
(cf. [`doc/runbook-bootstrap.md`](doc/runbook-bootstrap.md) §Source de vérité).

Le miroir est en **lecture seule** : on pousse sur la forge, jamais sur GitHub. Si un jour une
divergence apparaît, la forge fait foi. Renovate le sait : le bot GitHub ne scanne plus
`homelab_gitops` : c'est au bot Forgejo de s'en charger — ⚠️ **il n'est pas encore déployé**, sa
ligne attend son `SealedSecret` (cf.
[`cluster/app/renovate/README.md`](cluster/app/renovate/README.md)). D'ici là, **rien** ne propose
de mise à jour de dépendances sur ce dépôt.

## Par où commencer

| Vous voulez… | Allez voir |
|---|---|
| comprendre les règles du dépôt | [`doc/regles-gitops.md`](doc/regles-gitops.md) |
| ajouter ou modifier un composant | [`doc/conventions.md`](doc/conventions.md) |
| exposer un service, ou comprendre un 404 | [`doc/reseau.md`](doc/reseau.md) |
| reconstruire le cluster à froid | [`doc/runbook-bootstrap.md`](doc/runbook-bootstrap.md) |
| restaurer la forge après un sinistre | [`doc/forgejo-docker-bascule-et-sauvegarde.md`](doc/forgejo-docker-bascule-et-sauvegarde.md) §B (la forge est hors du cluster ; [`doc/forgejo-pra.md`](doc/forgejo-pra.md) décrit l'ancien montage) |
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
| [kubevirt](cluster/infra/kubevirt/README.md) | 1 | hyperviseur (KubeVirt + CDI) — **un seul consommateur**, `forgejo-pra` |
| [openebs-monitoring](cluster/infra/openebs-monitoring/README.md) | 2 | alertes de remplissage des volumes |

*Non déployés :*
- [external-secrets](cluster/infra/external-secrets/README.md) (`.noapp.yaml`) — le backend de
  secrets qu'il desservait a été retiré du dépôt.
- [velero](cluster/infra/velero/README.md) et
  [velero-monitoring](cluster/infra/velero-monitoring/README.md) (`.noapp.yaml`, **2026-09-11**) —
  la forge était le seul périmètre de la schedule ; elle a quitté le cluster. Au retrait :
  **zéro `Backup`, zéro `Schedule`**, et deux alertes déjà `firing` faute de bucket joignable.
  ⚠️ Les deux partent **ensemble** : velero seul deviendrait un service non surveillé,
  velero-monitoring seul ferait sonner `VeleroDown` en permanence.

**Applications** — `cluster/app/`

| Composant | Wave | Rôle |
|---|---|---|
| [cnpg](cluster/app/cnpg/README.md) | 0 | opérateur PostgreSQL — ⚠️ **plus aucune base** depuis le départ de la forge |
| [kube-prometheus-stack](cluster/app/kube-prometheus-stack/README.md) | 0 | Prometheus, Alertmanager, Grafana et ses dashboards |
| [hermes](cluster/app/hermes/README.md) | 0 | agent LLM en mode gateway |
| [renovate](cluster/app/renovate/README.md) | 0 | mises à jour de dépendances |
| [forgejo-runner](cluster/app/forgejo-runner/README.md) | 0 | Forgejo Actions — ⚠️ **inerte** tant que son `SealedSecret` d'enregistrement n'est pas scellé |
| [forgejo-pra](cluster/app/forgejo-pra/README.md) | 0 | VM d'**exercice** du PRA de la forge — éteinte par défaut, jamais un standby |
| [cnpg-monitoring](cluster/app/cnpg-monitoring/README.md) | 2 | archivage WAL — ⚠️ les 3 règles de **sauvegarde** sont commentées (plus de plugin barman) |
| [forgejo-monitoring](cluster/app/forgejo-monitoring/README.md) | 2 | la forge et sa base, scrapées **hors du cluster** — 9 alertes |
| [hosts-monitoring](cluster/app/hosts-monitoring/README.md) | 2 | les **machines** hors cluster (disque, mémoire, collecteur textfile) — 6 alertes |

*Non déployés :*
- [cnpg-barman-plugin](cluster/app/cnpg-barman-plugin/README.md) (`.noapp.yaml`, **2026-09-11**) —
  entièrement orphelin : zéro `Cluster` CNPG et zéro `ObjectStore` depuis le départ de la forge.
  ⚠️ Les trois règles `CNPG*Backup*` de [cnpg-monitoring](cluster/app/cnpg-monitoring/README.md)
  sont commentées en conséquence — laissées actives elles seraient **vertes en permanence**, ce qui
  laisserait croire que les sauvegardes PostgreSQL sont surveillées alors qu'il n'y en a plus.
- [forgejo](archive/forgejo/README.md) (`.noapp.yaml`, archivé le 2026-09-11) — la
forge a quitté le cluster pour une machine Docker dédiée. Ce qu'il en reste ici est
`forgejo-monitoring`, qui scrape depuis l'extérieur son `/metrics` et sa **base**.

La **machine** qui la porte, elle, est surveillée par un composant distinct,
[hosts-monitoring](cluster/app/hosts-monitoring/README.md) — séparé volontairement : une machine
précède le service qu'elle héberge et lui survit, la mettre avec la forge ferait disparaître sa
supervision au `prune` du jour où on retire la forge. Les deux volets datent du 2026-09-11, la
bascule ayant supprimé sans les remplacer le node-exporter du cluster et les métriques CNPG.

⚠️ Les waves n'ordonnent **qu'à l'intérieur d'un même app-of-apps** : `infra` et `app` sont deux
Applications sœurs, synchronisées en parallèle.

## Ce qui ne se reconstruit pas depuis Git

Deux choses, et elles se cumulent :

1. **La clé privée du contrôleur sealed-secrets.** Sans elle, les neuf `SealedSecret` du dépôt sont
   des fichiers morts — accès au dépôt compris, donc ArgoCD lui-même. La rotation automatique est
   coupée : une seule clé, à sauvegarder hors ligne.
2. **La clé de compte de service GCP** du bucket de sauvegarde velero. Scellée ici, donc protégée
   par (1) — mais une clé perdue oblige à en réémettre une, pas à la récupérer. (Celle du bucket
   CNPG est partie avec la forge : `archive/forgejo`.)

En reprise, **la clé sealed-secrets se restaure avant toute tentative de restauration velero ou
barman** : sans elle, aucune sauvegarde n'est lisible.

## Sauvegardes

⚠️ **CE CLUSTER NE SAUVEGARDE PLUS RIEN depuis le 2026-09-11**, et c'est un état voulu, pas une
panne. Les deux chaînes n'avaient qu'un seul objet — la forge — et elle est partie :

| Quoi | Par | État |
|---|---|---|
| namespace `forgejo` (PVC applicatif) | velero + kopia | **schedule désactivée** ; `includedNamespaces` vide. Les backups existants restent restaurables jusqu'à expiration de leur TTL (30 j) |
| base `forgejo-db` (base + WAL continu) | cnpg-barman-plugin | **plus aucune base dans le cluster** ; le plugin et la CRD `ObjectStore` restent en place pour la prochaine |

La sauvegarde de la forge se joue désormais **sur sa machine Docker** : §B de
[`doc/forgejo-docker-bascule-et-sauvegarde.md`](doc/forgejo-docker-bascule-et-sauvegarde.md).
⚠️ Corollaire à ne pas perdre de vue : les alertes qui signalaient une chaîne morte
(`VeleroBackupTooOld`, `VeleroNoBackupMetric`, `CNPGBackupChainAbsent`, `CNPGMetricsAbsent`) sont
**commentées** — elles sonneraient sans fin. Elles se remettent avec le premier namespace remis
sous velero, ou la première base recréée.

Le plan de reprise de la forge et son exercice, écrits du temps où elle vivait dans le cluster,
restent dans [`doc/forgejo-pra.md`](doc/forgejo-pra.md) et
[`doc/forgejo-pra-exercice.md`](doc/forgejo-pra-exercice.md).

## Conventions de documentation

- Un README de composant décrit **ce que le composant est** et pourquoi il est réglé ainsi ; les
  procédures multi-étapes vont dans `doc/`, les outils dans `script/`.
- **Aucune version épinglée dans un README** : elle vit dans le `targetRevision` du
  `.app.yaml`, à un seul endroit.
- Toute commande de la documentation s'exécute **depuis la racine du dépôt**, telle quelle.
