# Conventions des composants

## Un seul arbre pour tous les clusters

Le repo ne contient **qu'un** arbre de déploiement, `cluster/`. Il n'y a plus un dossier par
cluster : c'est **chaque composant** qui désigne sa ou ses cibles, via la `destination` de son
`Application` ou via les sous-dossiers de son `ApplicationSet`.

```
cluster/
├── root.yaml                        # TIER 1 — glob '*.bootstrap.yaml' (recurse)
├── infra/
│   ├── infra.bootstrap.yaml         # TIER 2 — glob '{*.app.yaml,*.appset.yaml}' (recurse)
│   └── <name>/…                     # composants d'infrastructure
└── app/
    ├── app.bootstrap.yaml           # TIER 2 — idem
    └── <name>/…                     # composants applicatifs
```

⚠️ Trois suffixes distincts, et c'est ce qui empêche l'auto-récursion :

| Fichier | Découvert par | Remarque |
|---|---|---|
| `cluster/root.yaml` | personne — **apply manuel**, une fois | S'il s'appelait `root.bootstrap.yaml` il matcherait son propre glob et se gérerait lui-même. |
| `*.bootstrap.yaml` | `root` | Deux exemplaires : `infra` et `app`. |
| `*.app.yaml` / `*.appset.yaml` | `infra` / `app` | Suffixe **exact** requis, sinon le composant n'est pas découvert. |

Les trois étages du haut ne produisent que des objets `Application`/`ApplicationSet`, qui doivent
vivre là où tourne l'ArgoCD qui les lit :

| Étage | Produit | `destination` |
|---|---|---|
| tier 1 (`root.yaml`) et tier 2 (`*.bootstrap.yaml`) | des `Application`/`ApplicationSet` | **toujours le hub** — `name: bleu-kalecgos`, ns `argocd` |
| feuilles (`*.app.yaml`, template d'un `*.appset.yaml`) | les ressources réelles | le cluster visé — `name: <cluster>` |

Onboarder un cluster **ne consiste plus** à ajouter un tier-1 : `root.yaml` est appliqué une fois
pour tout le repo. Il faut (1) enregistrer le cluster côté hub (Secret de cluster, cf.
[regles-gitops.md](regles-gitops.md)), puis (2) lui ajouter des composants — un sous-dossier dans
un `ApplicationSet` existant, ou un nouveau composant dont la `destination` le désigne.

## Mono-cluster ou multi-cluster : `Application` ou `ApplicationSet`

C'est le **seul** critère de choix entre les deux formes :

| | Forme | Fichier | Nom des Applications | Exemples |
|---|---|---|---|---|
| Déployé sur **un** cluster | `Application` | `<name>.app.yaml` | `<name>` (= dossier) | `argocd`, `openebs`, `forgejo`, `velero`… |
| Déployé sur **plusieurs** clusters | `ApplicationSet` | `<name>.appset.yaml` | `<cluster>-<name>` (template) | **aucun aujourd'hui** — le repo est mono-cluster |

Le **dossier** et le **nom de fichier** ne prennent jamais de préfixe de cluster : ce serait
`infra/cilium/cilium.appset.yaml`, produisant `bleu-kalecgos-cilium` et `bleu-arcanagos-cilium`.

⚠️ Le préfixe des Applications générées est **load-bearing** : toutes les Applications de tous les
clusters cohabitent dans le namespace `argocd` du hub. Sans préfixe, deux clusters portant le même
composant se disputeraient la même ressource, chacun avec son `prune`.

Un composant mono-cluster qui doit s'étendre à un second cluster **migre en `ApplicationSet`** :
renommer `<name>.app.yaml` en `<name>.appset.yaml`, déplacer ce qui est spécifique dans
`<cluster>/`, ce qui est partagé dans `common/`. Attention, la migration **renomme** l'Application
existante (`openebs` → `bleu-kalecgos-openebs`).

## Squelette d'un composant

**Mono-cluster** (`Application`) :

```
<name>/
├── <name>.app.yaml       # metadata.name == <name> == dossier
├── helm-values.yaml      # values Helm (si chart), référencées via $values (jamais inline)
├── README.md             # rôle, fichiers, contraintes, opérations — voir règle README ci-dessous
└── manifests/            # manifestes K8s bruts + kustomization.yaml (si nécessaires)
```

**Multi-cluster** (`ApplicationSet`) : un sous-dossier par cluster, découvert par un generator
`git.directories`, plus un `common/` optionnel pour ce qui est identique partout.

```
<name>/
├── <name>.appset.yaml    # generator git : path <name>/* (+ exclusion de common/)
├── README.md
├── common/               # facultatif — ce qui est identique entre clusters
│   ├── helm-values.yaml
│   └── manifests/        # base kustomize, jamais déployée seule
└── <cluster>/            # un par cluster ciblé — le nom du dossier EST le nom du cluster
    ├── helm-values.yaml  # facultatif : surcharge (ignoreMissingValueFiles)
    └── manifests/        # kustomization.yaml → ../../common/manifests + ressources propres
```

⚠️ **`common/` doit être exclu du generator**, sinon il produit une Application `common-<name>`
vers un cluster inexistant :

```yaml
directories:
  - path: cluster/infra/<name>/*
  - path: cluster/infra/<name>/common
    exclude: true
```

Aucun composant n'est aujourd'hui sous cette forme — le repo n'a plus qu'un cluster. Le dernier à
l'avoir été est [`infra/cilium`](../cluster/infra/cilium/README.md) (chart + values en deux
couches + base kustomize commune) ; son README décrit la migration inverse, et `git log
cluster/infra/cilium` en donne le modèle exact.

## Règles sur l'Application

- **Nom** : `metadata.name` = nom du dossier = préfixe du fichier, préfixé `<cluster>-` pour les
  Applications générées par un `ApplicationSet` (cf. ci-dessus).
- **Labels obligatoires** : `app.kubernetes.io/name`, `app.kubernetes.io/part-of: homelab-gitops`,
  `app.kubernetes.io/component`. Une Application générée porte **en plus**
  `homelab.wittner.tech/cluster: <cluster>` — c'est ce qui rend le namespace `argocd` du hub
  lisible par cluster :
  ```bash
  kubectl -n argocd get app -l homelab.wittner.tech/cluster=bleu-kalecgos
  ```
- **`targetRevision: main`** sur toute source git de ce repo.
- **`destination`** : **toujours `name: <cluster>`, jamais `server:`** — y compris pour le hub,
  qui se désigne `name: bleu-kalecgos` et non par l'URL interne. Le nom est celui porté par le
  Secret de cluster du namespace `argocd` **du hub** (`cluster-<cluster>`), y compris pour le
  cluster local : c'est
  [`cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml`](../cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml)
  qui remplace l'entrée `in-cluster` codée en dur d'ArgoCD. Une destination lue au nom du cluster
  se relit sans ambiguïté ; se tromper de nom déploie le composant **sur le mauvais cluster**.
- **`releaseName` explicite** sur toute source Helm.
- Pas de `CreateNamespace=true` quand `manifests/namespace.yaml` porte le namespace
  (nécessaire dès que le ns doit être labellisé, ex. PSA `privileged` pour `openebs`). L'un des
  deux doit couvrir le namespace, jamais les deux.
- `ServerSideApply=true` dès que le composant embarque des CRDs volumineuses (ArgoCD,
  prometheus-operator, Gateway API, OpenEBS, Cilium) ou de gros ConfigMaps (Loki).
- **`preserveResourcesOnDeletion: true`** sur tout `ApplicationSet` dont la disparition d'un
  dossier couperait le cluster (typiquement le CNI ou le credential d'accès du hub). Aucun
  `ApplicationSet` dans le repo aujourd'hui — règle à réappliquer au premier recréé.

## Charts Helm — values dans un fichier

Les values ne vont **jamais inline** (`helm.values: |`, `valuesObject:`). Toujours dans un fichier
**`helm-values.yaml`** à côté de l'app, référencé via le pattern multi-source `$values` :

```yaml
sources:
  - repoURL: <chart-repo>
    chart: <name>
    targetRevision: <ver>
    helm:
      releaseName: <name>
      valueFiles:
        - $values/cluster/infra/<name>/helm-values.yaml
  - repoURL: https://github.com/jbwittner/homelab_gitops.git
    targetRevision: main
    ref: values
```

Sur un `ApplicationSet` multi-cluster, les values se superposent en **deux couches**, l'ordre
faisant foi (le second fichier écrase le premier) ; `ignoreMissingValueFiles` rend la surcharge
facultative :

```yaml
valueFiles:
  - '$values/cluster/infra/<name>/common/helm-values.yaml'
  - '$values/{{.path.path}}/helm-values.yaml'
ignoreMissingValueFiles: true
```

La règle porte sur l'emplacement des **values Helm**, pas sur la configuration applicative :
une config embarquée dans une value (le pipeline Alloy, le `grafana.ini`) reste légitimement
dans `helm-values.yaml`.

## Archétypes

| Archétype | Forme | Composants |
|---|---|---|
| (a) | Helm + `$values` multi-source | `cnpg`, `cnpg-barman-plugin` |
| (b) | (a) + 3ᵉ source `manifests/` | `cert-manager`, `cilium`, `openebs`, `velero`, `kube-prometheus-stack`, `forgejo` |
| (c) | kustomize seul (`source.path` → `manifests/`) | `argocd`, `gateway-api`, `hermes`, `renovate`, les quatre `*-monitoring` |
| (d) | Helm sans values (migre vers (a) dès qu'une value est customisée) | `sealed-secrets` |

⚠️ `argocd` est en (c) avec **deux** sources : `manifests/` (cible de l'`apply -k` d'amorçage, objets
d'API cœur uniquement) et `post-bootstrap/` (ce qui suppose une CRD tierce). La séparation est
load-bearing — cf. [argocd](../cluster/infra/argocd/README.md).

## Sync-waves

Deux niveaux distincts, à ne pas confondre :

- **wave d'Application** (annotation sur le `.app.yaml` / `.appset.yaml`) — ordonne les composants
  entre eux ;
- **wave de ressource** (annotation sur un manifeste de `manifests/`) — ordonne l'intérieur d'un
  composant, ex. `openebs` : namespace (-1) → DaemonSet de bootstrap du VG (0) → StorageClass (1).

⚠️ Sur un `ApplicationSet`, l'annotation de wave porte sur **l'ApplicationSet lui-même** (c'est
lui que le tier-2 synchronise), pas sur les Applications générées — celles-ci sont créées ensuite
par le contrôleur ApplicationSet et déroulent leurs propres waves de ressource.

| Wave | Composant | Rôle |
|---|---|---|
| -10 | `gateway-api` | CRDs Gateway API + `shared-gw` |
| -8 | `sealed-secrets` | contrôleur de déchiffrement — **seul canal de secrets actif** |
| -7 | `external-secrets` | *(désactivé, `.noapp.yaml`)* — CRDs + contrôleur de l'ancien canal 2 |
| -5 | `cert-manager` | émission TLS, ClusterIssuers et wildcards (dans son `manifests/`) |
| -1 | `argocd` | self-management |
| -1 | `cnpg-barman-plugin` | le plugin doit précéder le `Cluster` CNPG qui le référence |
| 0 (défaut, non annoté) | `cilium`, `openebs`, `cnpg`, `kube-prometheus-stack`, `forgejo`, `hermes`, `renovate` | reste de la stack |
| 1 | `velero` | a besoin d'une StorageClass et des CRDs posées plus haut |
| 2 | `cnpg-monitoring`, `velero-monitoring`, `openebs-monitoring`, `forgejo-monitoring` | volets post-bootstrap : leurs `PrometheusRule`/`ServiceMonitor` supposent les CRDs de `kube-prometheus-stack` |

⚠️ **Une wave n'ordonne qu'à l'intérieur d'un même app-of-apps.** `infra` et `app` sont deux
Applications sœurs synchronisées en parallèle : aucune wave d'`infra` ne garantit quoi que ce
soit vis-à-vis d'un composant d'`app`. C'est pour cette raison que `velero`, qui a besoin d'une
StorageClass posée par `openebs`, est un composant d'**infra** — sinon sa dépendance à la StorageClass d'`openebs` ne serait pas exprimable.

## Secrets d'un composant

**Un seul canal actif** — sealed-secrets. Le second (openbao via external-secrets) est mort : les
deux composants sont désactivés ou archivés, cf. [regles-gitops.md](regles-gitops.md).

Trois fichiers, dans `manifests/` du composant qui **consomme** le secret :

| Fichier | Committé | Rôle |
|---|---|---|
| `<name>.sealed.yaml` | oui | le `SealedSecret`, **référencé dans le `kustomization.yaml`** |
| `<name>.secret.example.yaml` | oui | copie de référence, vide de toute valeur, porteuse de la procédure. **Jamais** dans le `kustomization.yaml` |
| `<name>.secret.yaml` | non — gitignoré (`*.secret.yaml`) | le clair, rempli localement puis supprimé après `kubeseal` |

Les `*.externalsecret.yaml` qui subsistent (quatre) sont tous commentés et ne s'appliquent nulle
part ; ne pas en créer de nouveaux.

⚠️ Un fichier référencé mais absent casse `kustomize build` et met toute l'Application en erreur :
tant qu'un secret n'est pas scellé, garder sa ligne **commentée** dans le `kustomization.yaml`.

Un `SealedSecret` est chiffré pour un couple **(nom, namespace)** et pour la clé du cluster : le
déplacer, ou le renommer, impose de le resceller.

⚠️ **Un `SealedSecret` ne va jamais dans un dossier servant à l'`apply -k` d'amorçage.** Seul
`cluster/infra/argocd/manifests/` est dans ce cas : ses `SealedSecret` vivent donc dans
`cluster/infra/argocd/post-bootstrap/`, déclaré comme second `source` de la même Application. À
l'étape 2 du bootstrap, la CRD `SealedSecret` n'existe pas encore.

## Commandes de la documentation

Toute commande d'un README doit être exécutable **depuis la racine du repo**, telle quelle :
chemins complets depuis la racine (`cluster/app/<name>/manifests/…`), jamais relatifs au
dossier du README.

## Règle README composant

Un README composant contient **au maximum** : `## Rôle` (2-3 lignes), `## Fichiers` (1 ligne
par fichier notable), `## Contraintes` (ce qui casse si on y touche), `## Opérations` (debug +
procédures propres au composant). Un composant multi-cluster ajoute utilement une section
« diverger sur un cluster » / « ajouter un cluster ».

**Interdit : toute version épinglée** (chart, image, manifest upstream). La version vit à un
seul endroit : `targetRevision` du `.app.yaml`/`.appset.yaml` (ou le `kustomization.yaml` pour un
install upstream). Un README ne doit jamais devoir être mis à jour lors d'un upgrade.

## READMEs d'index

- [`README.md`](../README.md) **racine** — point d'entrée du dépôt et index des composants : tout
  composant déployé (infra + app) y figure avec un **lien vers son README**. Un composant
  ajouté/supprimé = index mis à jour dans le **même commit**.
- [`doc/README.md`](README.md) — index des documents transverses de `doc/`.
- Les composants retirés du déploiement vont dans [`archive/`](../archive/), avec un bandeau en tête
  de leur README disant **quand** et **pourquoi**. Ils gardent l'extension `.noapp.yaml` pour rester
  hors du glob des tiers-2.
