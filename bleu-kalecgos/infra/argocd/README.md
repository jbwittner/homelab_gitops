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
- `manifests/argocd-cm.yaml` — patch de la config ArgoCD (dont `oidc.config` SSO authentik)
- `manifests/argocd-rbac-cm.yaml` — patch RBAC : groupe authentik `ArgoCD Admins` → `role:admin`
- `manifests/argocd-httproute.yaml` — UI via `shared-gw` (cf. [doc/reseau.md](../../../doc/reseau.md))
- `manifests/argocd-oidc.sealed.yaml` — SealedSecret du `client-secret` OIDC (**à créer**, cf. §Opérations)
- `manifests/argocd-notifications-cm.yaml` — patch notifications : service Grafana, templates,
  triggers, souscriptions globales (cf. §Notifications)
- `manifests/argocd-notifications-secret-patch.yaml` — patch du Secret vide upstream :
  annotation d'adoption sealed-secrets (aucune donnée, cf. §Notifications)
- `manifests/argocd-notifications.sealed.yaml` — SealedSecret du token Grafana (**à créer**)

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

## SSO — authentik (OIDC)

Login via authentik. Le Provider/Application/groupe côté authentik est géré en
**Terraform** (autre repo). Contrat : `clientID=argocd`, issuer
`https://authentik.wittner.tech/application/o/argocd/`, scopes
`openid profile email groups`. Groupe authentik `ArgoCD Admins` → `role:admin` ;
tout autre user = `readonly`. Compte local `admin` conservé en break-glass
(`/auth/login`).

**Câblage final du client-secret** (une fois le `terraform apply` fait, avec
l'output `client_secret`). Commandes lancées **depuis la racine du repo** :

```bash
# 1. Coller l'output client_secret dans le template en clair (gitignore *.secret.yaml)
#    bleu-kalecgos/infra/argocd/manifests/argocd-oidc.secret.yaml → clé client-secret

# 2. Sceller à partir de ce fichier, puis supprimer le clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < bleu-kalecgos/infra/argocd/manifests/argocd-oidc.secret.yaml \
  > bleu-kalecgos/infra/argocd/manifests/argocd-oidc.sealed.yaml
rm bleu-kalecgos/infra/argocd/manifests/argocd-oidc.secret.yaml

# 3. Décommenter la ligne `- argocd-oidc.sealed.yaml` dans
#    manifests/kustomization.yaml (resources:), puis commit + push.
```

Rotation : régénérer le secret Terraform, re-coller dans `.secret.yaml`,
re-sceller (étape 2), commit.

## Notifications — annotations Grafana

Le `argocd-notifications-controller` (livré par l'install upstream) pose une **annotation
Grafana** à chaque déploiement / dégradation / échec de sync, sur **toutes** les Applications
(souscriptions globales dans `argocd-notifications-cm`, aucune annotation par app à ajouter).
Tags posés : `argocd` + `deployed` | `degraded` | `sync-failed` — à utiliser comme filtre
d'annotation dans les dashboards Grafana.

Contraintes du contrôleur : il ne lit **que** le Secret `argocd-notifications-secret` du ns
`argocd` (nom imposé, pas de `$autre-secret:clé` comme dans `argocd-cm`). Comme l'upstream
livre déjà ce Secret vide, il est patché avec `sealedsecrets.bitnami.com/managed: "true"` pour
que le contrôleur sealed-secrets l'adopte et y injecte la clé.

**Câblage du token** (le token Grafana ne se provisionne pas en GitOps — création manuelle
côté Grafana, puis scellage) :

```bash
# 1. Grafana → Administration → Users and access → Service accounts
#    Créer `argocd-notifications`, rôle Editor, puis « Add service account token »
#    (le token glsa_… n'est affiché qu'une fois).

# 2. Coller le token dans le template en clair (gitignoré) :
#    bleu-kalecgos/infra/argocd/manifests/argocd-notifications.secret.yaml
#    → clé grafana-api-key

# 3. Sceller, puis supprimer le clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < bleu-kalecgos/infra/argocd/manifests/argocd-notifications.secret.yaml \
  > bleu-kalecgos/infra/argocd/manifests/argocd-notifications.sealed.yaml
rm bleu-kalecgos/infra/argocd/manifests/argocd-notifications.secret.yaml

# 4. Décommenter `- argocd-notifications.sealed.yaml` dans manifests/kustomization.yaml,
#    commit + push.
```

**Où les voir** : une annotation Grafana ne s'affiche **nulle part** par défaut — il faut qu'un
dashboard la requête par tag. La couche « Déploiements ArgoCD » (tags `argocd` + `deployed`) est
déclarée dans `dashboard-talos-nodes.json`
([kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)) ; à recopier dans tout
nouveau dashboard qui doit porter les marqueurs de déploiement. Liste brute :
Grafana → Dashboards → *Annotations*, ou `GET /api/annotations?tags=argocd`.

> [!warning] Multi-source et `oncePer`
> `syncResult.revision` est **vide** sur les Applications multi-source (archétypes (a)/(b),
> les révisions vivent dans `syncResult.revisions`). Le `oncePer` du catalogue upstream s'appuie
> dessus : clé de dédup constante → **une seule annotation à vie** pour ces apps. D'où le
> `oncePer` sur le couple `[revision, revisions]` et le `with/else` dans le template.

Debug : `kubectl logs -n argocd deploy/argocd-notifications-controller`. `TRIGGERED` puis
`already sent` = normal (dédup `oncePer`). Vérifier la prise en compte d'un trigger sur une app :
`kubectl -n argocd get app <name> -o jsonpath='{.metadata.annotations}'` (le contrôleur y écrit
son état `notified.notifications.argoproj.io`).

Rotation du token : régénérer côté Grafana, re-renseigner le template, re-sceller (étape 3).

