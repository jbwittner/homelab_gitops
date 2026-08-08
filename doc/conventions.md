# Conventions des composants

## Chaîne de découverte (app-of-apps)

```
<cluster>/cluster.yaml                # TIER 1 — glob *.bootstrap.yaml
├── infra/infra.bootstrap.yaml        # TIER 2 — glob infra/**/*.app.yaml
└── app/app.bootstrap.yaml            # TIER 2 — glob app/**/*.app.yaml
```

⚠️ Le suffixe **exact** `.app.yaml` est requis, sinon le composant n'est pas découvert. Les deux
suffixes distincts (`.bootstrap.yaml` en tier 1, `.app.yaml` en tier 2) évitent l'auto-récursion.

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
  (nécessaire dès que le ns doit être labellisé, ex. PSA `privileged` pour `openebs` et `alloy`).
- `ServerSideApply=true` dès que le composant embarque des CRDs volumineuses (ArgoCD,
  prometheus-operator, Gateway API, OpenEBS) ou de gros ConfigMaps (Loki).

## Charts Helm — values dans un fichier

Les values ne vont **jamais inline** (`helm.values: |`). Toujours dans un fichier
**`helm-values.yaml`** à côté de l'app, référencé via le pattern multi-source `$values` :

```yaml
sources:
  - repoURL: <chart-repo>
    chart: <name>
    targetRevision: <ver>
    helm:
      releaseName: <name>
      valueFiles:
        - $values/<cluster>/infra/<name>/helm-values.yaml
  - repoURL: https://github.com/jbwittner/homelab_gitops.git
    targetRevision: main
    ref: values
```

La règle porte sur l'emplacement des **values Helm**, pas sur la configuration applicative :
une config embarquée dans une value (le pipeline Alloy, le `grafana.ini`) reste légitimement
dans `helm-values.yaml`.

## Archétypes

| Archétype | Forme | Composants |
|---|---|---|
| (a) | Helm + `$values` multi-source | `cert-manager`, `cnpg` |
| (b) | (a) + 3ᵉ source `manifests/` | `cilium`, `openebs`, `alloy`, `authentik`, `loki`, `kube-prometheus-stack` |
| (c) | kustomize seul (`source.path` → `manifests/`) | `argocd`, `cert-manager-config`, `gateway-api`, `renovate`, `test-nginx` |
| (d) | Helm sans values (migre vers (a) dès qu'une value est customisée) | `sealed-secrets` |

## Sync-waves

Deux niveaux distincts, à ne pas confondre :

- **wave d'Application** (annotation sur le `.app.yaml`) — ordonne les composants entre eux ;
- **wave de ressource** (annotation sur un manifeste de `manifests/`) — ordonne l'intérieur d'un
  composant, ex. `openebs` : namespace (-1) → hook VG (0) → StorageClass (1).

| Wave | Composant | Rôle |
|---|---|---|
| -10 | `gateway-api` | CRDs Gateway API + `shared-gw` |
| -8 | `sealed-secrets` | contrôleur de déchiffrement des secrets |
| -5 | `cert-manager` | émission TLS |
| -4 | `cert-manager-config` | ClusterIssuer Let's Encrypt + wildcards |
| -1 | `argocd` | self-management |
| 0 (défaut, non annoté) | `cilium`, `openebs`, apps | reste de la stack |

## Secrets d'un composant

Dans `manifests/` du composant qui consomme le secret :

- `<name>.secret.yaml` — template **en clair**, gitignoré (`*.secret.yaml`), jamais committé ;
- `<name>.sealed.yaml` — le `SealedSecret`, committé et **référencé dans le
  `kustomization.yaml`**.

⚠️ Un fichier référencé mais absent casse `kustomize build` et met toute l'Application en erreur :
tant qu'un secret n'est pas scellé, garder sa ligne **commentée** dans le `kustomization.yaml`.

## Commandes de la documentation

Toute commande d'un README doit être exécutable **depuis la racine du repo**, telle quelle :
chemins complets depuis la racine (`<cluster>/app/<name>/manifests/…`), jamais relatifs au
dossier du README.

## Règle README composant

Un README composant contient **au maximum** : `## Rôle` (2-3 lignes), `## Fichiers` (1 ligne
par fichier notable), `## Contraintes` (ce qui casse si on y touche), `## Opérations` (debug +
procédures propres au composant).

**Interdit : toute version épinglée** (chart, image, manifest upstream). La version vit à un
seul endroit : `targetRevision` du `.app.yaml` (ou le `kustomization.yaml` pour un install
upstream). Un README ne doit jamais devoir être mis à jour lors d'un upgrade.

## READMEs d'index

- `<cluster>/README.md` liste **tout composant déployé** (infra + app) avec un **lien vers son
  README** (`[<name>](infra/<name>/README.md)` ou `app/…`) — un composant ajouté/supprimé =
  index mis à jour dans le même commit.
- `README.md` racine liste les READMEs des clusters.
- `doc/clusters/<cluster>.md` — **fiche cluster** : les valeurs que le
  [runbook générique](runbook-bootstrap.md) paramètre (nœud, pool L2, wildcard DNS, disque,
  inventaire des SealedSecrets). Un nouveau cluster = une fiche, dans le même commit. La fiche
  porte les **valeurs**, jamais la procédure ; l'index des composants reste dans
  `<cluster>/README.md`.
