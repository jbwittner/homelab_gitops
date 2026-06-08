# Bootstrap

Ce dossier contient le **tier 1** de l'app-of-apps : **un fichier par cluster**
(`<cluster>.yaml`). C'est le seul manifest appliqué manuellement sur le hub — une seule fois
par cluster onboardé. Tout le reste est ensuite géré par Argo CD via Git.

## Fichiers

| Fichier | Application Argo | Scope |
|---|---|---|
| `neltharion.yaml` | `neltharion` | `neltharion/` — découvre les deux bootstraps de partie (`recurse` + `include: '*.bootstrap.yaml'`) |

Hiérarchie à 3 niveaux :

- **Tier 1** — `neltharion.yaml` pointe sur `neltharion/` avec `include: '*.bootstrap.yaml'` →
  ne retient que `infra/infra.bootstrap.yaml` + `apps/apps.bootstrap.yaml`.
- **Tier 2** — chaque `*.bootstrap.yaml` pointe sur sa partie (`neltharion/infra` ou
  `neltharion/apps`) avec `include: '*.app.yaml'` → découvre les composants.
- **Tier 3** — les `<name>.app.yaml`.

Les deux suffixes distincts (`.bootstrap.yaml` au tier 1, `.app.yaml` au tier 2) évitent toute
auto-récursion ; les `values.yaml` / `kustomization.yaml` / `*.sealed-secret.yaml` ne sont
captés par aucun glob (ils sont consommés par les Applications elles-mêmes).

## Repo privé — credentials GitHub

Le secret de credentials repo est scellé via sealed-secrets et commité dans `neltharion/infra/argocd/argocd-repo.sealed-secret.yaml`. Il est appliqué au moment du `kubectl apply -k neltharion/infra/argocd` (étape 1). Mais comme il est *scellé*, il faut que le contrôleur sealed-secrets soit déjà là pour le déchiffrer : on l'installe donc **manuellement en étape 0** (Argo l'adoptera en wave 0). C'est le geste qui brise la dépendance circulaire — voir [`neltharion/infra/argocd/README.md`](../neltharion/infra/argocd/README.md).

## Application (bootstrap one-time)

```bash
# 0. Installer le contrôleur sealed-secrets EN PREMIER (mêmes nom/namespace/version que la wave 0)
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s deployment/sealed-secrets -n sealed-secrets

# 1. Installer Argo CD + le SealedSecret de repo (inclus dans la kustomization)
kubectl apply -k neltharion/infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Récupérer le mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer le tier-1 du cluster — Argo prend le relais pour tout le reste
kubectl apply -f bootstrap/neltharion.yaml
```

Après l'étape 4, ne plus toucher à ces fichiers via `kubectl`. Toute modification passe par Git → push → Argo reconcile.

## Onboarder un autre cluster (spoke)

1. Enregistrer le spoke comme **cluster secret** Argo sur le hub (scellé), nommé `<cluster>`.
2. **Copier** le dossier `neltharion/` vers `<cluster>/` et l'adapter : chaque `<name>.app.yaml`
   (`destination.name: <cluster>`), les deux `*.bootstrap.yaml` (name + `path`), les `values.yaml`,
   et **re-sceller** les secrets pour ce cluster.
   > ⚠️ Les noms d'Applications sont **globaux** dans le namespace `argocd` du hub. `neltharion`,
   > `neltharion-infra`, `neltharion-apps` sont préfixés cluster, mais pas les composants
   > (`argocd`, `traefik`, …) : à la copie, préfixer leur `metadata.name` par le cluster.
3. `cp bootstrap/neltharion.yaml bootstrap/<cluster>.yaml` (adapter name + `path`), puis
   `kubectl apply -f bootstrap/<cluster>.yaml` sur le hub.
