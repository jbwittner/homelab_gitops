# homelab_gitops — instructions projet

## Règle GitOps — NON négociable

**Interdit de pousser des données au cluster hors GitOps.** Toute ressource vit dans Git,
appliquée par **ArgoCD**. `kubectl` en écriture = bootstrap ArgoCD + debug read-only, rien
d'autre. Secrets : jamais en clair, uniquement **SealedSecrets** (`kubeseal`). Une modif =
éditer le manifeste, commit, push. Détail : [doc/regles-gitops.md](doc/regles-gitops.md).

## Commandes — toujours depuis la racine du projet

Toute commande écrite dans la doc (README, runbook, `doc/`) doit être exécutable **telle
quelle depuis la racine du clone**, sans `cd` préalable : chemins relatifs à la racine
(`<cluster>/infra/<name>/…`), jamais relatifs au dossier du README. Une commande qui
suppose un `cd` est un bug de documentation.

## Conventions

Règles complètes : [doc/conventions.md](doc/conventions.md). Points critiques :

- Composant = `<cluster>/{infra,app}/<name>/<name>.app.yaml` — suffixe **exact**
  `.app.yaml` requis (glob de découverte), `metadata.name` = dossier = préfixe fichier.
- Values Helm **jamais inline** : fichier `helm-values.yaml` référencé via le pattern
  multi-source `$values` (exemple dans doc/conventions.md).
- READMEs composants : minimaux, **aucune version épinglée** (source unique :
  `targetRevision` du `.app.yaml`, ou le `kustomization.yaml` pour un install upstream).
- Secrets : template en clair `<name>.secret.yaml` (**gitignoré**) → `kubeseal` →
  `<name>.sealed.yaml` (committé, référencé dans le `kustomization.yaml`).

## Exposition réseau

Cilium Gateway API, `Gateway` partagé `shared-gw`. Exposer = `HTTPRoute` → `shared-gw`.
Détail : [doc/reseau.md](doc/reseau.md).

## Bootstrap / disaster recovery

[doc/runbook-bootstrap.md](doc/runbook-bootstrap.md) — procédure **générique** (tous clusters,
paramétrée par `export CLUSTER=…`), part d'un cluster vierge **sans CNI**. Les valeurs propres à
un cluster (nœud, pool L2, wildcard DNS, disque, inventaire des SealedSecrets) vivent dans sa
fiche : [doc/clusters/](doc/clusters/) — y ajouter un fichier pour tout nouveau cluster. Le seul
élément non reconstructible depuis Git est la **clé privée sealed-secrets**, une par cluster :
son backup (coffre) est un prérequis du runbook, pas une option.

## Skills projet

Voir [.claude/skills/README.md](.claude/skills/README.md). `/check-regles <dossier>` vérifie
la conformité d'un dossier aux règles de `doc/`.
