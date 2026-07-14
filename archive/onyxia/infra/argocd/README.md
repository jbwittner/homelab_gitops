# Argo CD — `homelab-gitops` / Onyxia

Bootstrap et gestion déclarative d'Argo CD sur le cluster **Onyxia**.
Pattern : **app-of-apps** + **Argo manages Argo** (Argo gère sa propre config après le bootstrap initial).

Onyxia est un **hub autonome** : il fait tourner son propre Argo CD, indépendant de neltharion.

## TL;DR — commandes d'init

```bash
# 1. Installer Argo EN PREMIER (server-side OBLIGATOIRE). Repo public → clone HTTPS anonyme,
#    aucun credential ni SealedSecret requis au démarrage.
kubectl apply -k onyxia/infra/argocd --server-side --force-conflicts

# 2. Vérifier les pods
kubectl get pods -n argocd

# 3. Attendre que le serveur soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 4. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 5. Accès UI (port-forward au bootstrap)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080  (admin + mdp étape 4)

# 6. Lancer le tier-1 → Argo déploie tout le reste
kubectl apply -f onyxia/onyxia.yaml
```

## Principe

Argo est à la fois ce qui **lit** le repo et un composant **dans** le repo :

1. **Bootstrap impératif** (une fois) : on installe Argo à la main via `kustomize` + `kubectl apply --server-side`.
2. **Self-management** : l'`Application` `argocd` pointe sur le **même** dossier (`onyxia/infra/argocd`) → Argo adopte sa propre config. Ensuite, toute modif passe par Git.

> La convergence est garantie parce que l'apply manuel et l'Application self-managed utilisent **exactement le même dossier** `onyxia/infra/argocd`.

## Structure du repo (rappel)

```
homelab-gitops/
└── onyxia/
    ├── onyxia.yaml                     # TIER 1 app-of-apps (apply manuel UNE fois sur le hub)
    ├── infra/
    │   ├── infra.bootstrap.yaml        # TIER 2 — découvre infra/*/*.app.yaml
    │   └── argocd/                      # dossier AUTO-CONTENU (bootstrap ET self-management)
    │       ├── argocd.app.yaml          # Application self-management (path: onyxia/infra/argocd)
    │       ├── kustomization.yaml       # install.yaml pinné (v3.4.3) + patches cm/cmd-params
    │       ├── namespace.yaml           # namespace argocd
    │       ├── argocd-cm.yaml           # patch ConfigMap argocd-cm (status badge)
    │       └── argocd-cmd-params-cm.yaml # patch ConfigMap argocd-cmd-params-cm (server.insecure)
    └── apps/
        └── apps.bootstrap.yaml         # TIER 2 — découvre apps/*/*.app.yaml (vide pour l'instant)
```

> Repo **public** → Argo le clone en HTTPS anonyme : aucune deploy key ni SealedSecret
> repo/webhook dans ce dossier.
>
> `kustomization.yaml` liste explicitement ses resources (et ignore donc `argocd.app.yaml`).
> C'est le **même dossier** que l'apply manuel du bootstrap → convergence garantie.

## Bootstrap — procédure complète

### Pré-requis
- Cluster `Ready` (`kubectl get nodes`).
- Contexte kubectl pointé sur **Onyxia** (`kubectl config current-context`).
- `kustomize` ou `kubectl -k` disponible.

### 1. Installer Argo (impératif, une seule fois — EN PREMIER)

> [!important] Le `--server-side --force-conflicts` est **obligatoire**.
> Sans lui, erreur de CRD trop grosse (`metadata.annotations: Too long`) sur les CRD ApplicationSet.

```bash
kubectl apply -k onyxia/infra/argocd --server-side --force-conflicts
```

### 2. Vérifier que les pods montent

```bash
kubectl get pods -n argocd
```

Attendus en `Running` : `argocd-server`, `argocd-repo-server`,
`argocd-application-controller` (statefulset), `argocd-applicationset-controller`,
`argocd-redis`, `argocd-dex-server`, `argocd-notifications-controller`.

> [!warning] Compat version K8s
> L'install upstream est pinnée sur **v3.4.3** dans `onyxia/infra/argocd/kustomization.yaml`.
> Si des pods Argo crashent en boucle avec des erreurs d'API, bumper Argo vers le dernier patch
> stable (mettre à jour le tag dans cette base).

### 3. Mot de passe admin initial

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

### 5. Lancer les app-of-apps (déclenche tout le reste)

> Seulement APRÈS qu'Argo tourne.

```bash
kubectl apply -f onyxia/onyxia.yaml
```

`onyxia` (tier 1) pointe `onyxia/` (recurse + `include: '*.bootstrap.yaml'`) → crée les deux
bootstraps de partie → chacun découvre ses `*.app.yaml`. L'Application `argocd` (wave -1) adopte
la config déjà déployée à l'étape 1 → passe `Synced` sans rien changer → **self-management acté**.

## Self-management — points de vigilance

> [!danger] Pièges du « Argo manages Argo »
> - **`ServerSideApply=true`** sur l'Application `argocd` : doit matcher l'apply manuel server-side,
>   sinon diff permanent (`OutOfSync`).
> - **`prune: false`** sur l'Application `argocd` : éviter qu'Argo supprime ses propres composants.
>   `selfHeal: true` est OK.
> - Après le premier sync, repo-server/controller peuvent redémarrer une fois : **normal**.
> - Si diff persistant sur un webhook/CRD : ajouter un `ignoreDifferences` ciblé.

## DR — points à retenir

- Le bootstrap impératif (étape 1) est le **seul geste manuel** ; à refaire en reconstruction.
- Après l'étape 1, tout est déclaratif : `onyxia/onyxia.yaml` rejoue toute la stack depuis Git.
- Argo lit **GitHub public** (source de vérité) en HTTPS anonyme → DR déterministe, sans credential.
