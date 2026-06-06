# Argo CD — `homelab-gitops` / Neltharion

Bootstrap et gestion déclarative d'Argo CD sur le cluster **Neltharion** (`ns3058844`).
Pattern : **app-of-apps** + **Argo manages Argo** (Argo gère sa propre config après le bootstrap initial).

## TL;DR — commandes d'init

```bash
# 1. Installer Argo (server-side OBLIGATOIRE)
kubectl apply -k infra/argocd --server-side --force-conflicts

# 2. Vérifier les pods
kubectl get pods -n argocd

# 3. Attendre que le serveur soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 4. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 5. Accès UI (port-forward, pas d'ingress encore)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080  (admin + mdp étape 4)

# (optionnel) login CLI
argocd login localhost:8080 --username admin --password '<mdp>' --insecure
```

## Principe

Argo est à la fois ce qui **lit** le repo et un composant **dans** le repo :

1. **Bootstrap impératif** (une fois) : on installe Argo à la main via `kustomize` + `kubectl apply --server-side`.
2. **Self-management** : l'`Application` `argocd` pointe sur le **même** dossier (`infra/argocd`) → Argo adopte sa propre config. Ensuite, toute modif passe par Git.

> La convergence est garantie parce que l'apply manuel et l'Application self-managed utilisent **exactement le même dossier** `infra/argocd`.

## Structure du repo (rappel)

```
homelab-gitops/
├── bootstrap/
│   └── root.yaml                     # app-of-apps racine (apply manuel UNE fois)
├── infra/
│   └── argocd/                       # kustomize Argo (sert au bootstrap ET au self-management)
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── *.patch.yaml
│       ├── ingress.yaml              # activé APRÈS cert-manager
│       └── argocd.sealed-secret.yaml # activé APRÈS sealed-secrets
└── definitions/
    └── neltharion/
        ├── infra/
        │   └── argocd.app.yaml       # Application self-management (path: infra/argocd)
        └── apps/
```

## Bootstrap — procédure complète

### Pré-requis
- Cluster Talos `Ready` (`kubectl get nodes` → `ns3058844 Ready`).
- Contexte kubectl pointé sur Neltharion (`kubectl config current-context`).
- `kustomize` ou `kubectl -k` disponible.
- Dans `infra/argocd/kustomization.yaml` : `ingress.yaml` et `argocd.sealed-secret.yaml`
  **retirés des `resources`** pour le premier apply (pas encore de cert-manager / sealed-secrets).
- Patches nettoyés de l'ancien contexte (repoURL `jbwittner/infrastructure`, SSO Authentik).

### 1. Installer Argo (impératif, une seule fois)

> [!important] Le `--server-side --force-conflicts` est **obligatoire**.
> Sans lui, erreur de CRD trop grosse (`metadata.annotations: Too long`) sur les CRD ApplicationSet.

```bash
kubectl apply -k infra/argocd --server-side --force-conflicts
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
> Le cluster tourne sur Kubernetes **1.36**, très récent. Si des pods Argo crashent en boucle
> avec des erreurs d'API, c'est un problème de compatibilité version. Bumper Argo vers la dernière
> `v3.3.x` (≥ v3.3.3 pour le backport de compat K8s récente). En dernier recours, downgrade K8s
> (gratuit tant que le cluster est vide).

### 3. Récupérer le mot de passe admin initial

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Login : `admin` + ce mot de passe.

### 4. Accéder à l'UI (port-forward — pas d'ingress encore)

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

→ https://localhost:8080 (certificat auto-signé, accepter l'avertissement).

L'ingress propre (TLS via cert-manager) sera activé plus tard, après la wave cert-manager.

### 5. Lancer l'app-of-apps (déclenche tout le reste)

> Seulement APRÈS qu'Argo tourne.

```bash
kubectl apply -f bootstrap/root.yaml
```

Le root pointe `definitions/neltharion` (recurse) → Argo crée toutes les Applications →
déroule les sync-waves. L'Application `argocd` (wave -1) adopte la config déjà déployée à
l'étape 1 → passe `Synced` sans rien changer → **self-management acté**.

## Self-management — points de vigilance

> [!danger] Pièges du « Argo manages Argo »
> - **`ServerSideApply=true`** sur l'Application `argocd` : doit matcher l'apply manuel server-side,
>   sinon diff permanent (`OutOfSync`).
> - **`prune: false`** sur l'Application `argocd` : éviter qu'Argo supprime ses propres composants
>   (il se couperait les jambes). `selfHeal: true` est OK.
> - Après le premier sync, repo-server/controller peuvent redémarrer une fois : **normal**, laisser
>   se stabiliser, ne pas resync en boucle.
> - Si diff persistant sur un webhook/CRD : ajouter un `ignoreDifferences` ciblé.

## Ordre des sync-waves (cible)

| Wave | Composants |
|---|---|
| -1 | argocd (self-management) |
| 0 | sealed-secrets |
| 1 | local-path-provisioner, cert-manager (chart), ingress-nginx, cert-manager-config |
| 2 | cnpg (opérateur) |
| 3 | forgejo, authentik |
| 4 | monitoring, postfix |

## Réactivations différées

Une fois les dépendances en place, **décommenter dans `infra/argocd/kustomization.yaml`** :
- `ingress.yaml` → après cert-manager + ingress-nginx (wave 1).
- `argocd.sealed-secret.yaml` → après sealed-secrets (wave 0) + réinjection de la clé du contrôleur.
- SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) → après Authentik (wave 3).

Chaque réactivation = éditer le kustomize, push Git, Argo resync tout seul (self-managed).

## DR — points à retenir

- Le bootstrap impératif (étape 1) est le **seul geste manuel** ; à refaire en reconstruction.
- Après l'étape 1, tout est déclaratif : `root.yaml` rejoue toute la stack depuis Git.
- Argo lit **GitHub** (source primaire), pas Forgejo → pas de cycle, DR déterministe.
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

- [ ] Vérifier pods `Running` (compat K8s 1.36).
- [ ] Bumper version Argo vers dernière `v3.3.x` si besoin compat.
- [ ] Créer `argocd.app.yaml` (self-management, ServerSideApply=true, prune=false, wave -1).
- [ ] Créer `bootstrap/root.yaml` (path `definitions/neltharion`, recurse).
- [ ] Appliquer le root → vérifier que l'Application `argocd` passe `Synced`.
- [ ] Nettoyer patches de l'ancien contexte (`jbwittner/infrastructure`, SSO).
- [ ] Réactiver ingress/sealed-secret/SSO au fil des waves.