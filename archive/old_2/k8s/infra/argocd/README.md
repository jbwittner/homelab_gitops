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
#    Ce geste-ci s'exécute depuis un clone LOCAL : il est indifférent à la visibilité du dépôt.
kubectl apply -k k8s/infra/argocd/manifests --server-side --force-conflicts

# 2. Attendre les pods
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Credential du dépôt — ⚠️ LE DÉPÔT EST PRIVÉ, ce geste n'est pas optionnel et doit précéder
#    l'étape 6 : sans lui `root.yaml` échoue dès son premier fetch, et rien ne se déploie.
#    Procédure complète (GitHub App, scellement) : §Accès au dépôt privé.
kubectl apply -f k8s/infra/argocd/post-bootstrap/repo-homelab-gitops-github.secret.yaml \
  --server-side --force-conflicts

# 4. Mot de passe admin initial (à changer ensuite, cf. §Compte admin local)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# 5. Accès UI au bootstrap : la HTTPRoute n'est même pas posée à ce stade (elle est dans
#    post-bootstrap/, appliquée par Argo en wave -1) et ne routera qu'après gateway-api
#    + cert-manager. Port-forward, donc.
kubectl -n argocd port-forward svc/argocd-server 8080:443

# 6. Lancer le tier-1 → ArgoCD déploie tout le reste dans l'ordre des sync-waves
kubectl apply -f k8s/root.yaml
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
  `application.resourceTrackingMethod: annotation`. ⚠️ Le bloc `oidc.config` (SSO authentik) y est
  **commenté** : authentik est archivé
- `manifests/argocd-rbac-cm.yaml` — patch RBAC : défaut `role:readonly`, groupe authentik
  `app-argocd-admin` → `role:admin`. ⚠️ **Non appliqué** : la ligne est commentée dans
  `manifests/kustomization.yaml`, le patch n'ayant de sens qu'avec le SSO
- `manifests/argocd-notifications-cm.yaml` — patch notifications : service Grafana, templates,
  triggers, souscriptions globales (cf. §Notifications)
- `post-bootstrap/argocd-httproute.yaml` — UI via `shared-gw` (cf.
  [doc/reseau.md](../../../doc/reseau.md))
- `post-bootstrap/repo-homelab-gitops-github.sealed.yaml` — `SealedSecret`
  `repo-homelab-gitops-github`, le credential GitHub App avec lequel `argocd-repo-server` clone
  **ce dépôt**, privé (cf. §Accès au dépôt privé). ⚠️ Il ne suffit pas à l'amorçage : le Secret est d'abord posé à la main (étape 3 du
  TL;DR), ce SealedSecret ne fait que le **reprendre en gestion**
- `post-bootstrap/repo-homelab-gitops-github.secret.example.yaml` — template de scellement, versionné et
  sans valeur, porteur de la procédure. Jamais dans `kustomization.yaml`
- `manifests/argocd-notifications-secret.yaml` — patch qui pose
  `sealedsecrets.bitnami.com/managed: "true"` sur le Secret livré **vide** par l'upstream, sans
  quoi le contrôleur sealed-secrets refuse d'y écrire (cf. §Notifications)
- `manifests/argocd-secret.yaml` — patch qui pose `sealedsecrets.bitnami.com/patch: "true"` sur
  `argocd-secret`. ⚠️ **`patch` et non `managed`**, et l'écart est load-bearing : `managed`
  remplacerait l'objet entier, donc `server.secretkey` et le hash admin qu'Argo y écrit lui-même
  (cf. §Webhook et l'encadré §Pourquoi le patch survit à la sync)
- `post-bootstrap/argocd-webhook.sealed.yaml` — `SealedSecret` **`argocd-secret`**, clé
  `webhook.github.secret` : le HMAC qui ferme `/api/webhook` aux livraisons non signées, aucun
  webhook n'étant branché (cf. §Webhook)
- `post-bootstrap/argocd-webhook.secret.example.yaml` — template de scellement, versionné et sans
  valeur, porteur de la procédure. Jamais dans `kustomization.yaml`
- `post-bootstrap/argocd-oidc.sealed.yaml` — `SealedSecret` `argocd-oidc`, clé `client-secret`
  (OIDC). **Présent dans le repo, mais sa ligne reste commentée** dans le `kustomization.yaml` :
  le SSO est désactivé faute d'authentik (cf. §SSO)
- `post-bootstrap/argocd-notifications.sealed.yaml` — `SealedSecret`
  `argocd-notifications-secret`, clé `grafana-api-key`. **Présent dans le repo, ligne également
  commentée** (cf. §Notifications)
- `manifests/cluster-bleu-kalecgos.yaml` — Secret de cluster qui **nomme le cluster local**
  `bleu-kalecgos` (sans lui : entrée `in-cluster` codée en dur). Aucun credential dedans → clair,
  rien à sceller (cf. §Nommage du cluster local)
> [!NOTE]
> **Tous les secrets de ce composant passent par [sealed-secrets](../sealed-secrets/README.md).**
> Ils transitaient auparavant par un backend de secrets externe, retiré du dépôt depuis : la CRD
> `ExternalSecret` n'existe plus dans le cluster et les manifestes correspondants ne s'appliquaient
> plus. La source de vérité est désormais le `.sealed.yaml` committé ici.

> [!IMPORTANT]
> **Deux dossiers, et la séparation est load-bearing.** `manifests/` est aussi la cible de
> l'`apply -k` manuel du bootstrap, exécuté quand seul ArgoCD tourne — donc **avant que le
> tier-1 n'ait posé la moindre CRD**. Tout objet d'un groupe d'API tiers y ferait échouer le
> geste d'amorçage sur `no matches for kind`. Ils vivent donc dans `post-bootstrap/`, déclaré
> comme **second `source`** de cette Application :
>
> | Objet | CRD posée par | Wave |
> |---|---|---|
> | `SealedSecret` (`repo-homelab-gitops-github`) | [sealed-secrets](../sealed-secrets/README.md) | `-8` |
> | `SealedSecret` (`argocd-secret`, webhook) | [sealed-secrets](../sealed-secrets/README.md) | `-8` |
> | `HTTPRoute` (UI) | [gateway-api](../gateway-api/README.md) | `-10` |
>
> ⚠️ Seuls `repo-homelab-gitops-github.sealed.yaml` et `argocd-webhook.sealed.yaml` sont effectivement
> dans le `kustomization.yaml` ; ceux d'OIDC et des notifications sont présents dans le dossier
> mais **commentés**.
>
> Les deux arrivent donc **après** l'amorçage manuel, mais **avant** la wave `-1` où Argo
> synchronise cette Application : le tour de piste est complet, la route et les secrets sont
> posés par Argo lui-même.
>
> **Le critère est « est-ce que ça CASSE l'apply d'amorçage », pas « est-ce que c'est utile à
> l'amorçage ».** Les patchs RBAC (groupe authentik) et notifications (Grafana, `k8s/app/`)
> ne servent à rien tant que leur interlocuteur n'existe pas, mais ils s'appliquent proprement et
> n'empêchent ni Argo de démarrer ni le compte local `admin` de fonctionner : ils restent dans
> `manifests/`. Les sortir coûterait cher pour rien — leur cible vivant dans l'install upstream
> de ce dossier, il faudrait l'en retirer par un `$patch: delete` et les reposer en ressources
> autonomes, qui écraseraient en silence les clés que l'upstream pourrait y ajouter un jour
> (`argocd-cm` en porte déjà 9 : `resource.exclusions` et les
> `resource.customizations.ignoreResourceUpdates.*`).

## Accès au dépôt privé

La source du GitOps est **`https://github.com/jbwittner/homelab_gitops.git`**, dépôt **privé**.
Toutes les `repoURL` du dépôt qui le visent portent cette chaîne exacte, et
`argocd-repo-server` s'authentifie sous l'identité d'une **GitHub App** installée sur ce seul
dépôt, permission `Contents: Read-only`. Le credential est le Secret `repo-homelab-gitops-github`
(`argocd.argoproj.io/secret-type: repository`, ns `argocd`) : App ID, Installation ID et clé
privée. ArgoCD en tire lui-même des jetons d'installation d'une heure — rien n'expire à la main.

> [!WARNING]
> **C'est le point de défaillance unique du moteur GitOps.** Si ce Secret disparaît, si l'App est
> désinstallée ou sa clé révoquée, **toutes** les Applications tombent en `ComparisonError` d'un
> coup — `argocd` compris, puisqu'il est self-managed. Autrement dit : l'outil avec lequel on
> diagnostiquerait est aussi la victime. Symptôme côté logs :
> `kubectl -n argocd logs deploy/argocd-repo-server`, en `authentication required` ou HTTP 401.
>
> ⚠️ Une installation qui **ne couvre pas le dépôt** ne rend pas 403 mais **404** : GitHub masque
> l'existence des dépôts privés. Le symptôme ressemble à une faute de frappe dans l'URL, pas à un
> problème de droits.

**Chemin réseau.** `argocd-repo-server` sort du cluster vers `github.com` en HTTPS. Conséquence à
connaître : **GitHub est une dépendance dure de la synchro GitOps**. Une panne ou une coupure
Internet ne casse rien de ce qui tourne (les objets restent en place), mais gèle toute
réconciliation et fait passer les Applications en `ComparisonError`.

**TLS : rien à faire.** Le certificat de `github.com` est signé par une CA publique, déjà dans le
magasin du conteneur `argocd-repo-server`. Pas de `tls-client-cert`, pas de CA à injecter, et
**`argocd-ssh-known-hosts-cm` ne joue aucun rôle** ici : une GitHub App ne s'authentifie qu'en
HTTPS (le ConfigMap reste livré par l'install upstream, simplement inutilisé pour ce dépôt).

**Pourquoi un geste manuel dans le bootstrap.** Le credential doit exister **avant le premier fetch
d'ArgoCD** : à cet instant ni la CRD `SealedSecret` (posée en wave `-8`) n'existe, ni le dépôt
n'est lisible. Un `SealedSecret` ne peut donc pas servir à ce moment-là. On casse l'œuf-poule avec
l'annotation `sealedsecrets.bitnami.com/managed: "true"` posée sur le Secret manuel : le contrôleur
sealed-secrets accepte alors d'écrire dans un objet qu'il n'a pas créé, et
`post-bootstrap/repo-homelab-gitops-github.sealed.yaml` le **reprend en gestion** dès la wave `-1`.
Après quoi la rotation repasse entièrement par Git. Même mécanique que
`manifests/argocd-notifications-secret.yaml` (cf. §Notifications).

⚠️ `--server-side` sur ce `kubectl apply` n'est pas cosmétique : en client-side, kubectl recopie
l'objet entier — donc la **clé privée en clair** — dans l'annotation
`kubectl.kubernetes.io/last-applied-configuration`, que le scellement ne nettoie jamais. Réparation
si le geste a déjà été fait sans le drapeau :

```bash
kubectl -n argocd annotate secret repo-homelab-gitops-github \
  kubectl.kubernetes.io/last-applied-configuration-
```

### Génération / rotation

Procédure complète — création de l'App, clé privée, installation, production du clair,
scellement, rotation — en commentaires dans
`post-bootstrap/repo-homelab-gitops-github.secret.example.yaml`. Ce qui s'y joue d'irréversible :

- **Permissions de l'App : `Contents: Read-only`, et rien d'autre.** Un droit en écriture ferait
  de ce credential le seul du dispositif capable de réécrire l'état désiré du cluster.
- **Installation sur `homelab_gitops` seul**, jamais « All repositories » : ce serait donner au
  cluster la lecture de tous les dépôts privés du compte.
- **En rotation, la nouvelle clé d'abord** : générer, resceller, attendre que le Secret soit à jour
  dans le cluster, **puis** supprimer l'ancienne côté GitHub. Dans l'autre ordre, fenêtre pendant
  laquelle plus rien ne synchronise.

⚠️ Le `SealedSecret` est chiffré pour le couple (`repo-homelab-gitops-github`, `argocd`) : le
renommer ou le déplacer de namespace le rend indéchiffrable. ⚠️ Vérifier le **contenu** du
`.sealed.yaml`, pas son existence — un fichier scellé vide ne fait pas échouer `kustomize build`,
il ne rend rien.

⚠️ Le champ `url` du Secret doit être **strictement** la chaîne des `repoURL`, suffixe `.git`
compris : ArgoCD apparie credential et source par égalité d'URL normalisée. Un décalage ne produit
aucune erreur de configuration, juste un clone anonyme — qui rendra 404, le dépôt étant privé.

> [!WARNING]
> **`k8s/root.yaml` ne se met PAS à jour tout seul.** C'est le seul objet `Application` du
> dispositif que rien ne gère : il est appliqué à la main au bootstrap, et aucune Application ne
> le prend pour cible (il en serait sinon son propre parent). Toute modification de `root.yaml` —
> **son `repoURL` au premier chef** — exige donc un ré-apply manuel :
>
> ```bash
> kubectl apply -f k8s/root.yaml --server-side --force-conflicts
> ```
>
> **C'est le piège numéro un d'un changement de source**, et il s'est déjà produit : les
> `repoURL` étaient à jour dans Git, les Applications enfants avaient été mises à jour par
> `root`… et `root` lui-même clonait encore l'ancienne URL. Tout était `Synced`/`Healthy`, parce
> que l'ancienne source répondait toujours. Contrôle qui l'attrape — **une seule ligne attendue,
> en `https://github.com/`** :
>
> ```bash
> kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.spec.source.repoURL}{"\n"}{range .spec.sources[*]}{.repoURL}{"\n"}{end}{end}' \
>   | grep jbwittner | sort | uniq -c
> ```

### Vérifier

> [!WARNING]
> **Ne PAS vérifier avec un `git` nu dans le pod.**
>
> ```bash
> kubectl -n argocd exec deploy/argocd-repo-server -- \
>   git ls-remote https://github.com/jbwittner/homelab_gitops.git   # ✗ INUTILE
> ```
>
> Cette commande échoue **toujours** — en `authentication required` ou 404 —, y compris quand tout
> est correct. ArgoCD n'écrit jamais le credential sur le disque du conteneur : il le matérialise à
> la volée, par clone. Un `git` lancé à la main dans le pod n'hérite de rien et teste le vide.
> C'est un faux négatif, pas un symptôme — et il coûte du temps parce qu'il ressemble exactement à
> un credential invalide.

**1. La portée de l'App est-elle bien en lecture seule, sur un seul dépôt ?** Un credential trop
large passe tous les tests ci-dessous sans que rien ne le signale. Le contrôle se fait dans l'UI
GitHub, pas depuis le cluster : page de l'App → *Permissions & events* (seul `Contents:
Read-only`, plus le `Metadata` imposé), et `github.com/settings/installations/<ID>` (seul
`homelab_gitops` sélectionné).

**2. ArgoCD, lui, voit-il le credential ?** C'est la seule vérification qui exerce le vrai chemin :

```bash
argocd repo list            # CONNECTION STATUS = Successful
# ou UI : Settings → Repositories
```

**3. Bout en bout** — aucune Application en `ComparisonError` :

```bash
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get applications
kubectl -n argocd logs deploy/argocd-repo-server --tail=50 | grep -i 'auth\|fatal\|401\|404'
```

**4. Le `SealedSecret` a bien repris l'objet posé à la main** (sinon la rotation par Git est un
leurre : le Secret reste celui du bootstrap) :

```bash
kubectl -n argocd get secret repo-homelab-gitops-github -o jsonpath='{.metadata.ownerReferences}'
```


## Webhook — aucun, la sync se fait au polling

ArgoCD découvre un commit à son **polling**, toutes les **3 min** par Application
(`timeout.reconciliation`, défaut amont non surchargé ici). **Aucun webhook ne l'accélère** :
GitHub ne joint pas le LAN, et `argocd.lan.wittner.tech` n'est servi qu'au reverse proxy
`192.168.1.50`. L'App GitHub a d'ailleurs son webhook désactivé (cf.
`post-bootstrap/repo-homelab-gitops-github.secret.example.yaml`, étape 1).

> [!IMPORTANT]
> **Le polling est le mécanisme, pas un filet.** Allonger `timeout.reconciliation` retarde
> d'autant chaque déploiement, et il n'y a rien derrière pour rattraper. Un commit poussé se voit
> au plus 3 min plus tard ; pour l'avoir tout de suite :
> `kubectl -n argocd annotate app <nom> argocd.argoproj.io/refresh=normal --overwrite`.

### Pourquoi `webhook.github.secret` reste posé

`/api/webhook` **n'est pas protégé par une session ArgoCD** : c'est un endpoint anonyme, par
conception, et il reste joignable depuis le LAN par l'`HTTPRoute` de l'UI
(`post-bootstrap/argocd-httproute.yaml`, `PathPrefix: /`). Ce qui l'authentifie est un HMAC — et
**sans clé configurée, ArgoCD accepte toute livraison non signée** : n'importe qui sur le LAN
pourrait déclencher en boucle des refresh de tout le parc, donc des clones sur
`argocd-repo-server`. La clé `webhook.github.secret`, posée par
`post-bootstrap/argocd-webhook.sealed.yaml`, ferme cette porte sans que personne ne la connaisse.

⚠️ Le nom compte : ArgoCD ne connaît que `webhook.github.secret`, `webhook.gitlab.secret`,
`webhook.gogs.secret`, `webhook.bitbucket.uuid`, `webhook.bitbucketserver.secret`,
`webhook.azuredevops.username`/`.password`. Toute autre clé est **ignorée en silence** — et
l'endpoint redevient ouvert sans que rien ne le dise.

> [!NOTE]
> Rebrancher un webhook GitHub demanderait d'exposer `/api/webhook` hors du LAN — et seulement ce
> chemin, pas l'UI. Côté GitHub, la livraison est signée en `X-Hub-Signature-256` avec la valeur
> de `webhook.github.secret`, que le webhook du dépôt (Settings → Webhooks, `application/json`,
> événement *push*) devrait alors porter. Rien de cela n'est en place.

### Vérifier

```bash
# 1. La clé est arrivée — ET les trois autres sont toujours là. C'est le contrôle qui prouve que
#    le mode `patch` a fait son travail : trouver `webhook.github.secret` SEUL ici voudrait dire
#    que le Secret a été remplacé et que `server.secretkey` et le mot de passe admin sont perdus.
kubectl -n argocd get secret argocd-secret -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
#   attendu : admin.password, admin.passwordMtime, server.secretkey, webhook.github.secret

# 2. Le SealedSecret n'a PAS pris la propriété de l'objet (mode `patch`) : doit être VIDE.
kubectl -n argocd get secret argocd-secret -o jsonpath='{.metadata.ownerReferences}' ; echo

# 3. Une livraison NON signée doit être refusée — attendu : un 4xx. Un 200 voudrait dire que la
#    clé n'est pas lue (nom de clé, ou patch non appliqué) et que l'endpoint est ouvert.
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'X-GitHub-Event: push' \
  -H 'Content-Type: application/json' -d '{}' https://argocd.lan.wittner.tech/api/webhook
```

### Rotation

Refaire les étapes 1-2 de `post-bootstrap/argocd-webhook.secret.example.yaml` et committer le
`.sealed.yaml`. Aucun émetteur ne porte la valeur : rien d'autre à mettre à jour.


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
> Arrivé pour de vrai : le PVC d'un StatefulSet, détruit par un prune lors d'un passage de 2 à 1
> replica — et avec lui le LV, `openebs-lvm-thin` étant en
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
> coup (le `caBundle` d'un webhook, le `/data` d'un token de ServiceAccount). Ces exceptions-là
> restent nécessaires.

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

## Compte admin local — mot de passe

Le mot de passe **n'est pas en Git** et n'a pas vocation à y être : c'est de l'état vivant du
cluster, un hash **bcrypt** dans la clé `admin.password` du Secret `argocd-secret` (ns `argocd`).
Le SSO authentik étant désactivé, ce compte est aujourd'hui le **seul** moyen d'entrer.

### Changer le mot de passe — `kubectl` seul

Aucune CLI `argocd` à installer, aucun login préalable : le hash bcrypt se calcule **dans le
cluster**, avec le binaire déjà présent dans l'image argocd-server. `argocd account bcrypt` est un
calcul purement local au binaire — il ne parle pas à l'API server d'Argo, il n'ouvre pas de
session, il ne lit rien : c'est un `bcrypt()` en ligne de commande. Le geste marche donc même
mot de passe courant perdu.

```bash
# 1. Produire le hash (coût 10). Sortie : $2a$10$…
kubectl -n argocd exec deploy/argocd-server -- argocd account bcrypt --password '<nouveau>'

# 2. L'écrire, en bumpant passwordMtime dans le MÊME patch (cf. encadré).
kubectl -n argocd patch secret argocd-secret -p \
  '{"stringData": {"admin.password": "<hash $2a$10$…>", "admin.passwordMtime": "'$(date -u +%FT%TZ)'"}}'

# 3. Vérifier la prise en compte (le hash est relu à chaud, AUCUN redémarrage nécessaire).
kubectl -n argocd get secret argocd-secret \
  -o jsonpath='{.data.admin\.passwordMtime}' | base64 -d ; echo
```

> [!IMPORTANT]
> **`admin.passwordMtime` fait partie du geste, ce n'est pas de la cosmétique.** ArgoCD rejette
> tout JWT émis *avant* cette date : la bumper déconnecte les sessions ouvertes, ce qui est le
> comportement attendu d'une rotation. L'oublier laisse une session volée valide jusqu'à son
> expiration naturelle.
>
> Le format doit être du **RFC3339**, d'où le `date -u +%FT%TZ` (`2026-01-31T09:12:00Z`). Un
> `date +%FT%T%Z` — la forme qui traîne dans la FAQ upstream — produit `…09:12:00UTC`, que Go ne
> sait pas parser. Et le parse est fait en `if err == nil` (`util/settings/accounts.go`) : ArgoCD
> **ignore l'erreur en silence**, l'invalidation ne se fait pas, rien ne le signale. Le champ
> reste faux jusqu'au prochain démarrage d'`argocd-server`, qui le réécrit alors à l'heure
> courante (`Initialized admin mtime` dans ses logs) — les sessions sautent donc à un moment
> imprévisible plutôt qu'au moment de la rotation. La vérification de l'étape 3 relit ce qui a
> réellement été écrit.

Après le premier changement, supprimer le Secret d'amorçage — ArgoCD ne le fait pas tout seul et
il contient le mot de passe initial **en clair** :

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
```

**Si l'`exec` n'est pas possible** (pod down, droits RBAC absents), le hash se calcule en local
avec n'importe quelle implémentation bcrypt — l'étape 2 ne change pas :

```bash
htpasswd -bnBC 10 "" '<nouveau>' | tr -d ':\n' ; echo          # apache2-utils
python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' '<nouveau>'
```

> [!TIP]
> Avec la CLI `argocd` installée **et** une session ouverte, `argocd account update-password` fait
> les deux étapes (hash + mtime) en une commande. C'est plus court, mais ça suppose de connaître
> le mot de passe courant — la voie `kubectl` ci-dessus reste le geste de référence, et le seul
> qui marche en break-glass.

### Pourquoi le patch survit à la sync (et ce qu'il ne faut pas sceller)

`argocd-secret` est livré **VIDE** par l'install.yaml upstream (`type: Opaque`, aucun champ
`data`) — c'est exactement le cas d'`argocd-notifications-secret`. Argo l'applique en
server-side apply sans jamais posséder la clé `admin.password` : `selfHeal: true` ne l'efface
donc pas, et le mot de passe survit aux syncs comme aux redémarrages.

> [!CAUTION]
> **Ne jamais mettre `argocd-secret` en `SealedSecret` `managed`.** Le Secret ne porte pas que le
> hash admin : `argocd-server` y génère aussi `server.secretkey`, la clé de signature des JWT. Un
> `SealedSecret` en mode `managed` en prendrait la propriété et **remplacerait l'objet entier** —
> toutes les sessions invalidées à chaque sync, le mot de passe admin perdu (c'est-à-dire le seul
> moyen d'entrer, le SSO étant désactivé), et la suppression du `SealedSecret` emporterait le
> Secret avec elle. Le mot de passe admin est un secret **de break-glass**, il se gère à la main
> dans le cluster et n'a pas vocation à être en Git.
>
> ⚠️ **Il y a pourtant un `SealedSecret` nommé `argocd-secret` dans ce dossier**
> (`post-bootstrap/argocd-webhook.sealed.yaml`, cf. §Webhook) — et ce n'est pas une
> entorse : il porte `sealedsecrets.bitnami.com/patch: "true"`, pas `managed`. En mode `patch` le
> contrôleur **ajoute** les clés qu'il porte et ne supprime ni les autres clés, ni les labels, ni
> les annotations, et **ne prend pas la propriété** de l'objet. C'est le seul mode acceptable
> ici : tout ce qui écrit dans `argocd-secret` depuis Git doit y écrire en `patch`.

Désactiver complètement le compte local (`admin.enabled: "false"` dans `argocd-cm`) n'a de sens
qu'une fois le SSO rétabli — voir ci-dessous. En l'état ce serait se verrouiller dehors.

## SSO — authentik (OIDC) — DÉSACTIVÉ

> [!IMPORTANT]
> **Le SSO n'est pas actif.** [authentik](../../../archive/authentik/README.md) est archivé, donc :
> le bloc `oidc.config` d'`argocd-cm.yaml` est commenté, le patch `argocd-rbac-cm.yaml` n'est pas
> dans le `kustomization.yaml`, et `argocd-oidc.sealed.yaml` — bien que présent dans le dossier —
> reste commenté lui aussi. **Le compte local `admin` est aujourd'hui le seul moyen d'entrer.**
>
> La procédure ci-dessous reste la spécification de remise en service, à jouer telle quelle le jour
> où un fournisseur OIDC revient.

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
  < k8s/infra/argocd/post-bootstrap/argocd-oidc.secret.yaml \
  > k8s/infra/argocd/post-bootstrap/argocd-oidc.sealed.yaml

# 3. Supprimer le clair, décommenter `argocd-oidc.sealed.yaml` dans
#    post-bootstrap/kustomization.yaml (+ le bloc oidc.config d'argocd-cm.yaml), committer.
rm k8s/infra/argocd/post-bootstrap/argocd-oidc.secret.yaml
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
  < k8s/infra/argocd/post-bootstrap/argocd-notifications.secret.yaml \
  > k8s/infra/argocd/post-bootstrap/argocd-notifications.sealed.yaml

# 4. Supprimer le clair, décommenter `argocd-notifications.sealed.yaml` dans
#    post-bootstrap/kustomization.yaml, committer.
rm k8s/infra/argocd/post-bootstrap/argocd-notifications.secret.yaml
```

**Où les voir** : une annotation Grafana ne s'affiche **nulle part** par défaut — il faut qu'un
dashboard la requête par tag. La couche « Déploiements ArgoCD » (tags `argocd` + `deployed`) est
déclarée dans `dashboard-machines.yaml` (ex-`dashboard-talos-nodes.yaml`, renommé le 2026-09-11), et les 3 tags (`deployed` / `degraded` /
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
