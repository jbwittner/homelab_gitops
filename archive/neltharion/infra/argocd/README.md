# Argo CD — `homelab-gitops` / Neltharion

Bootstrap et gestion déclarative d'Argo CD sur le cluster **Neltharion** (`ns3058844`).
Pattern : **app-of-apps** + **Argo manages Argo** (Argo gère sa propre config après le bootstrap initial).

## TL;DR — commandes d'init

```bash
# 0. Installer le contrôleur sealed-secrets EN PREMIER (sinon la repo-cred scellée
#    appliquée à l'étape 1 ne peut pas être déchiffrée — cf. « Ordre du bootstrap » ci-dessous).
#    Mêmes nom/namespace/version que l'Application wave 0 → Argo l'adopte sans churn.
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s \
  deployment/sealed-secrets -n sealed-secrets

# 1. Installer Argo (server-side OBLIGATOIRE)
kubectl apply -k neltharion/infra/argocd --server-side --force-conflicts

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
2. **Self-management** : l'`Application` `argocd` pointe sur le **même** dossier (`neltharion/infra/argocd`) → Argo adopte sa propre config. Ensuite, toute modif passe par Git.

> La convergence est garantie parce que l'apply manuel et l'Application self-managed utilisent **exactement le même dossier** `neltharion/infra/argocd`.

## Structure du repo (rappel)

```
homelab-gitops/
└── neltharion/
    ├── neltharion.yaml                  # TIER 1 app-of-apps (apply manuel UNE fois sur le hub)
    └── infra/argocd/                    # dossier AUTO-CONTENU (bootstrap ET self-management)
    ├── argocd.app.yaml                  # Application self-management (path: neltharion/infra/argocd)
    ├── kustomization.yaml               # install.yaml pinné (v3.4.3) + patch cmd-params + spécifique-hub
    ├── namespace.yaml                   # namespace argocd
    ├── argocd-cmd-params-cm.yaml        # patch ConfigMap argocd-cmd-params-cm
    ├── argocd-certificate.yaml          # Certificate cert-manager pour l'UI
    ├── argocd-ingress-route.yaml        # IngressRoute Traefik pour l'UI
    ├── argocd-repo.sealed-secret.yaml       # deploy key SSH (scellée) — contient AUSSI l'url du repo
    └── argocd-webhook.sealed-secret.yaml    # secret webhook GitHub (scellé)
```

> `kustomization.yaml` liste explicitement ses resources (et ignore donc `argocd.app.yaml`) :
> l'install upstream pinné, le namespace, le patch cmd-params, et le spécifique-hub
> (Certificate/IngressRoute UI + secrets scellés). C'est le **même dossier** que l'apply manuel
> du bootstrap → convergence garantie.

## Bootstrap — procédure complète

### Pré-requis
- Cluster Talos `Ready` (`kubectl get nodes` → `ns3058844 Ready`).
- Contexte kubectl pointé sur Neltharion (`kubectl config current-context`).
- `kustomize` ou `kubectl -k` disponible.
- `kubeseal` installé localement (`brew install kubeseal`).
- `argocd-repo.sealed-secret.yaml` généré (voir section ci-dessous).

### Credentials Git (repo privé — SSH deploy key)

> Le repo est hébergé sur **GitHub** (`github.com`, SSH port 22 standard). L'url utilisée est la
> forme SCP `git@github.com:jbwittner/homelab_gitops.git` — supportée par Argo et identique au
> `repoURL` des manifests.

Argo CD accède au repo via une **deploy key SSH** : lecture seule, scopée à ce repo uniquement, révocable sans toucher au compte GitHub. Le secret est scellé et commité dans `neltharion/infra/argocd/argocd-repo.sealed-secret.yaml` — il contient **trois champs** (`url`, `sshPrivateKey`, `type: git`) et est appliqué en même temps qu'Argo au bootstrap. La cohérence est critique : la valeur `url` du secret **doit être identique** au `repoURL` des `*.app.yaml` (`git@github.com:jbwittner/homelab_gitops.git`), sinon Argo n'associe pas les credentials et le repo reste « unauthorized ».

**Générer la deploy key et le SealedSecret**

> Toutes les commandes ci-dessous sont à lancer depuis la **racine du repo**.

```bash
# 1. Générer une paire de clés ED25519 dédiée (sans passphrase)
ssh-keygen -t ed25519 -C "argocd@neltharion" -f argocd-deploy-key -N ""
# → argocd-deploy-key     (clé privée — gitignored)
# → argocd-deploy-key.pub (clé publique — à déposer comme deploy key GitHub)

# 2. Ajouter la clé publique comme deploy key du repo sur GitHub
#    https://github.com/jbwittner/homelab_gitops/settings/keys
#    Titre : argocd-neltharion | Allow write access : NON (lecture seule)
cat argocd-deploy-key.pub

# 3. Renseigner le secret (gitignored) : url + clé privée
#    - url   : git@github.com:jbwittner/homelab_gitops.git (DOIT matcher le repoURL des app.yaml)
#    - clé   : remplacer le placeholder par le contenu de la clé privée
sed -i '' "s|<COLLER_LA_CLÉ_PRIVÉE_ICI>|$(cat argocd-deploy-key)|" \
  neltharion/infra/argocd/argocd-repo.secret.yaml
# Vérifier que le champ url vaut bien :
#   git@github.com:jbwittner/homelab_gitops.git

# 4. Sceller (sealed-secrets doit être joignable sur le cluster)
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml \
  < neltharion/infra/argocd/argocd-repo.secret.yaml \
  > neltharion/infra/argocd/argocd-repo.sealed-secret.yaml

# 5. Committer le sealed (argocd-deploy-key* et *.secret.yaml restent gitignored)
git add neltharion/infra/argocd/argocd-repo.sealed-secret.yaml
git commit -m "Reseal argocd repo credential for GitHub"

# 6. Supprimer les clés locales (la privée est scellée, la publique est sur GitHub)
rm argocd-deploy-key argocd-deploy-key.pub
```

**Clé d'hôte SSH** — Argo vérifie la clé d'hôte du serveur Git avant de cloner. `github.com` fait
partie de la liste `ssh_known_hosts` **par défaut** livrée avec Argo (GitHub/GitLab/Bitbucket/Azure),
donc **aucun patch n'est nécessaire** : le `argocd-ssh-known-hosts-cm.yaml` custom (qui ne servait
qu'au serveur auto-hébergé sur port non standard) a été supprimé avec la migration. Si un jour le
clone échoue en « host key verification failed », vérifier que le patch n'a pas été ré-ajouté en
écrasant le défaut.

### 0. Installer le contrôleur sealed-secrets (impératif, AVANT Argo)

> [!danger] Ordre du bootstrap — dépendance circulaire à briser à la main
> La repo-cred SSH d'Argo (`argocd-repo.sealed-secret.yaml`) est **scellée** et appliquée à
> l'étape 1. Mais seul le contrôleur **sealed-secrets** peut la déchiffrer en `Secret` exploitable.
> Or ce contrôleur est normalement déployé par Argo en **wave 0** — qui a justement besoin de la
> repo-cred déchiffrée pour cloner le repo privé. Sans intervention, Argo ne peut donc jamais
> démarrer la wave 0. On **brise le cycle** en installant le contrôleur manuellement ici, avec
> exactement les mêmes nom/namespace/version que l'Application wave 0 : Argo l'**adopte** ensuite
> sans rien réinstaller.

```bash
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s \
  deployment/sealed-secrets -n sealed-secrets
```

> La génération/scellement de la deploy key (section « Credentials GitHub » ci-dessus) suppose
> déjà ce contrôleur joignable (`kubeseal --controller-name=sealed-secrets ...`) — c'est la même
> exigence.

### 1. Installer Argo (impératif, une seule fois)

> [!important] Le `--server-side --force-conflicts` est **obligatoire**.
> Sans lui, erreur de CRD trop grosse (`metadata.annotations: Too long`) sur les CRD ApplicationSet.

```bash
kubectl apply -k neltharion/infra/argocd --server-side --force-conflicts
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
> pinnée sur **v3.4.3** dans `neltharion/infra/argocd/kustomization.yaml`. Si des pods Argo
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
kubectl apply -f neltharion/neltharion.yaml
```

`neltharion` (tier 1) pointe `neltharion/` (recurse + `include: '*.bootstrap.yaml'`) → crée les deux bootstraps de partie → chacun découvre ses `*.app.yaml` → Argo crée toutes les Applications du cluster et déroule les sync-waves. L'Application `argocd` (wave -1) adopte la config déjà déployée à l'étape 1 → passe `Synced` sans rien changer → **self-management acté**.

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
(actifs dans `neltharion/infra/argocd/kustomization.yaml`). Reste en roadmap :
- SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) → à ajouter après (re)déploiement
  d'Authentik (actuellement archivé sous `archive/authentik/`, wave 3).

Chaque activation = éditer le kustomize, push Git, Argo resync tout seul (self-managed).

## DR — points à retenir

- Le bootstrap impératif (étape 1) est le **seul geste manuel** ; à refaire en reconstruction.
- Après l'étape 1, tout est déclaratif : le tier-1 du cluster (`neltharion/neltharion.yaml`) rejoue toute la stack depuis Git.
- Argo lit **GitHub** (source de vérité) via deploy key SSH → DR déterministe, indépendant de toute forge auto-hébergée.
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
- [ ] Bumper le tag Argo dans `neltharion/infra/argocd/kustomization.yaml` si la compat K8s 1.36 l'exige.