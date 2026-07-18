# homelab_gitops — instructions projet

## Règle GitOps — NON négociable

**Interdit de pousser des données au cluster hors GitOps.** Toute ressource vit dans Git,
appliquée par **ArgoCD**. `kubectl` en écriture = bootstrap ArgoCD + debug read-only, rien
d'autre. Secrets : jamais en clair, uniquement **SealedSecrets** (`kubeseal`). Une modif =
éditer le manifeste, commit, push. Détail : [doc/regles-gitops.md](doc/regles-gitops.md).

## Conventions

Règles complètes : [doc/conventions.md](doc/conventions.md). Points critiques :

- Composant = `bleu-kalecgos/{infra,app}/<name>/<name>.app.yaml` — suffixe **exact**
  `.app.yaml` requis (glob de découverte), `metadata.name` = dossier = préfixe fichier.
- Values Helm **jamais inline** : fichier `helm-values.yaml` référencé via le pattern
  multi-source `$values` (exemple dans doc/conventions.md).
- READMEs composants : minimaux, **aucune version épinglée** (source unique :
  `targetRevision` du `.app.yaml`).

## Exposition réseau

Cilium Gateway API, `Gateway` partagé `shared-gw`. Exposer = `HTTPRoute` → `shared-gw`.
Détail : [doc/reseau.md](doc/reseau.md).

## Skills projet

Voir [.claude/skills/README.md](.claude/skills/README.md). `/check-regles <dossier>` vérifie
la conformité d'un dossier aux règles de `doc/`.
