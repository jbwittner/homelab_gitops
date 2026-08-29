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

# 4. Accès UI au bootstrap : la HTTPRoute n'est même pas posée à ce stade (elle est dans
#    post-bootstrap/, appliquée par Argo en wave -1) et ne routera qu'après gateway-api
#    + cert-manager. Port-forward, donc.
kubectl -n argocd port-forward svc/argocd-server 8080:443

# 5. Lancer le tier-1 → ArgoCD déploie tout le reste dans l'ordre des sync-waves
kubectl apply -f cluster/root.yaml
```

## Fichiers

- `argocd.app.yaml` — Application self-management (archétype (c), wave -1, `prune: false`,
  `path` → `manifests/`)
- `manifests/kustomization.yaml` — install upstream **épinglé ici** + namespace + patchs
  (objets d'API cœur uniquement, cf. encadré ci-dessous)
- `manifests/namespace.yaml` — ns `argocd`
- `manifests/argocd-cmd-params-cm.yaml` — patch `server.insecure: "true"` (TLS terminé au
  Gateway) + `controller.diff.server.side: "true"` (cf. §Diff)
- `manifests/argocd-cm.yaml` — patch de la config ArgoCD : `url` externe, status badge,
  `oidc.config` (SSO authentik)
- `manifests/argocd-rbac-cm.yaml` — patch RBAC : défaut `role:readonly`, groupe authentik
  `app-argocd-admin` → `role:admin`
- `manifests/argocd-notifications-cm.yaml` — patch notifications : service Grafana, templates,
  triggers, souscriptions globales (cf. §Notifications)
- `post-bootstrap/argocd-httproute.yaml` — UI via `shared-gw` (cf.
  [doc/reseau.md](../../../doc/reseau.md))
- `manifests/argocd-notifications-secret.yaml` — patch qui pose
  `sealedsecrets.bitnami.com/managed: "true"` sur le Secret livré **vide** par l'upstream, sans
  quoi le contrôleur sealed-secrets refuse d'y écrire (cf. §Notifications)
- `post-bootstrap/argocd-oidc.sealed.yaml` — `SealedSecret` `argocd-oidc`, clé `client-secret`
  (OIDC). **Absent du repo tant qu'il n'est pas scellé** (cf. §SSO), ligne commentée dans le
  `kustomization.yaml`
- `post-bootstrap/argocd-notifications.sealed.yaml` — `SealedSecret`
  `argocd-notifications-secret`, clé `grafana-api-key`. **Absent du repo tant qu'il n'est pas
  scellé** (cf. §Notifications), ligne commentée dans le `kustomization.yaml`
- `manifests/cluster-bleu-kalecgos.yaml` — Secret de cluster qui **nomme le cluster local**
  `bleu-kalecgos` (sans lui : entrée `in-cluster` codée en dur). Aucun credential dedans → clair,
  rien à sceller (cf. §Nommage du cluster local)
> [!NOTE]
> **Tous les secrets de ce composant passent par [sealed-secrets](../sealed-secrets/README.md).**
> Ils transitaient auparavant par openbao + external-secrets ; ces deux composants sont
> désactivés (`*.noapp.yaml`), donc la CRD `ExternalSecret` n'existe plus dans le cluster et les
> manifestes correspondants ne s'appliquaient plus. Les valeurs restent au coffre côté openbao si
> celui-ci est relancé un jour, mais la source de vérité du cluster est le `.sealed.yaml`
> committé ici.

> [!IMPORTANT]
> **Deux dossiers, et la séparation est load-bearing.** `manifests/` est aussi la cible de
> l'`apply -k` manuel du bootstrap, exécuté quand seul ArgoCD tourne — donc **avant que le
> tier-1 n'ait posé la moindre CRD**. Tout objet d'un groupe d'API tiers y ferait échouer le
> geste d'amorçage sur `no matches for kind`. Ils vivent donc dans `post-bootstrap/`, déclaré
> comme **second `source`** de cette Application :
>
> | Objet | CRD posée par | Wave |
> |---|---|---|
> | `SealedSecret` (OIDC, notifications) | [sealed-secrets](../sealed-secrets/README.md) | `-8` |
> | `HTTPRoute` (UI) | [gateway-api](../gateway-api/README.md) | `-10` |
>
> Les deux arrivent donc **après** l'amorçage manuel, mais **avant** la wave `-1` où Argo
> synchronise cette Application : le tour de piste est complet, la route et les secrets sont
> posés par Argo lui-même.
>
> **Le critère est « est-ce que ça CASSE l'apply d'amorçage », pas « est-ce que c'est utile à
> l'amorçage ».** Les patchs RBAC (groupe authentik) et notifications (Grafana, `cluster/app/`)
> ne servent à rien tant que leur interlocuteur n'existe pas, mais ils s'appliquent proprement et
> n'empêchent ni Argo de démarrer ni le compte local `admin` de fonctionner : ils restent dans
> `manifests/`. Les sortir coûterait cher pour rien — leur cible vivant dans l'install upstream
> de ce dossier, il faudrait l'en retirer par un `$patch: delete` et les reposer en ressources
> autonomes, qui écraseraient en silence les clés que l'upstream pourrait y ajouter un jour
> (`argocd-cm` en porte déjà 9 : `resource.exclusions` et les
> `resource.customizations.ignoreResourceUpdates.*`).

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
> - Un fichier référencé mais absent dans `kustomization.yaml` casse `kustomize build` et met
>   l'app self-managed en erreur : commenter la ligne d'un `*.sealed.yaml` pas encore scellé.

## Tracking des ressources — `application.resourceTrackingMethod: annotation`

Réglage **global** (`manifests/argocd-cm.yaml`), il vaut pour toutes les Applications du repo, et
c'est un garde-fou contre la **perte de données**, pas un détail de confort.

Par défaut Argo trace ce qui lui appartient via le **label** `app.kubernetes.io/instance`. Or ce
label est aussi posé par les charts Helm sur des objets qu'Argo n'a jamais créés — typiquement
les PVC issus d'un `volumeClaimTemplates`, les Secrets générés par un opérateur, les Jobs. Argo
les **adopte**, et dès qu'ils sortent de l'ensemble désiré (un scale down suffit), `prune: true`
les supprime.

> [!WARNING]
> Arrivé pour de vrai : le PVC `data-openbao-1` d'[openbao](../openbao/README.md), détruit par un
> prune lors d'un passage de 2 à 1 replica — et avec lui le LV, `openebs-lvm-thin` étant en
> `reclaimPolicy: Delete`. Le `persistentVolumeClaimRetentionPolicy: Retain` du StatefulSet **ne
> protège pas de ce chemin** : il ne couvre que son propre garbage collector. Le coffre était
> vide ce jour-là ; il ne le sera pas toujours.

En tracking par **annotation**, Argo pose `argocd.argoproj.io/tracking-id` sur ce qu'il applique
lui-même. Une ressource créée par un contrôleur ne la porte pas → jamais adoptée → jamais prunée.

Au basculement, les ressources encore tracées par label le restent jusqu'à leur prochaine sync,
qui les ré-annote. Elles peuvent apparaître `OutOfSync` ou en *orphaned* pendant la transition —
sans risque de prune, une ressource non tracée n'étant justement pas candidate.

## Diff — `controller.diff.server.side`

Réglage **global** (`argocd-cmd-params-cm`), il vaut pour toutes les Applications du repo.

Par défaut le controller compare l'objet **live complet** au manifeste de Git. Or un CRD injecte
ses valeurs par défaut à l'admission — `remoteRef.conversionStrategy`/`decodingStrategy`/
`metadataPolicy` sur un `ExternalSecret`, `group`/`kind`/`weight` sur une `HTTPRoute`… Absents de
Git, présents côté live : `OutOfSync` permanent, qu'aucune sync ne résorbe puisque le champ
renaît à chaque apply. Le seul contournement était d'écrire ces defaults à la main dans **chaque**
manifeste, à refaire pour chaque nouvelle ressource.

Avec le flag, le controller applique en **dry-run côté serveur** et diffe le résultat prédit :
les defaults n'apparaissent plus, quel que soit le CRD. Écrire les defaults à la main devient
donc inutile (ceux déjà en place ne gênent pas — ils documentent l'appliqué).

> [!IMPORTANT]
> Ce n'est **pas** un substitut à `ignoreDifferences` : le server-side diff supprime les diffs
> dus aux defaults d'un **schéma**, pas ceux dus à une valeur écrite par un **contrôleur** après
> coup (le `caBundle` d'[openbao](../openbao/README.md), le `/data` d'un token de
> [argocd-manager](../argocd-manager/README.md)). Ces exceptions-là restent nécessaires.

Le flag est lu comme **variable d'environnement** par le controller : un changement de la
ConfigMap ne prend effet qu'au redémarrage du pod.

```bash
kubectl -n argocd rollout restart statefulset/argocd-application-controller
kubectl -n argocd rollout status statefulset/argocd-application-controller
# Vérifier la prise en compte
kubectl -n argocd exec statefulset/argocd-application-controller -- \
  printenv ARGOCD_APPLICATION_CONTROLLER_SERVER_SIDE_DIFF
```

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
# 1. Renseigner le template en clair (gitignoré, déjà dans le repo de travail) :
#    post-bootstrap/argocd-oidc.secret.yaml → remplacer REMPLACER par l'output terraform.

# 2. Sceller (le label `app.kubernetes.io/part-of: argocd` du template est recopié par kubeseal
#    dans le SealedSecret — sans lui ArgoCD ignore le secret et renvoie invalid_client).
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/argocd/post-bootstrap/argocd-oidc.secret.yaml \
  > cluster/infra/argocd/post-bootstrap/argocd-oidc.sealed.yaml

# 3. Supprimer le clair, décommenter `argocd-oidc.sealed.yaml` dans
#    post-bootstrap/kustomization.yaml (+ le bloc oidc.config d'argocd-cm.yaml), committer.
rm cluster/infra/argocd/post-bootstrap/argocd-oidc.secret.yaml
```

Rotation : régénérer le secret côté Terraform, refaire les étapes 1-3. Le contrôleur
sealed-secrets réécrit le Secret dès la sync de l'Application ; pour forcer :
`argocd app sync argocd`.

## Notifications — annotations Grafana

Le `argocd-notifications-controller` (livré par l'install upstream) pose une **annotation
Grafana** à chaque déploiement / dégradation / échec de sync, sur **toutes** les Applications
(souscriptions globales dans `argocd-notifications-cm`, rien à annoter par app). Tags posés :
`argocd` + `deployed` | `degraded` | `sync-failed` — à utiliser comme filtre d'annotation dans
les dashboards Grafana.

Contrainte du contrôleur : il ne lit **que** le Secret `argocd-notifications-secret` du ns
`argocd` (nom imposé, pas de `$autre-secret:clé` comme dans `argocd-cm`). Comme l'upstream livre
déjà ce Secret **vide**, le contrôleur sealed-secrets refuserait d'écrire dedans (« Resource ...
is not managed by SealedSecret ») : le patch `manifests/argocd-notifications-secret.yaml` y pose
`sealedsecrets.bitnami.com/managed: "true"`, ce qui l'autorise à s'en approprier le contenu.
L'annotation est portée par les deux objets — le Secret patché (pour la prise en main) et le
template du SealedSecret (pour qu'une réécriture ne la perde pas).

**Câblage du token** — il ne se provisionne pas en GitOps : création manuelle côté Grafana, puis
scellement.

```bash
# 1. Grafana → Administration → Users and access → Service accounts
#    Créer `argocd-notifications`, rôle Editor, puis « Add service account token »
#    (le token glsa_… n'est affiché qu'une fois).

# 2. Renseigner le template en clair (gitignoré, déjà dans le repo de travail) :
#    post-bootstrap/argocd-notifications.secret.yaml → remplacer REMPLACER par le glsa_…

# 3. Sceller.
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/infra/argocd/post-bootstrap/argocd-notifications.secret.yaml \
  > cluster/infra/argocd/post-bootstrap/argocd-notifications.sealed.yaml

# 4. Supprimer le clair, décommenter `argocd-notifications.sealed.yaml` dans
#    post-bootstrap/kustomization.yaml, committer.
rm cluster/infra/argocd/post-bootstrap/argocd-notifications.secret.yaml
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

Rotation du token : régénérer côté Grafana, re-renseigner le template, re-sceller (étapes 2-4).
Un `SealedSecret` est chiffré **pour un couple (nom, namespace)** : le déplacer de namespace le
rend indéchiffrable.
