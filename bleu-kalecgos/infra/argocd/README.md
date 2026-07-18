# argocd

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
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 4. Accès UI au bootstrap (la HTTPRoute ne fonctionne qu'après gateway-api + cert-manager)
kubectl -n argocd port-forward svc/argocd-server 8080:443

# 5. Lancer le tier-1 → ArgoCD déploie tout le reste dans l'ordre des sync-waves
kubectl apply -f bleu-kalecgos/cluster.yaml
```

Procédure complète (Talos, Cilium, DR) : [doc/runbook-bootstrap-kalecgos.md](../../../doc/runbook-bootstrap-kalecgos.md).

## Fichiers

- `argocd.app.yaml` — Application self-management (archétype (c), `prune: false`,
  path → `manifests/`)
- `manifests/kustomization.yaml` — install upstream **épinglé ici** + namespace + patchs + HTTPRoute
- `manifests/namespace.yaml` — ns `argocd`
- `manifests/argocd-cmd-params-cm.yaml` — patch `server.insecure: "true"` (TLS terminé au Gateway)
- `manifests/argocd-cm.yaml` — patch de la config ArgoCD
- `manifests/argocd-httproute.yaml` — UI via `shared-gw` (cf. [doc/reseau.md](../../../doc/reseau.md))

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

## Opérations

- **Upgrade ArgoCD** : bumper le tag dans `manifests/kustomization.yaml`, commit, push
  (self-managed). Si crash-loop post-upgrade K8s : problème de compat, bumper au dernier patch
  de la série.
- **État** : `kubectl get applications -n argocd`, `argocd app list` (après login CLI).
- **Diff/resync** : `argocd app diff <name>`, `argocd app sync <name>`.
- **Logs** : `kubectl logs -n argocd deploy/argocd-repo-server`,
  `kubectl logs -n argocd statefulset/argocd-application-controller`.
