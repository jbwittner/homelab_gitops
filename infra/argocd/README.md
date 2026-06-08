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

# 5. Accès UI (port-forward au bootstrap — l'IngressRoute n'est fonctionnel qu'après Traefik + cert-manager)
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
│   ├── root-infra.yaml                  # app-of-apps infra (apply manuel UNE fois)
│   └── root-apps.yaml                   # app-of-apps apps  (apply manuel UNE fois)
├── infra/
│   └── argocd/                          # kustomize Argo (sert au bootstrap ET au self-management)
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── argocd-cmd-params-cm.yaml    # patch ConfigMap argocd-cmd-params-cm
│       ├── argocd-certificate.yaml      # Certificate cert-manager pour l'UI
│       ├── argocd-ingress-route.yaml    # IngressRoute Traefik pour l'UI
│       ├── argocd-repo.sealed-secret.yaml     # deploy key SSH (scellée)
│       └── argocd-webhook.sealed-secret.yaml  # secret webhook GitHub (scellé)
└── definitions/
    └── neltharion/
        ├── infra/
        │   └── argocd.yaml          # Application self-management (path: infra/argocd)
        └── apps/
```

## Bootstrap — procédure complète

### Pré-requis
- Cluster Talos `Ready` (`kubectl get nodes` → `ns3058844 Ready`).
- Contexte kubectl pointé sur Neltharion (`kubectl config current-context`).
- `kustomize` ou `kubectl -k` disponible.
- `kubeseal` installé localement (`brew install kubeseal`).
- `argocd-repo.sealed-secret.yaml` généré (voir section ci-dessous).

### Credentials GitHub (repo privé — SSH deploy key)

Argo CD accède au repo via une **deploy key SSH** : lecture seule, scopée à ce repo uniquement, révocable sans toucher au compte GitHub. Le secret est scellé et commité dans `infra/argocd/argocd-repo.sealed-secret.yaml` — il est appliqué en même temps qu'Argo au bootstrap.

**Générer la deploy key et le SealedSecret**

> Toutes les commandes ci-dessous sont à lancer depuis la **racine du repo**.

```bash
# 1. Générer une paire de clés ED25519 dédiée (sans passphrase)
ssh-keygen -t ed25519 -C "argocd@neltharion" -f argocd-deploy-key -N ""
# → argocd-deploy-key     (clé privée — gitignored)
# → argocd-deploy-key.pub (clé publique — à déposer sur GitHub)

# 2. Ajouter la clé publique comme deploy key sur GitHub
#    https://github.com/jbwittner/homelab_gitops/settings/keys
#    Title : argocd-neltharion | Allow write access : NON (lecture seule)
cat argocd-deploy-key.pub

# 3. Injecter la clé privée dans le fichier secret (gitignored)
#    Remplacer le placeholder par le contenu de la clé
sed -i '' "s|<COLLER_LA_CLÉ_PRIVÉE_ICI>|$(cat argocd-deploy-key)|" \
  infra/argocd/argocd-repo.secret.yaml

# 4. Sceller (sealed-secrets doit être joignable sur le cluster)
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml \
  < infra/argocd/argocd-repo.secret.yaml \
  > infra/argocd/argocd-repo.sealed-secret.yaml

# 5. Committer le sealed (argocd-deploy-key* et *.secret.yaml restent gitignored)
git add infra/argocd/argocd-repo.sealed-secret.yaml
git commit -m "Add sealed SSH deploy key for argocd"

# 6. Supprimer les clés locales (la privée est scellée, la publique est sur GitHub)
rm argocd-deploy-key argocd-deploy-key.pub
```

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
kubectl apply -f bootstrap/root-infra.yaml -f bootstrap/root-apps.yaml
```

`root-infra` pointe `definitions/neltharion/infra` et `root-apps` pointe `definitions/neltharion/apps` (recurse sur chacun) → Argo crée toutes les Applications → déroule les sync-waves. L'Application `argocd` (wave -1) adopte la config déjà déployée à l'étape 1 → passe `Synced` sans rien changer → **self-management acté**.

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

Référence faisant foi : la table dans [`CLAUDE.md`](../../CLAUDE.md) (déployé vs roadmap).
Rappel de l'état déployé :

| Wave | Composants |
|---|---|
| -1 | argocd (self-management) |
| 0 | sealed-secrets, traefik |
| 1 | cert-manager (+ cert-manager-config), external-dns |
| 3 | whoami (app de test) |

## Réactivations différées

L'UI Argo est déjà exposée via `argocd-ingress-route.yaml` + `argocd-certificate.yaml`
(actifs dans `infra/argocd/kustomization.yaml`). Reste en roadmap :
- SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) → à ajouter après Authentik (wave 3).

Chaque activation = éditer le kustomize, push Git, Argo resync tout seul (self-managed).

## DR — points à retenir

- Le bootstrap impératif (étape 1) est le **seul geste manuel** ; à refaire en reconstruction.
- Après l'étape 1, tout est déclaratif : les deux roots (`root-infra.yaml` / `root-apps.yaml`) rejouent toute la stack depuis Git.
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

Bootstrap et self-management acquis (Argo installé, roots appliqués, `argocd` `Synced`,
IngressRoute/Certificate en place). Reste :

- [ ] Activer le SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) après la wave Authentik.
- [ ] Bumper le tag Argo dans `kustomization.yaml` si la compat K8s 1.36 l'exige.