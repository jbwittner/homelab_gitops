# Bootstrap

Ce dossier contient les deux Applications racines du pattern **app-of-apps**. Ce sont les seuls manifests appliqués manuellement — une seule fois, au premier démarrage du cluster. Tout le reste est ensuite géré par Argo CD via Git.

## Fichiers

| Fichier | Application Argo | Scope |
|---|---|---|
| `root-infra.yaml` | `root-infra` | `definitions/neltharion/infra/` — opérateurs, contrôleurs, cert-manager, ingress, etc. |
| `root-apps.yaml` | `root-apps` | `definitions/neltharion/apps/` — applications métier (Forgejo, Authentik, monitoring…) |

Chaque Application pointe sur son dossier avec `recurse: true` : tout nouveau fichier `.yaml` déposé dedans est automatiquement détecté et synchronisé par Argo.

## Repo privé — credentials GitHub

Le secret de credentials repo est scellé via sealed-secrets et commité dans `infra/argocd/argocd-repo.sealed-secret.yaml`. Il est appliqué au moment du `kubectl apply -k infra/argocd` (étape 1). Mais comme il est *scellé*, il faut que le contrôleur sealed-secrets soit déjà là pour le déchiffrer : on l'installe donc **manuellement en étape 0** (Argo l'adoptera en wave 0). C'est le geste qui brise la dépendance circulaire — voir [`infra/argocd/README.md`](../infra/argocd/README.md).

## Application (bootstrap one-time)

```bash
# 0. Installer le contrôleur sealed-secrets EN PREMIER (mêmes nom/namespace/version que la wave 0)
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s deployment/sealed-secrets -n sealed-secrets

# 1. Installer Argo CD + le SealedSecret de repo (inclus dans la kustomization)
kubectl apply -k infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Récupérer le mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer les deux roots — Argo prend le relais pour tout le reste
kubectl apply -f bootstrap/root-infra.yaml -f bootstrap/root-apps.yaml
```

Après l'étape 4, ne plus toucher à ces fichiers via `kubectl`. Toute modification passe par Git → push → Argo reconcile.
