---
name: check-regles
description: Vérifie la conformité d'un dossier du repo aux règles GitOps et conventions (doc/regles-gitops.md, doc/conventions.md, doc/reseau.md). Argument = chemin du dossier à auditer (un composant ou un arbre entier, ex. cluster/infra/cilium ou cluster/infra). Read-only, rapporte les violations sans rien modifier.
---

# check-regles — audit de conformité d'un dossier

Audit **read-only** : ne modifie aucun fichier, ne lance aucun `kubectl`. Sortie = rapport.

## Entrée

Argument : chemin d'un dossier (relatif à la racine du repo). Cas :
- un composant (`cluster/infra/<name>` ou `cluster/app/<name>`) → auditer ce composant ;
- un arbre (`cluster`, `cluster/infra`…) → auditer chaque composant qu'il contient
  (tout dossier contenant un `*.app.yaml` / `*.appset.yaml`, ou qui devrait en contenir un) ;
- un sous-dossier de cluster d'un composant multi-cluster (`cluster/infra/cilium/bleu-arcanagos`)
  → auditer le composant entier, ce sous-dossier n'a pas de sens isolément.
- Sans argument : demander le dossier.
- Ignorer `archive/` (hors périmètre actif).

## Étape 1 — recharger les règles (source de vérité)

**Toujours** lire d'abord — les règles ne sont PAS codées en dur dans ce skill, elles peuvent
évoluer :

1. `doc/regles-gitops.md`
2. `doc/conventions.md`
3. `doc/reseau.md`

Si une règle de ces fichiers contredit la checklist ci-dessous, **les fichiers doc/ gagnent**.

## Étape 2 — inventaire

Lister récursivement les fichiers du dossier cible (Glob). Lire chaque `*.app.yaml`,
`*.appset.yaml`, `helm-values.yaml`, `manifests/*.yaml`, `README.md` — y compris ceux de
`common/` et des sous-dossiers de cluster d'un composant multi-cluster.

## Étape 3 — vérifications (par composant)

Checklist minimale (complétée par ce que disent les fichiers doc/) :

1. **Découverte** : le fichier a le suffixe **exact** `.app.yaml` (`Application`) ou
   `.appset.yaml` (`ApplicationSet`) — piège : `.app.yml`, `-app.yaml`, `.application.yaml`,
   `.appset.yml` → non découvert par le glob du tier-2.
2. **Naming** : `metadata.name` = nom du dossier = préfixe du fichier
   (`<name>/<name>.app.yaml`). Pour un `ApplicationSet`, le `template.metadata.name` doit
   produire `<cluster>-<name>` (typiquement `'{{.path.basename}}-<name>'`) : toutes les
   Applications de tous les clusters partagent le namespace `argocd` du hub. Signaler toute
   collision de nom entre deux composants, et tout composant déployé sur plusieurs clusters
   resté sous forme d'`Application`.
3. **Labels obligatoires** sur l'Application : `app.kubernetes.io/name`,
   `app.kubernetes.io/part-of: homelab-gitops`, `app.kubernetes.io/component`. Sur un
   `ApplicationSet` : les mêmes, sur l'appset **et** sur son `template`, plus
   `homelab.wittner.tech/cluster: '{{.path.basename}}'` sur le template.
4. **Sources git de ce repo** : `targetRevision: main`.
5. **Sources Helm** : `releaseName` explicite.
6. **Values Helm** : jamais `helm.values: |` inline ni `valuesObject`. Si chart avec values →
   fichier `helm-values.yaml` référencé via `$values` multi-source (pattern exact dans
   doc/conventions.md). En multi-cluster : `common/helm-values.yaml` **puis** la surcharge du
   cluster, dans cet ordre, avec `ignoreMissingValueFiles: true`.
7. **Secrets** : aucun manifeste `kind: Secret` en clair **committé**. Seuls les
   `kind: SealedSecret` (`<name>.sealed.yaml`) sont admis dans Git ; les templates en clair
   suivent le motif gitignoré `<name>.secret.yaml`. Signaler tout fichier porteur d'un secret
   en clair (`stringData:`, tokens, clés privées) qui ne correspond pas à ce motif, et tout
   `*.sealed.yaml` référencé dans un `kustomization.yaml` mais absent du disque (casse
   `kustomize build`). **Deux exceptions** admises par doc/regles-gitops.md, et rien d'autre :
   la coquille sans `data`/`stringData` remplie par un contrôleur (`argocd-manager-token`) et le
   Secret de cluster du cluster **local** (`cluster-bleu-kalecgos`, sans credential). Le Secret
   de cluster d'un **spoke** porte un bearer token → `SealedSecret` obligatoire.
8. **Namespace** : pas de `syncOptions: CreateNamespace=true` si `manifests/namespace.yaml`
   existe (et inversement, un des deux doit couvrir le namespace).
9. **Exposition** : tout `HTTPRoute` a `parentRefs` → `shared-gw` (ns `gateway`) +
   `sectionName` ; `group`/`kind`/`weight` explicites dans les `backendRef`.
10. **README** : présent ; sections max Rôle/Fichiers/Contraintes/Opérations ; **aucune version
    épinglée** (numéros type `1.2.3`, `v1.2.3` référant à une version de chart/manifest —
    les versions vivent dans `.app.yaml`/`.appset.yaml`/`kustomization.yaml`).
11. **Commandes exécutables depuis la racine du repo** : toute commande d'un README doit
    utiliser des chemins relatifs à la racine (`cluster/…`), jamais au dossier du README
    (`manifests/…`, `./…`) ni supposer un `cd`.
12. **Doc à jour** : les noms de fichiers, de secrets, de clés et de groupes cités dans le README
    correspondent au contenu réel des manifestes (`kustomization.yaml`, `*.sealed.yaml`,
    `helm-values.yaml`). Une doc qui décrit un état révolu (« à créer », « décommenter » alors
    que la ressource est déjà câblée) est une violation.
13. **Archétype** : la forme du composant correspond à un archétype (a)/(b)/(c)/(d) de
    doc/conventions.md ; signaler un archétype (d) avec `helm-values.yaml` présent
    (devrait migrer en (a)) ou toute forme hybride non répertoriée.
14. **Destination** (doc/conventions.md, « Un seul arbre pour tous les clusters ») : toute
    `destination` se désigne par `name: <cluster>`, jamais par `server:` — `cluster/root.yaml`
    et les `*.bootstrap.yaml` ciblent **toujours** le hub (`name: bleu-kalecgos`, ns `argocd`) ;
    une feuille cible le cluster visé (`name: bleu-arcanagos` sur un spoke, ou
    `'{{.path.basename}}'` dans le template d'un appset). Une feuille de spoke laissée sur le hub
    y déploie ses ressources : violation critique. Un `server: https://kubernetes.default.svc`
    résiduel est une violation en soi.
15. **ApplicationSet** (composant multi-cluster) : generator `git.directories` sur
    `cluster/<partie>/<name>/*` avec **exclusion explicite de `common/`** (sinon une Application
    `common-<name>` vers un cluster inexistant) ; `goTemplateOptions: [missingkey=error]` ;
    `preserveResourcesOnDeletion: true` dès que la suppression couperait le cluster (CNI,
    credential d'accès) ; un sous-dossier par cluster dont le **nom est celui du cluster**, tel
    qu'enregistré côté hub. Signaler tout sous-dossier de cluster sans `manifests/`, et toute
    duplication entre deux clusters qui devrait vivre dans `common/`.
16. **Index racine** : le composant apparaît dans [`README.md`](../../../README.md) avec un
    **lien valide vers son README** et la ou les cibles. Vérifier aussi l'inverse quand l'audit
    porte sur un arbre : aucune entrée de l'index ne pointe vers un composant supprimé.
17. **Fiche cluster** : un composant qui ajoute un cluster (nouveau sous-dossier d'appset) exige
    une fiche `doc/clusters/<cluster>.md` et une ligne dans le tableau « Clusters » du README
    racine, dans le même commit.

## Étape 4 — rapport

Format :

```
# Audit check-regles — <dossier>

## Verdict : ✅ conforme | ❌ N violation(s), M avertissement(s)

## Violations
- `fichier:ligne` — règle enfreinte (référence doc/xxx.md) — correction proposée

## Avertissements
- points douteux, non bloquants

## Composants audités
- <name> ✅/❌
```

- Chaque violation cite le fichier de règles qui la fonde.
- Ne **jamais** corriger automatiquement — proposer la correction, l'utilisateur décide.
