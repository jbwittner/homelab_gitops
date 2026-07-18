# argocd — bleu-kalecgos

## Rôle

Moteur GitOps du cluster. **Seul geste impératif du repo** : le bootstrap initial d'ArgoCD.
Pattern : **app-of-apps** + **Argo manages Argo** (après le bootstrap, ArgoCD gère sa propre
config depuis Git).

## TL;DR — bootstrap

```bash
# 1. Installer Argo EN PREMIER (server-side OBLIGATOIRE — CRDs trop grosses sinon).
#    Repo public → clone HTTPS anonyme, aucun credential requis.
kubectl apply -k bleu-kalecgos/infra/argocd/manifests --server-side --force-conflicts

# 2. Attendre les pods
kubectl get pods -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 4. Accès UI au bootstrap (la HTTPRoute ne fonctionne qu'après gateway-api + cert-manager)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080 (admin + mdp étape 3)

# 5. Lancer le tier-1 → ArgoCD déploie tout le reste dans l'ordre des sync-waves
kubectl apply -f bleu-kalecgos/cluster.yaml
```

Procédure complète (Talos, Cilium, DR) : [doc/runbook-bootstrap-kalecgos.md](../../../doc/runbook-bootstrap-kalecgos.md).

## Source & versions

| Quoi | Valeur |
|---|---|
| Manifest upstream | `install.yaml` épinglé **v3.4.5** (`manifests/kustomization.yaml`) |
| Namespace | `argocd` (porté par `manifests/namespace.yaml`) |
| Archétype | (c) kustomize seul |

## Fichiers

- `argocd.app.yaml` — Application self-management (wave **-1**, `prune: false`,
  path → `manifests/`)
- `manifests/kustomization.yaml` — install upstream épinglé + namespace + patchs + HTTPRoute
- `manifests/namespace.yaml` — ns `argocd`
- `manifests/argocd-cmd-params-cm.yaml` — patch `server.insecure: "true"` (TLS terminé au Gateway)
- `manifests/argocd-cm.yaml` — patch de la config ArgoCD
- `manifests/argocd-httproute.yaml` — UI `argocd.kalecgos.lan.wittner.tech` via `shared-gw`
  (listener `https-internal-kalecgos`, backend `argocd-server:80`)

## Self-management — garde-fous

> [!danger] Pièges du « Argo manages Argo »
> - `path` de l'Application = **même dossier** que l'apply manuel (`manifests/`) → convergence
>   garantie, l'app passe `Synced` sans rien changer après le bootstrap.
> - **`ServerSideApply=true`** : doit matcher l'apply manuel server-side, sinon `OutOfSync`
>   permanent.
> - **`prune: false`** : Argo ne doit pas pouvoir supprimer ses propres composants.
>   `selfHeal: true` est OK.
> - Diff persistant sur un webhook/CRD → `ignoreDifferences` ciblé
>   (`RespectIgnoreDifferences=true` déjà actif).
> - Les `group/kind/weight` de la HTTPRoute sont **explicites** — sinon les defaults CRD
>   injectés côté live créent un `OutOfSync` permanent.

## Dépendances & sync-wave

Wave **-1** (après les CRDs Gateway API -10 pour que la HTTPRoute s'applique). L'ordre complet
du cluster :

| Wave | Composant |
|---|---|
| -10 | `gateway-api` |
| -8 | `sealed-secrets` |
| -5 | `cert-manager` |
| -4 | `cert-manager-config` |
| -1 | `argocd` |
| 0 | `cilium`, `openebs`, apps |

## Opérations courantes

- **Upgrade ArgoCD** : bumper le tag `vX.Y.Z` dans `manifests/kustomization.yaml`, commit, push
  (self-managed). Si crash-loop post-upgrade K8s : problème de compat, bumper au dernier patch
  de la série.
- **État** : `kubectl get applications -n argocd`, `argocd app list` (après login CLI).
- **Diff/resync** : `argocd app diff <name>`, `argocd app sync <name>`.
- **Logs** : `kubectl logs -n argocd deploy/argocd-repo-server`,
  `kubectl logs -n argocd statefulset/argocd-application-controller`.
