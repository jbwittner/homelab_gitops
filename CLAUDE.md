# homelab_gitops — instructions projet

## Règle GitOps — NON négociable

**Interdit de pousser des données au cluster hors GitOps.** Toute ressource vit dans Git,
appliquée par **ArgoCD**. `kubectl` en écriture = bootstrap ArgoCD + debug read-only, rien
d'autre. Secrets : jamais en clair, uniquement **SealedSecrets** (`kubeseal`). Une modif =
éditer le manifeste, commit, push. Détail : [doc/regles-gitops.md](doc/regles-gitops.md).

## Un seul arbre, plusieurs clusters

`cluster/` est **l'unique** arbre de déploiement — il n'y a plus un dossier par cluster. C'est
chaque composant qui désigne sa cible. `bleu-kalecgos` est le **hub** (seul ArgoCD du repo) ;
`bleu-arcanagos` est un **spoke** piloté à distance.

```
cluster/root.yaml                 # tier 1, appliqué à la main UNE FOIS, sur le hub
├── infra/infra.bootstrap.yaml    # tier 2 → glob {*.app.yaml,*.appset.yaml}
└── app/app.bootstrap.yaml        # tier 2 → idem
```

Tier-1 et tier-2 ciblent **toujours le hub** (ils ne produisent que des `Application`) ; seules
les feuilles portent la vraie `destination`, **toujours `name: <cluster>`, jamais `server:`**.

## Commandes — toujours depuis la racine du projet

Toute commande écrite dans la doc (README, runbook, `doc/`) doit être exécutable **telle
quelle depuis la racine du clone**, sans `cd` préalable : chemins relatifs à la racine
(`cluster/infra/<name>/…`), jamais relatifs au dossier du README. Une commande qui
suppose un `cd` est un bug de documentation.

## Conventions

Règles complètes : [doc/conventions.md](doc/conventions.md). Points critiques :

- Composant **mono-cluster** = `cluster/{infra,app}/<name>/<name>.app.yaml` (`Application`) ;
  composant **multi-cluster** = `<name>.appset.yaml` (`ApplicationSet`) + un sous-dossier
  `<name>/<cluster>/` par cluster et un `<name>/common/` optionnel, exclu du generator.
  Suffixe **exact** `.app.yaml`/`.appset.yaml` requis (glob de découverte),
  `metadata.name` = dossier = préfixe fichier ; les Applications **générées** sont préfixées
  `<cluster>-` et portent le label `homelab.wittner.tech/cluster`.
- Values Helm **jamais inline** : fichier `helm-values.yaml` référencé via le pattern
  multi-source `$values` (exemple dans doc/conventions.md). En multi-cluster, deux couches :
  `common/helm-values.yaml` puis la surcharge du cluster (`ignoreMissingValueFiles`).
- READMEs composants : minimaux, **aucune version épinglée** (source unique :
  `targetRevision` du `.app.yaml`/`.appset.yaml`, ou le `kustomization.yaml` pour un install
  upstream).
- Secrets : template en clair `<name>.secret.yaml` (**gitignoré**) → `kubeseal` →
  `<name>.sealed.yaml` (committé, référencé dans le `kustomization.yaml`).
- Index des composants : [README.md](README.md) racine — mis à jour dans le **même commit**
  qu'un ajout/suppression de composant.

## Exposition réseau

Cilium Gateway API, `Gateway` partagé `shared-gw`. Exposer = `HTTPRoute` → `shared-gw`.
`gateway-api` est aujourd'hui mono-cluster (hub) : exposer depuis un spoke suppose de le migrer
en `ApplicationSet`. Détail : [doc/reseau.md](doc/reseau.md).

## Bootstrap / disaster recovery

[doc/runbook-bootstrap.md](doc/runbook-bootstrap.md) — procédure **générique** (tous clusters,
paramétrée par `export CLUSTER=…`), part d'un cluster vierge **sans CNI**. Les valeurs propres à
un cluster (nœud, pool L2, wildcard DNS, disque, inventaire des SealedSecrets) vivent dans sa
fiche : [doc/clusters/](doc/clusters/) — y ajouter un fichier pour tout nouveau cluster. Le seul
élément non reconstructible depuis Git est la **clé privée sealed-secrets** du hub (elle scelle
aussi les secrets des spokes) : son backup (coffre) est un prérequis du runbook, pas une option.

## Skills projet

Voir [.claude/skills/README.md](.claude/skills/README.md). `/check-regles <dossier>` vérifie
la conformité d'un dossier aux règles de `doc/`.
