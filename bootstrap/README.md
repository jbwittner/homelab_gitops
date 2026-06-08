# Bootstrap

Ce dossier contient **un app-of-apps par cluster** (`root-<cluster>.yaml`). C'est le seul
manifest appliqué manuellement sur le hub — une seule fois par cluster onboardé. Tout le
reste est ensuite géré par Argo CD via Git.

## Fichiers

| Fichier | Application Argo | Scope |
|---|---|---|
| `root-neltharion.yaml` | `root-neltharion` | `clusters/neltharion/` — découvre toutes les `Application` du cluster (`recurse` + `include: '*.app.yaml'`) |

Le root pointe sur `clusters/<cluster>` avec `recurse: true` et `include: '*.app.yaml'` :
tout nouveau `<name>.app.yaml` est automatiquement détecté et synchronisé par Argo ; les
`values.yaml` / `kustomization.yaml` / `*.sealed-secret.yaml` des overlays sont ignorés par
le root (ils sont consommés par les Applications elles-mêmes).

## Repo privé — credentials GitHub

Le secret de credentials repo est scellé via sealed-secrets et commité dans `clusters/neltharion/infra/argocd/argocd-repo.sealed-secret.yaml`. Il est appliqué au moment du `kubectl apply -k clusters/neltharion/infra/argocd` (étape 1). Mais comme il est *scellé*, il faut que le contrôleur sealed-secrets soit déjà là pour le déchiffrer : on l'installe donc **manuellement en étape 0** (Argo l'adoptera en wave 0). C'est le geste qui brise la dépendance circulaire — voir [`clusters/neltharion/infra/argocd/README.md`](../clusters/neltharion/infra/argocd/README.md).

## Application (bootstrap one-time)

```bash
# 0. Installer le contrôleur sealed-secrets EN PREMIER (mêmes nom/namespace/version que la wave 0)
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s deployment/sealed-secrets -n sealed-secrets

# 1. Installer Argo CD + le SealedSecret de repo (inclus dans la kustomization)
kubectl apply -k clusters/neltharion/infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Récupérer le mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer le root du cluster — Argo prend le relais pour tout le reste
kubectl apply -f bootstrap/root-neltharion.yaml
```

Après l'étape 4, ne plus toucher à ces fichiers via `kubectl`. Toute modification passe par Git → push → Argo reconcile.

## Onboarder un autre cluster (spoke)

1. Enregistrer le spoke comme **cluster secret** Argo sur le hub (scellé), nommé `<cluster>`.
2. Créer `clusters/<cluster>/{infra,apps}/` avec les `<name>.app.yaml` voulus (chacun en
   `destination.name: <cluster>`), leurs overlays/values et les secrets **re-scellés** pour ce cluster.
3. `kubectl apply -f bootstrap/root-<cluster>.yaml` sur le hub.
