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
├── bootstrap/
│   └── neltharion.yaml                  # TIER 1 app-of-apps (apply manuel UNE fois sur le hub)
└── neltharion/infra/argocd/             # dossier AUTO-CONTENU (bootstrap ET self-management)
    ├── argocd.app.yaml                  # Application self-management (path: neltharion/infra/argocd)
    ├── kustomization.yaml               # install.yaml pinné (v3.4.3) + patch cmd-params + spécifique-hub
    ├── namespace.yaml                   # namespace argocd
    ├── argocd-cmd-params-cm.yaml        # patch ConfigMap argocd-cmd-params-cm
    ├── argocd-certificate.yaml          # Certificate cert-manager pour l'UI
    ├── argocd-ingress-route.yaml        # IngressRoute Traefik pour l'UI
    ├── argocd-notifications-cm.yaml     # patch ConfigMap argocd-notifications-cm (service Grafana)
    ├── argocd-notifications.sealed-secret.yaml  # token Grafana scellé (à générer, cf. § Notifications)
    ├── argocd-repo.sealed-secret.yaml       # deploy key SSH (scellée)
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

### Credentials GitHub (repo privé — SSH deploy key)

Argo CD accède au repo via une **deploy key SSH** : lecture seule, scopée à ce repo uniquement, révocable sans toucher au compte GitHub. Le secret est scellé et commité dans `neltharion/infra/argocd/argocd-repo.sealed-secret.yaml` — il est appliqué en même temps qu'Argo au bootstrap.

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
  neltharion/infra/argocd/argocd-repo.secret.yaml

# 4. Sceller (sealed-secrets doit être joignable sur le cluster)
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml \
  < neltharion/infra/argocd/argocd-repo.secret.yaml \
  > neltharion/infra/argocd/argocd-repo.sealed-secret.yaml

# 5. Committer le sealed (argocd-deploy-key* et *.secret.yaml restent gitignored)
git add neltharion/infra/argocd/argocd-repo.sealed-secret.yaml
git commit -m "Add sealed SSH deploy key for argocd"

# 6. Supprimer les clés locales (la privée est scellée, la publique est sur GitHub)
rm argocd-deploy-key argocd-deploy-key.pub
```

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
kubectl apply -f bootstrap/neltharion.yaml
```

`neltharion` (tier 1) pointe `neltharion/` (recurse + `include: '*.bootstrap.yaml'`) → crée les deux bootstraps de partie → chacun découvre ses `*.app.yaml` → Argo crée toutes les Applications du cluster et déroule les sync-waves. L'Application `argocd` (wave -1) adopte la config déjà déployée à l'étape 1 → passe `Synced` sans rien changer → **self-management acté**.

## Notifications Grafana

Le `argocd-notifications-controller` (livré par l'install upstream) poste une **annotation Grafana**
(`POST /api/annotations`) à chaque évènement Argo. Visible ensuite comme marqueur vertical sur les
dashboards (filtrable par tag `argocd`).

Câblage déclaratif (déjà en place) :
- `argocd-notifications-cm.yaml` — patch du ConfigMap (vide à l'install) : service Grafana
  (`apiUrl: http://monitoring-grafana.monitoring.svc/api`), templates, triggers
  (`on-deployed`, `on-sync-failed`, `on-health-degraded`) et **subscription par défaut** sur
  toutes les Applications (tag `argocd`).
- `ignoreDifferences` sur l'Application `argocd` pour `Secret/argocd-notifications-secret` `/data` :
  le Secret est livré **vide** par l'upstream puis peuplé hors-bande par sealed-secrets — sans ça,
  `OutOfSync` permanent et `selfHeal` qui effacerait le token.

> Tant que le token n'est pas scellé, le controller logue une erreur d'envoi mais ne crashe pas.

### Générer le token Grafana et le sceller

> Toutes les commandes depuis la **racine du repo**.

```bash
# 1. Dans Grafana (https://grafana.wittnerlab.com) : Administration → Service accounts →
#    « Add service account » (role: Editor) → « Add token » (pas d'expiration ou longue TTL).
#    Copier le token affiché (visible une seule fois).

# 2. Injecter le token dans le placeholder gitignored
sed -i '' "s|<COLLER_LE_TOKEN_GRAFANA_ICI>|<token>|" \
  neltharion/infra/argocd/argocd-notifications.secret.yaml

# 3. Sceller (sealed-secrets doit être joignable sur le cluster)
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml \
  < neltharion/infra/argocd/argocd-notifications.secret.yaml \
  > neltharion/infra/argocd/argocd-notifications.sealed-secret.yaml

# 4. Activer la ressource dans le kustomize : décommenter la ligne
#    « - argocd-notifications.sealed-secret.yaml » dans kustomization.yaml

# 5. Vérifier le build, puis committer (seul le *.sealed-secret.yaml est suivi ;
#    le *.secret.yaml reste gitignored)
kubectl kustomize neltharion/infra/argocd >/dev/null && echo OK
git add neltharion/infra/argocd/argocd-notifications.sealed-secret.yaml \
        neltharion/infra/argocd/kustomization.yaml
git commit -m "Add sealed Grafana API token for argocd notifications"
```

> **Adoption du Secret vide.** L'install upstream livre `argocd-notifications-secret` VIDE.
> sealed-secrets refuse d'écraser un Secret qu'il ne possède pas tant que le **Secret live** ne
> porte pas l'annotation `sealedsecrets.bitnami.com/managed: "true"` — le contrôleur la vérifie
> sur le Secret existant, **pas** sur le template de la SealedSecret (que `kubeseal` y place
> pourtant). C'est donc un **patch kustomize** (dans `kustomization.yaml`) qui ajoute l'annotation
> directement au Secret upstream ; Argo l'applique → le contrôleur peut alors l'adopter et y
> écrire la clé `grafana-apikey`.
>
> ⚠️ **Migration (ajout de la feature sur un cluster déjà bootstrappé).** Si le Secret vide
> existait déjà SANS l'annotation, sealed-secrets a échoué puis *abandonné* (`giving up`) ; ajouter
> l'annotation au Secret live ne re-déclenche PAS la réconciliation (le **spec** de la SealedSecret
> n'a pas changé). Forcer un re-sync une fois :
> `kubectl rollout restart deploy/sealed-secrets -n sealed-secrets`. Sur un bootstrap *neuf* le
> problème n'existe pas : le patch crée le Secret déjà annoté, l'adoption est immédiate.

### Vérifier

```bash
kubectl logs -n argocd deploy/argocd-notifications-controller
# Forcer un test sur une app :
kubectl -n argocd annotate app whoami \
  notifications.argoproj.io/notified.on-deployed.grafana.argocd- --overwrite  # reset oncePer
```

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
- SSO Authentik (patch `argocd-cm` + `argocd-rbac-cm`) → à ajouter après Authentik (wave 3).

Chaque activation = éditer le kustomize, push Git, Argo resync tout seul (self-managed).

## DR — points à retenir

- Le bootstrap impératif (étape 1) est le **seul geste manuel** ; à refaire en reconstruction.
- Après l'étape 1, tout est déclaratif : le tier-1 du cluster (`bootstrap/neltharion.yaml`) rejoue toute la stack depuis Git.
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
- [ ] Bumper le tag Argo dans `neltharion/infra/argocd/kustomization.yaml` si la compat K8s 1.36 l'exige.
- [ ] **Notifications Grafana** : générer/sceller le token (`argocd-notifications.sealed-secret.yaml`)
      et décommenter la ressource dans `kustomization.yaml` (cf. § Notifications Grafana).