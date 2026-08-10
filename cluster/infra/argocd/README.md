# argocd

## Rôle

Moteur GitOps du cluster. Pattern **app-of-apps** + **Argo manages Argo** : après le bootstrap,
ArgoCD gère sa propre configuration depuis Git. Le dossier `manifests/` est **auto-contenu** —
il sert à la fois à l'apply manuel du bootstrap et à l'Application self-managed.

## TL;DR — bootstrap

Commandes à lancer **depuis la racine du repo**. Procédure complète (prérequis, CNI, clé
sealed-secrets, DR) : [doc/runbook-bootstrap.md](../../../doc/runbook-bootstrap.md).

```bash
# 1. Installer Argo (server-side OBLIGATOIRE — CRDs trop grosses sinon).
#    Repo public → clone HTTPS anonyme, aucun credential requis.
kubectl apply -k cluster/infra/argocd/manifests --server-side --force-conflicts

# 2. Attendre les pods
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 4. Accès UI au bootstrap (la HTTPRoute ne sert qu'après gateway-api + cert-manager)
kubectl -n argocd port-forward svc/argocd-server 8080:443

# 5. Lancer le tier-1 → ArgoCD déploie tout le reste dans l'ordre des sync-waves
kubectl apply -f cluster/root.yaml
```

## Fichiers

- `argocd.app.yaml` — Application self-management (archétype (c), wave -1, `prune: false`,
  `path` → `manifests/`)
- `manifests/kustomization.yaml` — install upstream **épinglé ici** + namespace + patchs + HTTPRoute
- `manifests/namespace.yaml` — ns `argocd`
- `manifests/argocd-cmd-params-cm.yaml` — patch `server.insecure: "true"` (TLS terminé au Gateway)
- `manifests/argocd-cm.yaml` — patch de la config ArgoCD : `url` externe, status badge,
  `oidc.config` (SSO authentik)
- `manifests/argocd-rbac-cm.yaml` — patch RBAC : défaut `role:readonly`, groupe authentik
  `app-argocd-admin` → `role:admin`
- `manifests/argocd-httproute.yaml` — UI via `shared-gw` (cf. [doc/reseau.md](../../../doc/reseau.md))
- `manifests/argocd-oidc.sealed.yaml` — SealedSecret `argocd-oidc`, clé `client-secret` (OIDC)
- `manifests/argocd-notifications-cm.yaml` — patch notifications : service Grafana, templates,
  triggers, souscriptions globales (cf. §Notifications)
- `manifests/argocd-notifications-secret-patch.yaml` — patch du Secret vide livré par l'upstream :
  annotation d'adoption sealed-secrets, aucune donnée (cf. §Notifications)
- `manifests/argocd-notifications.sealed.yaml` — SealedSecret `argocd-notifications-secret`,
  clé `grafana-api-key`
- `manifests/cluster-bleu-kalecgos.yaml` — Secret de cluster qui **nomme le cluster local**
  `bleu-kalecgos` (sans lui : entrée `in-cluster` codée en dur). Aucun credential dedans → clair,
  rien à sceller (cf. §Nommage du cluster local)
- `manifests/cluster-bleu-arcanagos.sealed.yaml` — SealedSecret du cluster **spoke**
  `bleu-arcanagos` (bearer token du SA `argocd-manager`, cf.
  [argocd-manager](../argocd-manager/README.md))

## Contraintes — self-management

> [!WARNING]
> **Pièges du « Argo manages Argo »**
> - `path` de l'Application = **même dossier** que l'apply manuel (`manifests/`) → l'app passe
>   `Synced` sans rien changer après le bootstrap.
> - **`ServerSideApply=true`** : doit matcher l'apply manuel server-side, sinon `OutOfSync`
>   permanent.
> - **`prune: false`** : Argo ne doit pas pouvoir supprimer ses propres composants.
>   `selfHeal: true` est OK.
> - Diff persistant sur un webhook/CRD → `ignoreDifferences` ciblé
>   (`RespectIgnoreDifferences=true` déjà actif).
> - Les `group/kind/weight` et le `matches` de la HTTPRoute sont **explicites** — sinon les
>   defaults CRD injectés côté live créent un `OutOfSync` permanent.
> - Un fichier référencé mais absent dans `kustomization.yaml` casse `kustomize build` et met
>   l'app self-managed en erreur : commenter la ligne d'un `*.sealed.yaml` pas encore scellé.

## Opérations

- **Upgrade ArgoCD** : bumper le tag dans `manifests/kustomization.yaml`, commit, push
  (self-managed). Renovate propose la PR mais **n'automerge jamais** ce composant
  (cf. `renovate.json`) : relecture obligatoire. Si crash-loop après un upgrade Kubernetes,
  bumper au dernier patch de la série.
- **État** : `kubectl get applications -n argocd`, `argocd app list` (après login CLI).
- **Diff / resync** : `argocd app diff <name>`, `argocd app sync <name>`.
- **Logs** : `kubectl logs -n argocd deploy/argocd-repo-server`,
  `kubectl logs -n argocd statefulset/argocd-application-controller`.

## SSO — authentik (OIDC)

Login via authentik. Le Provider / Application / groupe côté authentik est géré en
**Terraform** (autre repo). Contrat : `clientID=argocd`, issuer
`https://authentik.wittner.tech/application/o/argocd/`, scopes `openid profile email groups`.
Groupe authentik **`app-argocd-admin`** → `role:admin` ; tout autre utilisateur = `readonly`.
Compte local `admin` conservé en break-glass (`/auth/login`).

**Câblage du client-secret** (après le `terraform apply`, avec l'output `client_secret`) —
commandes **depuis la racine du repo** :

```bash
# 1. Coller l'output client_secret dans le template en clair (gitignoré, clé client-secret) :
#    cluster/infra/argocd/manifests/argocd-oidc.secret.yaml

# 2. Sceller, puis supprimer le clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/argocd/manifests/argocd-oidc.secret.yaml \
  > cluster/infra/argocd/manifests/argocd-oidc.sealed.yaml
rm cluster/infra/argocd/manifests/argocd-oidc.secret.yaml

# 3. Commit + push (la ligne `- argocd-oidc.sealed.yaml` est déjà dans kustomization.yaml).
```

Rotation : régénérer le secret côté Terraform, re-renseigner le template, re-sceller (étape 2).

## Notifications — annotations Grafana

Le `argocd-notifications-controller` (livré par l'install upstream) pose une **annotation
Grafana** à chaque déploiement / dégradation / échec de sync, sur **toutes** les Applications
(souscriptions globales dans `argocd-notifications-cm`, rien à annoter par app). Tags posés :
`argocd` + `deployed` | `degraded` | `sync-failed` — à utiliser comme filtre d'annotation dans
les dashboards Grafana.

Contrainte du contrôleur : il ne lit **que** le Secret `argocd-notifications-secret` du ns
`argocd` (nom imposé, pas de `$autre-secret:clé` comme dans `argocd-cm`). Comme l'upstream livre
déjà ce Secret vide, il est patché avec `sealedsecrets.bitnami.com/managed: "true"` pour que le
contrôleur sealed-secrets l'adopte et y injecte la clé.

**Câblage du token** — il ne se provisionne pas en GitOps : création manuelle côté Grafana, puis
scellage.

```bash
# 1. Grafana → Administration → Users and access → Service accounts
#    Créer `argocd-notifications`, rôle Editor, puis « Add service account token »
#    (le token glsa_… n'est affiché qu'une fois).

# 2. Coller le token dans le template en clair (gitignoré, clé grafana-api-key) :
#    cluster/infra/argocd/manifests/argocd-notifications.secret.yaml

# 3. Sceller, puis supprimer le clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/argocd/manifests/argocd-notifications.secret.yaml \
  > cluster/infra/argocd/manifests/argocd-notifications.sealed.yaml
rm cluster/infra/argocd/manifests/argocd-notifications.secret.yaml

# 4. Commit + push.
```

**Où les voir** : une annotation Grafana ne s'affiche **nulle part** par défaut — il faut qu'un
dashboard la requête par tag. La couche « Déploiements ArgoCD » (tags `argocd` + `deployed`) est
déclarée dans `dashboard-talos-nodes.yaml`, et les 3 tags (`deployed` / `degraded` /
`sync-failed`) dans le dashboard « GitOps — ArgoCD » — qui porte aussi le suivi des Applications
et le scrape des composants
([kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)) ; à recopier dans tout
nouveau dashboard qui doit porter les marqueurs de déploiement. Liste brute :
Grafana → Dashboards → *Annotations*, ou `GET /api/annotations?tags=argocd`.

> [!WARNING]
> **Multi-source et `oncePer`.** `syncResult.revision` est **vide** sur les Applications
> multi-source (archétypes (a)/(b) — les révisions vivent dans `syncResult.revisions`). Le
> `oncePer` du catalogue upstream s'appuie dessus : clé de dédup constante → **une seule
> annotation à vie** pour ces apps. D'où le `oncePer` sur le couple `[revision, revisions]` et le
> `with/else` dans le template.

Debug : `kubectl logs -n argocd deploy/argocd-notifications-controller`. `TRIGGERED` puis
`already sent` = normal (dédup `oncePer`). Vérifier la prise en compte d'un trigger sur une app :
`kubectl -n argocd get app <name> -o jsonpath='{.metadata.annotations}'` (le contrôleur y écrit
son état `notified.notifications.argoproj.io`).

Rotation du token : régénérer côté Grafana, re-renseigner le template, re-sceller (étape 3).
