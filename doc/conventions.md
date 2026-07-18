# Conventions des composants

## Chaîne de découverte (app-of-apps)

```
bleu-kalecgos/cluster.yaml            # TIER 1 — glob *.bootstrap.yaml
├── infra/infra.bootstrap.yaml        # TIER 2 — glob infra/**/*.app.yaml
└── app/app.bootstrap.yaml            # TIER 2 — glob app/**/*.app.yaml
```

⚠️ Le suffixe **exact** `.app.yaml` est requis, sinon le composant n'est pas découvert.

## Squelette d'un composant

```
<name>/
├── <name>.app.yaml       # Application ArgoCD — metadata.name == <name> == dossier
├── helm-values.yaml      # values Helm (si chart), référencées via $values (jamais inline)
├── README.md             # rôle, fichiers, opérations — voir règle README ci-dessous
└── manifests/            # manifestes K8s bruts + kustomization.yaml (si nécessaires)
```

## Règles sur l'Application

- **Nom** : `metadata.name` = nom du dossier = préfixe du fichier `.app.yaml`.
- **Labels obligatoires** : `app.kubernetes.io/name`, `app.kubernetes.io/part-of: homelab-gitops`,
  `app.kubernetes.io/component`.
- **`targetRevision: main`** sur toute source git de ce repo.
- **`releaseName` explicite** sur toute source Helm.
- Pas de `CreateNamespace=true` quand `manifests/namespace.yaml` porte le namespace
  (nécessaire dès que le ns doit être labellisé, ex. PSA `privileged` pour openebs).

## Charts Helm — values dans un fichier

Les values ne vont **jamais inline** (`helm.values: |`). Toujours dans un fichier
**`helm-values.yaml`** à côté de l'app, référencé via le pattern multi-source `$values` :

```yaml
sources:
  - repoURL: <chart-repo>
    chart: <name>
    targetRevision: <ver>
    helm:
      valueFiles:
        - $values/bleu-kalecgos/infra/<name>/helm-values.yaml
  - repoURL: https://github.com/jbwittner/homelab_gitops.git
    targetRevision: main
    ref: values
```

## Archétypes

| Archétype | Forme | Exemples |
|---|---|---|
| (a) | Helm + `$values` multi-source | `cert-manager`, `cnpg` |
| (b) | (a) + 3ᵉ source `manifests/` | `cilium`, `openebs` |
| (c) | kustomize seul (`source.path` → `manifests/`) | `argocd`, `cert-manager-config`, `gateway-api`, `test-nginx` |
| (d) | Helm sans values (migre vers (a) dès qu'une value est customisée) | `sealed-secrets` |

## Sync-waves

| Wave | Composant | Rôle |
|---|---|---|
| -10 | `gateway-api` | CRDs Gateway API + `shared-gw` |
| -8 | `sealed-secrets` | contrôleur de déchiffrement des secrets |
| -5 | `cert-manager` | émission TLS |
| -4 | `cert-manager-config` | ClusterIssuer Let's Encrypt + wildcards |
| -1 | `argocd` | self-management |
| 0 | `cilium`, `openebs`, apps | reste de la stack |

## Règle README composant

Un README composant contient **au maximum** : `## Rôle` (2-3 lignes), `## Fichiers` (1 ligne
par fichier notable), `## Opérations` (debug + procédures propres au composant).

**Interdit : toute version épinglée** (chart, image, manifest upstream). La version vit à un
seul endroit : `targetRevision` du `.app.yaml` (ou le `kustomization.yaml` pour un install
upstream). Un README ne doit jamais devoir être mis à jour lors d'un upgrade.

## READMEs d'index

- `<cluster>/README.md` liste **tout composant déployé** (infra + app) avec un **lien vers son
  README** (`[<name>](infra/<name>/README.md)` ou `app/…`) — un composant ajouté/supprimé =
  index mis à jour dans le même commit.
- `README.md` racine liste les READMEs des clusters.
