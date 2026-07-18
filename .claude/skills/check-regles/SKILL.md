---
name: check-regles
description: Vérifie la conformité d'un dossier du repo aux règles GitOps et conventions (doc/regles-gitops.md, doc/conventions.md, doc/reseau.md). Argument = chemin du dossier à auditer (un composant ou un arbre entier, ex. bleu-kalecgos/infra/cilium ou bleu-kalecgos). Read-only, rapporte les violations sans rien modifier.
---

# check-regles — audit de conformité d'un dossier

Audit **read-only** : ne modifie aucun fichier, ne lance aucun `kubectl`. Sortie = rapport.

## Entrée

Argument : chemin d'un dossier (relatif à la racine du repo). Cas :
- un composant (`bleu-kalecgos/infra/<name>` ou `bleu-kalecgos/app/<name>`) → auditer ce composant ;
- un arbre (`bleu-kalecgos`, `bleu-kalecgos/infra`…) → auditer chaque composant qu'il contient
  (tout dossier contenant un `*.app.yaml`, ou qui devrait en contenir un).
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
`helm-values.yaml`, `manifests/*.yaml`, `README.md`.

## Étape 3 — vérifications (par composant)

Checklist minimale (complétée par ce que disent les fichiers doc/) :

1. **Découverte** : le fichier Application a le suffixe **exact** `.app.yaml`
   (piège : `.app.yml`, `-app.yaml`, `.application.yaml` → non découvert par le glob).
2. **Naming** : `metadata.name` de l'Application = nom du dossier = préfixe du fichier
   (`<name>/<name>.app.yaml`).
3. **Labels obligatoires** sur l'Application : `app.kubernetes.io/name`,
   `app.kubernetes.io/part-of: homelab-gitops`, `app.kubernetes.io/component`.
4. **Sources git de ce repo** : `targetRevision: main`.
5. **Sources Helm** : `releaseName` explicite.
6. **Values Helm** : jamais `helm.values: |` inline ni `valuesObject`. Si chart avec values →
   fichier `helm-values.yaml` référencé via `$values` multi-source (pattern exact dans
   doc/conventions.md).
7. **Secrets** : aucun manifeste `kind: Secret` en clair dans le dossier. Seuls les
   `kind: SealedSecret` sont admis. Signaler aussi tout fichier ressemblant à un secret en
   clair (`stringData:`, tokens, clés privées).
8. **Namespace** : pas de `syncOptions: CreateNamespace=true` si `manifests/namespace.yaml`
   existe (et inversement, un des deux doit couvrir le namespace).
9. **Exposition** : tout `HTTPRoute` a `parentRefs` → `shared-gw` (ns `gateway`) +
   `sectionName` ; `group`/`kind`/`weight` explicites dans les `backendRef`.
10. **README** : présent ; sections max Rôle/Fichiers/Contraintes/Opérations ; **aucune version
    épinglée** (numéros type `1.2.3`, `v1.2.3` référant à une version de chart/manifest —
    les versions vivent dans `.app.yaml`/`kustomization.yaml`).
11. **Archétype** : la forme du composant correspond à un archétype (a)/(b)/(c)/(d) de
    doc/conventions.md ; signaler un archétype (d) avec `helm-values.yaml` présent
    (devrait migrer en (a)) ou toute forme hybride non répertoriée.
12. **Index cluster** : le composant apparaît dans `<cluster>/README.md` avec un **lien valide
    vers son README** (ex. `[cilium](infra/cilium/README.md)`). Vérifier aussi l'inverse quand
    l'audit porte sur un arbre : aucune entrée de l'index ne pointe vers un composant supprimé.
    Le README racine doit lister le README du cluster.

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
