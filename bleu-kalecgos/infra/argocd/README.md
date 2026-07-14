# Argo CD — `homelab-gitops` / bleu-kalecgos

Bootstrap et gestion déclarative d'Argo CD sur le cluster **bleu-kalecgos** (`ns3058844`).
Pattern : **app-of-apps** + **Argo manages Argo** (Argo gère sa propre config après le bootstrap initial).

## TL;DR — commandes d'init

```bash
# 1. Installer Argo EN PREMIER (server-side OBLIGATOIRE). Repo public → clone HTTPS anonyme,
#    aucun credential ni SealedSecret requis au démarrage.
kubectl apply -k bleu-kalecgos/infra/argocd --server-side --force-conflicts

# 2. Vérifier les pods
kubectl get pods -n argocd

# 3. Attendre que le serveur soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 4. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 5. Accès UI (port-forward au bootstrap — l'IngressRoute n'est fonctionnel qu'après Traefik + cert-manager)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080  (admin + mdp étape 4)

# 6. Lancer le tier-1 → Argo déploie tout le reste (sealed-secrets inclus, wave 0)
kubectl apply -f bleu-kalecgos/cluster.yaml

# (optionnel) login CLI
argocd login localhost:8080 --username admin --password '<mdp>' --insecure
```

## Principe

Argo est à la fois ce qui **lit** le repo et un composant **dans** le repo :

1. **Bootstrap impératif** (une fois) : on installe Argo à la main via `kustomize` + `kubectl apply --server-side`.
2. **Self-management** : l'`Application` `argocd` pointe sur le **même** dossier (`bleu-kalecgos/infra/argocd`) → Argo adopte sa propre config. Ensuite, toute modif passe par Git.

> La convergence est garantie parce que l'apply manuel et l'Application self-managed utilisent **exactement le même dossier** `bleu-kalecgos/infra/argocd`.

## Structure du repo (rappel)

```
homelab-gitops/
└── bleu-kalecgos/
    ├── bleu-kalecgos.yaml                  # TIER 1 app-of-apps (apply manuel UNE fois sur le hub)
    └── infra/argocd/                    # dossier AUTO-CONTENU (bootstrap ET self-management)
    ├── argocd.app.yaml                  # Application self-management (path: bleu-kalecgos/infra/argocd)
    ├── kustomization.yaml               # install.yaml pinné (v3.4.3) + patch cmd-params + spécifique-hub
    ├── namespace.yaml                   # namespace argocd
    ├── argocd-cmd-params-cm.yaml        # patch ConfigMap argocd-cmd-params-cm
    ├── argocd-certificate.yaml          # Certificate cert-manager pour l'UI
    └── argocd-ingress-route.yaml        # IngressRoute Traefik pour l'UI
```

> Repo **public** → Argo le clone en HTTPS anonyme : plus aucune deploy key ni SealedSecret
> repo/webhook dans ce dossier.
>
> `kustomization.yaml` liste explicitement ses resources (et ignore donc `argocd.app.yaml`) :
> l'install upstream pinné, le namespace, le patch cmd-params, et le spécifique-hub
> (Certificate/IngressRoute UI). C'est le **même dossier** que l'apply manuel du bootstrap →
> convergence garantie.

## Bootstrap — procédure complète

### Pré-requis
- Cluster Talos `Ready` (`kubectl get nodes` → `ns3058844 Ready`).
- Contexte kubectl pointé sur bleu-kalecgos (`kubectl config current-context`).
- `kustomize` ou `kubectl -k` disponible.

### Credentials Git (repo public — aucun)

> Le repo est hébergé sur **GitHub** en **public** (`https://github.com/jbwittner/homelab_gitops.git`,
> HTTPS anonyme). C'est le `repoURL` de tous les `*.app.yaml`.

Argo clone le repo **sans credential** : plus de deploy key SSH, plus de SealedSecret repo, plus
de patch `ssh-known-hosts`. La migration en public a supprimé toute la dépendance circulaire du
bootstrap : **Argo s'installe en premier**, puis le contrôleur sealed-secrets est déployé par Argo
en wave 0 comme tout autre composant — aucun pré-install manuel.

> Les SealedSecrets d'autres composants (Cloudflare cert-manager/external-dns, PAT Renovate, …)
> restent scellés contre le contrôleur ; ils se génèrent après coup, une fois sealed-secrets en
> place (chaque README de composant porte la commande `kubeseal`). Rien de tout ça n'est requis
> pour amorcer Argo.

### 1. Installer Argo (impératif, une seule fois — EN PREMIER)

> [!important] Le `--server-side --force-conflicts` est **obligatoire**.
> Sans lui, erreur de CRD trop grosse (`metadata.annotations: Too long`) sur les CRD ApplicationSet.

```bash
kubectl apply -k bleu-kalecgos/infra/argocd --server-side --force-conflicts
```

### 2. Vérifier que les pods montent

```bash
kubectl get pods -n argocd
```

Attendus en `Running` :
- `argocd-server`
- `argocd-repo-server`
- `argocd-application-controller` (statefulset)
- `argocd-applicationset-controller`
- `argocd-redis`
- `argocd-dex-server` (SSO — peut être désactivé si pas de SSO)
- `argocd-notifications-controller`

> [!warning] K8s 1.36 (bleeding-edge)
> Le cluster tourne sur Kubernetes **1.36**, très récent. L'install upstream est actuellement
> pinnée sur **v3.4.3** dans `bleu-kalecgos/infra/argocd/kustomization.yaml`. Si des pods Argo
> crashent en boucle avec des erreurs d'API, c'est un problème de compatibilité version : bumper
> Argo vers le dernier patch stable de la série `v3.4.x` (mettre à jour le tag dans cette base). En dernier
> recours, downgrade K8s (gratuit tant que le cluster est vide).

### 3. Récupérer le mot de passe admin initial

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Login : `admin` + ce mot de passe.

### 4. Accéder à l'UI (port-forward au bootstrap)

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

→ https://localhost:8080 (certificat auto-signé, accepter l'avertissement).

L'`IngressRoute` Traefik + TLS cert-manager (`argocd-ingress-route.yaml` /
`argocd-certificate.yaml`) est dans le bundle mais ne devient fonctionnelle qu'une fois
Traefik (wave 0) et cert-manager (wave 1) déployés. Avant ça, utiliser le port-forward.

### 5. Lancer les app-of-apps (déclenche tout le reste)

> Seulement APRÈS qu'Argo tourne.

```bash
kubectl apply -f bleu-kalecgos/bleu-kalecgos.yaml
```

`bleu-kalecgos` (tier 1) pointe `bleu-kalecgos/` (recurse + `include: '*.bootstrap.yaml'`) → crée les deux bootstraps de partie → chacun découvre ses `*.app.yaml` → Argo crée toutes les Applications du cluster et déroule les sync-waves. L'Application `argocd` (wave -1) adopte la config déjà déployée à l'étape 1 → passe `Synced` sans rien changer → **self-management acté**.

## Self-management — points de vigilance

> [!danger] Pièges du « Argo manages Argo »
> - **`ServerSideApply=true`** sur l'Application `argocd` : doit matcher l'apply manuel server-side,
>   sinon diff permanent (`OutOfSync`).
> - **`prune: false`** sur l'Application `argocd` : éviter qu'Argo supprime ses propres composants
>   (il se couperait les jambes). `selfHeal: true` est OK.
> - Après le premier sync, repo-server/controller peuvent redémarrer une fois : **normal**, laisser
>   se stabiliser, ne pas resync en boucle.
> - Si diff persistant sur un webhook/CRD : ajouter un `ignoreDifferences` ciblé.

## Ordre des sync-waves

Référence faisant foi : la table dans [`CLAUDE.md`](../../../CLAUDE.md) (déployé vs roadmap).
Rappel de l'état déployé :

| Wave | Composants |
|---|---|
| -1 | argocd (self-management) |
| 0 | sealed-secrets, traefik |
| 1 | cert-manager (+ ClusterIssuer overlay), external-dns |
| 3 | whoami (app de test) |

## Réactivations différées

L'UI Argo est déjà exposée via `argocd-ingress-route.yaml` + `argocd-certificate.yaml`
(actifs dans `bleu-kalecgos/infra/argocd/kustomization.yaml`). Reste en roadmap :
- SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) → à ajouter après (re)déploiement
  d'Authentik (actuellement archivé sous `archive/authentik/`, wave 3).

Chaque activation = éditer le kustomize, push Git, Argo resync tout seul (self-managed).

## DR — points à retenir

- Le bootstrap impératif (étape 1) est le **seul geste manuel** ; à refaire en reconstruction.
- Après l'étape 1, tout est déclaratif : le tier-1 du cluster (`bleu-kalecgos/bleu-kalecgos.yaml`) rejoue toute la stack depuis Git.
- Argo lit **GitHub public** (source de vérité) en HTTPS anonyme → DR déterministe, sans credential à restaurer, indépendant de toute forge auto-hébergée.
- La clé du contrôleur **sealed-secrets** doit être réinjectée AVANT que le contrôleur démarre
  (sinon SealedSecrets indéchiffrables). Procédure DR déjà testée.

## Commandes utiles

```bash
# état des Applications
kubectl get applications -n argocd
argocd app list                     # (via CLI, après login)

# resync manuel d'une app
argocd app sync <name>

# voir le diff d'une app
argocd app diff <name>

# logs d'un composant Argo
kubectl logs -n argocd deploy/argocd-repo-server
kubectl logs -n argocd statefulset/argocd-application-controller
```

## TODO

Bootstrap et self-management acquis (Argo installé, roots appliqués, `argocd` `Synced`,
IngressRoute/Certificate en place). Reste :

- [ ] Activer le SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) après (re)déploiement
      d'Authentik (archivé sous `archive/authentik/`).
- [ ] Bumper le tag Argo dans `bleu-kalecgos/infra/argocd/kustomization.yaml` si la compat K8s 1.36 l'exige.