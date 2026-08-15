# openbao

## Rôle

Gestionnaire de secrets (fork libre de Vault), stockage **raft intégré**, un replica. C'est
l'un des deux canaux de secrets du repo, à côté de
[`sealed-secrets`](../sealed-secrets/README.md), et il porte la quasi-totalité d'entre eux — sept
des huit. Différence entre les deux : l'emplacement du chiffré, **dans Git** pour un `SealedSecret`,
**dans le PVC** pour openbao. Il n'est pas consommé directement : c'est
[external-secrets](../external-secrets/README.md) qui en tire des `Secret` Kubernetes natifs.
Critère de choix entre les deux canaux :
[`doc/regles-gitops.md`](../../../doc/regles-gitops.md). UI exposée sur
`openbao.lan.wittner.tech`, login humain en **SSO authentik** (OIDC), token root conservé en
break-glass — cf. Opérations.

## Contenu du coffre

Les secrets servis, tous en KV **v2** monté sur `kv` (les `remoteRef.key` des `ExternalSecret`
s'écrivent sans le suffixe `/data`, ajouté par ESO) :

| Chemin KV | Clés | Consommateur |
|---|---|---|
| `homelab/argocd/oidc` | `client-secret` | [argocd](../argocd/README.md) |
| `homelab/argocd/notifications` | `grafana-api-key` | [argocd](../argocd/README.md) |
| `homelab/authentik/secrets` | `secret-key` | [authentik](../../app/authentik/README.md) |
| `homelab/cert-manager/cloudflare` | `api-token` | [cert-manager-config](../cert-manager-config/README.md) — solver DNS-01, consommé en wave `-4` (cf. Contraintes) |
| `homelab/grafana/admin` | `admin-user`, `admin-password` | [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md) |
| `homelab/grafana/oidc` | `client-secret` | [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md) |
| `homelab/renovate/github` | `token` | [renovate](../../app/renovate/README.md) |

## Fichiers

- `openbao.app.yaml` — Application (archétype (b) : Helm + `$values` + `manifests/`), ns
  `openbao`, wave `1`
- `helm-values.yaml` — raft 1 replica + `retry_join`, injector, télémétrie serveur
  (`unauthenticated_metrics_access` + `prometheus_retention_time`), rétention du PVC. Le
  ServiceMonitor du chart y est **coupé volontairement** : il est porté par
  [openbao-monitoring](../openbao-monitoring/README.md) (voir le commentaire du fichier)
- `manifests/namespace.yaml` — ns `openbao` (wave -1), sans label PodSecurity
- `manifests/openbao-httproute.yaml` — UI sur le listener `https-internal` de `shared-gw`
- `openbao-script.sh` — gestion des sauvegardes : `status`, `list`, `snapshot`, `fetch`, `check`,
  `verify`, `stop`, `restore`. Pas déployé, pas référencé par le `kustomization.yaml` : ce sont
  des ÉVÉNEMENTS (un snapshot, un restore), pas des états désirés — committés, ArgoCD les
  rejouerait sans fin. Même statut que `velero-script.sh` côté [velero](../velero/README.md)
- `manifests/openbao-snapshot-s3.secret.yaml` — **clair, gitignoré** : template d'entrée de
  `kubeseal` pour les credentials S3 de la sauvegarde (`AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`). Le produit scellé, `openbao-snapshot-s3.sealed.yaml`, est le seul des
  deux qui se committe — et la ligne correspondante du `kustomization.yaml` reste **commentée**
  tant qu'il n'existe pas (cf. Opérations)

## Contraintes

- **OpenBao démarre scellé.** Après chaque redémarrage d'un pod, il faut le desceller à la main
  (voir Opérations), **pod par pod** : les clés de descellement ne transitent pas entre pairs
  raft. Tant qu'il l'est, l'API répond `503` et le pod n'est pas `Ready` — c'est attendu, pas une
  panne.
- **Monter en HA : 1 → 3, jamais 2, et autant de nœuds que de replicas.** Le quorum raft est la
  majorité stricte : à 2 replicas il en faut 2, soit zéro panne tolérée pour deux fois la surface
  de panne d'un nœud unique — strictement pire que 1. À 3, la perte d'un nœud est absorbée. Et
  l'anti-affinité du chart est `requiredDuringScheduling` sur `kubernetes.io/hostname` : un
  replica de plus que de nœuds reste `Pending` indéfiniment.
- **Redescendre : `remove-peer` AVANT de baisser `replicas`.** Un scale down ne retire pas le
  pair de la configuration raft. Le quorum reste calculé sur des votants devenus injoignables, le
  nœud survivant part en élection perpétuelle (`failed to make requestVote RPC … no such host`,
  `HA Mode: standby` sans leader, `/v1/sys/health` en `429`) — et on ne peut plus en sortir par
  l'API, puisque retirer un pair est *lui-même* une écriture raft qui exige le quorum perdu.
  Séquence en Opérations.
- **Sans `retry_join`, un nouveau pod ne rejoint jamais le raft.** Son PVC est vide, il démarre
  `Initialized false` + `Sealed true`, la readiness probe échoue, et il reste `0/1` pour
  toujours — sans rien dans les logs qui ressemble à une erreur. Les stanzas `retry_join` du
  `helm-values.yaml` pointent chaque pod via le Service **headless** `openbao-internal` ; un
  nœud qui a déjà un état raft les ignore.
- **Un coffre scellé ne casse rien, mais teinte le mur en rouge.** Les `ExternalSecret` qui en
  dépendent passent `NotReady`, donc les Applications `argocd`, `authentik`,
  `cert-manager-config`, `kube-prometheus-stack` et `renovate` passent `Degraded` — alors que
  leurs charges tournent normalement, les `Secret` déjà matérialisés étant conservés
  (`deletionPolicy: Retain`). Ce n'est pas une panne applicative : c'est le signal que les
  secrets ne se rafraîchissent plus. Depuis
  [openbao-monitoring](../openbao-monitoring/README.md), cet état lève aussi une alerte
  (`OpenBaoNoActiveNode`, 15 min) — un coffre scellé ne se voyait jusque-là qu'au mur ArgoCD.
- **Scellé, le coffre n'est pas seulement `NotReady` : il devient invisible pour Prometheus.**
  Sans leader, le Service `openbao-active` perd son endpoint et la cible de scrape disparaît au
  lieu de tomber à zéro. Toute règle d'alerte sur ce composant doit être écrite en `absent(…)`,
  jamais en `up == 0` (cf. [openbao-monitoring](../openbao-monitoring/README.md)).
- **Le coffre est désormais en amont de l'émission TLS, et il est en wave `1`.** Depuis la
  migration du token Cloudflare, [cert-manager-config](../cert-manager-config/README.md)
  (wave `-4`) tire son secret d'ici : au bootstrap à froid, **aucun certificat wildcard n'est
  émis avant le descellement manuel**, donc aucun listener TLS de `shared-gw` n'est programmé.
  L'ordre du runbook n'est pas modifié — mais ce qui attendait le coffre s'est élargi.
- **Wave `1`, après openebs.** Le coffre a un PVC : sans la StorageClass par défaut il reste
  `Pending`. Cet ordre n'existe que parce qu'openbao est un composant d'**infra** — les
  sync-waves ne s'ordonnent qu'à l'intérieur d'un même app-of-apps, donc `cluster/app/` et
  `cluster/infra/` se déroulent en parallèle, sans relation d'ordre entre eux.
- **Les clés de descellement et le token root ne vont JAMAIS dans Git**, même en `SealedSecret` :
  ce sont elles qui protègent tout le reste. Elles vivent au coffre, hors cluster, comme la clé
  privée sealed-secrets. Sans elles, le contenu du PVC est définitivement illisible.
- **Le PVC est protégé contre DEUX chemins de suppression distincts, par deux mécanismes qui
  vivent à des endroits différents. Les deux sont nécessaires.**
  1. Le **prune ArgoCD** : le PVC est créé par le `volumeClaimTemplates` du StatefulSet, pas par
     ArgoCD — mais il hérite du label `app.kubernetes.io/instance: openbao`. C'était le label de
     tracking par défaut d'ArgoCD, qui l'**adoptait** donc, et le supprimait dès qu'il sortait de
     l'ensemble désiré (un scale down suffit) ; avec `reclaimPolicy: Delete` sur
     openebs-lvm-thin, le LV partait avec. Détruit en vrai une fois (`data-openbao-1`, puis
     reprovisionné à vide). Fermé par `application.resourceTrackingMethod: annotation` dans
     [argocd](../argocd/README.md) (`manifests/argocd-cm.yaml`) — **la protection ne vit pas dans
     ce composant**.
  2. Le **GC du StatefulSet** (suppression du STS, passage à 0 replica) :
     `persistentVolumeClaimRetentionPolicy: Retain` des deux côtés, dans `helm-values.yaml`.

  ⚠️ Le point 2 ne protège **pas** du point 1 — c'est le piège, parce qu'il en donne
  l'impression. Ne retirer ni l'un ni l'autre.
- **L'HTTPRoute pointe sur le Service `openbao`, pas `openbao-active`.** Ce dernier ne sélectionne
  que les pods labellisés `openbao-active: "true"`, label posé une fois le nœud descellé et
  leader : un OpenBao scellé n'y a aucun endpoint, et l'UI serait injoignable exactement quand on
  en a besoin pour le desceller.
- **Le PDB est désactivé.** À un replica le chart calcule `maxUnavailable: 0` (`ALLOWED
  DISRUPTIONS: 0`), ce qui bloque indéfiniment tout `kubectl drain` du nœud sans protéger aucune
  HA. À réactiver en même temps que le passage à 3 replicas, où le chart calcule `1` et où il
  protège vraiment le quorum.
- **La cible Prometheus disparaît quand OpenBao est scellé** (le ServiceMonitor sélectionne le
  Service `-active`, sans endpoint dans cet état). Une alerte sur ce composant doit donc porter
  sur l'*absence* de la série, pas sur `up == 0`.
- **La configuration du coffre vit dans le repo Terraform, pas ici.** Le chart déploie le
  serveur, il ne configure rien à l'intérieur : méthode d'auth `kubernetes`, policies, roles et
  moteurs de secrets sont posés par le provider Terraform/OpenTofu qui gère déjà les providers
  OIDC authentik. Le **contrat** attendu par
  [external-secrets](../external-secrets/README.md) — et sans lequel les sept `ExternalSecret`
  échouent en `permission denied` :
  - un moteur KV **v2** monté sur `kv` ;
  - **un mount d'auth `kubernetes` par cluster**, nommé `kubernetes-<cluster>` — une méthode
    d'auth est configurée pour UN API server (issuer, CA, TokenReview), un mount partagé ne
    saurait pas valider les tokens des autres clusters. Pour un **spoke**, le mount exige en
    plus `kubernetes_host`, `kubernetes_ca_cert` et un `token_reviewer_jwt` : openbao n'a aucun
    accès local à l'API TokenReview d'un cluster distant ;
  - dans chaque mount, un role `external-secrets` borné au ServiceAccount `external-secrets` du
    namespace `external-secrets` ;
  - une policy en **lecture** sur `kv/data/homelab/*` attachée à ces roles ;
  - pour le **login humain**, un mount d'auth `oidc` pointant sur le Provider authentik
    `openbao`, plus le groupe externe `app-openbao-admin` et sa policy — sans lui, seul le token
    root permet d'entrer. Détail : [`doc/openbao-terraform.md`](../../../doc/openbao-terraform.md) §5.

  Rien côté `cluster/` ne vérifie ce contrat : le repo GitOps déclare le consommateur, le repo
  Terraform déclare le producteur, et la seule preuve que les deux s'accordent est l'état
  `Ready` des `ExternalSecret`.
- **Le SSO du coffre dépend d'un composant que le coffre alimente.** authentik tire son
  `secret-key` de `kv/homelab/authentik/secrets` : une reconstruction complète part donc
  forcément du **token root**, pas du login authentik. C'est aussi vrai à froid — au bootstrap,
  authentik n'existe pas encore quand il faut poser les sept secrets. L'OIDC est un confort
  d'exploitation, jamais un chemin d'amorçage.
- **L'OIDC fait sortir le pod vers un nom public.** Pour valider un login, openbao va chercher le
  document de découverte et les JWKS sur `https://authentik.wittner.tech` — depuis l'intérieur du
  cluster. Même chemin que le SSO d'ArgoCD, déjà éprouvé, mais il tombe si le résolveur du réseau
  renvoie ce nom vers une IP injoignable en hairpin.
- **Ce que le coffre ne servira jamais.** Un secret dont openbao ou ESO a besoin pour
  fonctionner ne peut pas venir d'openbao. Concrètement : le jour où `snapshotAgent` poussera
  vers S3/MinIO, **ses credentials devront être un `SealedSecret`** — sinon la sauvegarde du
  coffre dépend du coffre. C'est le seul `SealedSecret` prévu dans ce composant
  (`openbao-snapshot-s3`, cf. Fichiers et Opérations) : tout autre secret d'ici doit passer par
  le coffre. Même raisonnement pour le secret resté scellé — le Secret de cluster
  du spoke (cf. [`doc/regles-gitops.md`](../../../doc/regles-gitops.md)).
- **L'agent injector n'est utilisé par aucun composant.** Il injecte des *fichiers dans des
  pods*, or les huit consommateurs du repo exigent tous un `Secret` natif (`existingSecret`,
  `secretKeyRef`, `envFrom`, `$secret:clé` d'ArgoCD, Secret de cluster). C'est ESO qui fait le
  travail ; l'injector reste activé par défaut du chart, sans usage à ce jour.

## SSO — authentik (OIDC)

Login **humain** sur l'UI et sur la CLI `bao`, par le même fournisseur d'identité que
[argocd](../argocd/README.md) et [grafana](../../app/kube-prometheus-stack/README.md). Le
Provider / Application / groupe côté authentik **et** le mount côté coffre sont posés par le repo
**Terraform** (autre repo) : rien ici, le chart ne configure pas l'intérieur du coffre. Contrat —
détail et code HCL dans [`doc/openbao-terraform.md`](../../../doc/openbao-terraform.md) §5 :

| Élément | Valeur |
|---|---|
| `clientID` | `openbao`, client **confidentiel** |
| Issuer | `https://authentik.wittner.tech/application/o/openbao/` |
| Scopes | `openid profile email groups` |
| Mount d'auth | `oidc`, role `default` (`user_claim: sub`, `groups_claim: groups`) |
| Groupe admin | **`app-openbao-admin`** → policy `openbao-admin` (groupe **externe** + alias) |
| Redirect URIs | `https://openbao.lan.wittner.tech/ui/vault/auth/oidc/oidc/callback` (UI) et `http://localhost:8250/oidc/callback` (CLI) |

Trois pièges, tous vérifiés à la connexion :

- **Le segment `vault` de l'URI de callback n'est pas une faute** : l'UI d'OpenBao est un fork de
  celle de Vault et a gardé ses routes. Le `oidc/oidc` non plus : c'est *auth/`<mount>`/oidc/callback*.
- **Le `client-secret` ne va PAS au coffre**, contrairement à ceux d'ArgoCD et de Grafana : ici le
  consommateur *est* le coffre, la valeur vit déjà dans sa config d'auth. Pas d'`ExternalSecret`,
  pas d'entrée dans la table « Contenu du coffre » — et surtout pas de secret nécessaire au login
  rangé derrière ce login (règle anti-cycle de
  [`doc/regles-gitops.md`](../../../doc/regles-gitops.md)).
- **Le token root reste le break-glass et ne se supprime pas** : l'OIDC ajoute un chemin d'entrée,
  il n'en retire aucun. authentik en panne — ou dont le `secret-key` vient justement du coffre —
  ne doit pas fermer la porte (cf. Contraintes, « Le SSO du coffre dépend d'un composant que le
  coffre alimente »).

## Opérations

- **Initialiser** (une seule fois, à la première installation) — conserver la sortie au coffre :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao operator init
  ```
- **Desceller** (après chaque redémarrage) — répéter avec 3 parts de clé distinctes :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao operator unseal
  kubectl -n openbao exec -ti openbao-0 -- bao status     # Sealed=false, HA Mode=active
  ```
  En HA, **un pod par un pod** : raft réplique le stockage *chiffré*, pas la master key. Les
  parts ne transitent jamais entre pairs, un nœud scellé ne se fait pas desceller par le leader.
  N pods = N descellements après chaque redémarrage.
- **Changer le nombre de replicas.** Monter est direct (`replicas: N`, commit, push, puis
  desceller chaque nouveau pod). **Redescendre exige de retirer le pair D'ABORD**, sinon le
  quorum est perdu et on ne peut plus le récupérer par l'API :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao login                        # token root
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft remove-peer openbao-2
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers     # le pair a disparu
  # SEULEMENT ensuite : baisser `replicas` dans helm-values.yaml, commit, push
  ```
  Le PVC du pod retiré survit (`whenScaled: Retain` + `Prune=false`) : le supprimer à la main,
  sinon il sera réutilisé tel quel — avec un état raft périmé — à la prochaine remontée.
  Un pod qui rejoint le raft pour la **première fois** (PVC neuf) doit être descellé avec les
  parts du cluster existant, pas réinitialisé : `bao operator init` ne se lance qu'une fois, sur
  `openbao-0`.
- **Se connecter en SSO authentik** (cf. §SSO ; suppose le coffre descellé et le mount `oidc`
  posé par Terraform). UI : `https://openbao.lan.wittner.tech` → méthode **OIDC** dans le menu
  déroulant. CLI, depuis la racine du repo — un navigateur s'ouvre, le callback revient sur un
  listener local `:8250` :
  ```bash
  BAO_ADDR=https://openbao.lan.wittner.tech bao login -method=oidc
  BAO_ADDR=https://openbao.lan.wittner.tech bao token capabilities kv/data/homelab/grafana/oidc
  ```
  La seconde commande doit renvoyer les capacités de `openbao-admin`. `deny` seul = le token est
  valide mais le groupe n'a pas été reconnu — comparer au caractère près le nom du groupe
  authentik et l'alias côté coffre. Si la méthode **OIDC** n'apparaît pas dans le menu de l'UI,
  c'est le `listing_visibility = "unauth"` qui manque sur le mount. Table complète des
  symptômes : [`doc/openbao-terraform.md`](../../../doc/openbao-terraform.md).
- **Sauvegarder le coffre** (à chaud, possible grâce au backend raft) :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft snapshot save /tmp/openbao.snap
  kubectl -n openbao cp openbao-0:/tmp/openbao.snap ./openbao.snap
  ```
  Le snapshot contient **tout le coffre chiffré** : le traiter comme un secret, et le stocker
  hors cluster. Il reste inutile sans les clés de descellement. Le chart embarque un CronJob de
  snapshot automatique (`snapshotAgent`), non activé : il ne sait pousser que vers S3, et le
  homelab n'a ni bucket ni MinIO. Le jour où l'un des deux existe, c'est la voie à privilégier
  plutôt qu'un CronJob maison.
- **Sceller les credentials S3 de la sauvegarde** — depuis la racine du repo, cert public récupéré
  au préalable (cf. [sealed-secrets](../sealed-secrets/README.md)) :
  ```bash
  # 1. Renseigner les deux valeurs dans le template en clair (gitignoré)
  $EDITOR cluster/infra/openbao/manifests/openbao-snapshot-gcs.secret.yaml

  # 2. Sceller — le chiffré est lié au couple (openbao-snapshot-gcs, openbao)
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
    < cluster/infra/openbao/manifests/openbao-snapshot-gcs.secret.yaml \
    > cluster/infra/openbao/manifests/openbao-snapshot-gcs.sealed.yaml

  # 3. Supprimer le clair, décommenter la ressource dans manifests/kustomization.yaml, committer
  rm cluster/infra/openbao/manifests/openbao-snapshot-gcs.secret.yaml
  ```
  L'ordre des étapes 2 et 3 n'est pas cosmétique : décommenter la ressource **avant** que le
  `.sealed.yaml` existe casse le `kustomize build`, donc la sync de toute l'Application openbao,
  pas seulement du secret. Rotation : refaire les trois étapes et committer — contrairement aux
  secrets servis par le coffre, un scellé se refait passer par Git.
- **Restaurer** :
  ```bash
  kubectl -n openbao cp ./openbao.snap openbao-0:/tmp/openbao.snap
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft snapshot restore /tmp/openbao.snap
  ```
- **Gérer et TESTER les sauvegardes** — tout passe par `openbao-script.sh` :
  ```bash
  cluster/infra/openbao/openbao-script.sh status            # coffre, CronJob, âge du dernier snapshot
  cluster/infra/openbao/openbao-script.sh list              # snapshots du bucket + Jobs
  cluster/infra/openbao/openbao-script.sh snapshot          # sauvegarde manuelle (Job dérivé du CronJob)
  cluster/infra/openbao/openbao-script.sh verify latest     # RESTORE réel en Docker — aucune clé requise
  cluster/infra/openbao/openbao-script.sh verify oldest --unseal   # + descellement et contenu

  cluster/infra/openbao/openbao-script.sh up oldest         # idem mais l'instance SURVIT
  cluster/infra/openbao/openbao-script.sh unseal            # la desceller après coup
  cluster/infra/openbao/openbao-script.sh bao kv get -mount=kv homelab/argocd
  cluster/infra/openbao/openbao-script.sh stop              # la détruire
  ```
  La présence d'un objet dans le bucket ne prouve rien. `verify` remonte le snapshot dans un
  OpenBao jetable, l'y restaure, et vérifie que l'instance adopte la configuration de seal de la
  prod (`5 / 3`) : si c'est le cas, le keyring du snapshot a été ouvert et `state.bin` est intègre.
  Ce contrôle ne demande **aucune part de descellement** — c'est celui à passer régulièrement.
  `--unseal` va plus loin (parts de prod + token root) et compare le contenu au contrat dérivé des
  `ExternalSecret` du cluster. `verify` **détruit** l'instance en sortant ; `up` la **garde**, pour
  fouiller un coffre d'hier sans toucher la prod — conteneur `openbao-drill`, une seule instance à
  la fois, fermée par `stop`. Une instance descellée sert tous les secrets du homelab en clair sur
  `127.0.0.1:8210` : `status` la rappelle à chaque appel. Procédure manuelle et pièges détaillés :
  [`doc/openbao-restore-local.md`](../../../doc/openbao-restore-local.md).
  ⚠️ Ne jamais tester un restore sur `openbao-0` : `snapshot restore` écrase tout le raft. C'est
  précisément ce que fait `openbao-script.sh restore`, réservé à une vraie reprise.
- **Configurer le coffre** — c'est le **repo Terraform** qui pose l'auth `kubernetes`, le
  moteur KV, la policy et le role `external-secrets` (contrat détaillé en Contraintes). Les
  commandes ci-dessous ne servent qu'à **vérifier** l'état obtenu, en lecture :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao auth list      # kubernetes-<cluster>/ + oidc/
  kubectl -n openbao exec -ti openbao-0 -- bao secrets list
  kubectl -n openbao exec -ti openbao-0 -- bao read auth/kubernetes-bleu-kalecgos/role/external-secrets
  kubectl -n openbao exec -ti openbao-0 -- bao read auth/oidc/role/default
  kubectl -n openbao exec -ti openbao-0 -- bao list identity/group/name   # app-openbao-admin
  ```
- **Lire ou faire tourner un secret servi aux applications** (cf. table « Contenu du coffre ») —
  une rotation ne demande **ni commit, ni `kubeseal`, ni redéploiement**, c'est le gain
  principal du canal openbao sur le scellement :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao kv get kv/homelab/grafana/oidc
  kubectl -n openbao exec -ti openbao-0 -- bao kv put kv/homelab/grafana/oidc client-secret=…
  ```
  ESO reprend la nouvelle valeur au prochain `refreshInterval` (1 h) ; pour l'appliquer tout de
  suite, voir « forcer un rafraîchissement » dans
  [external-secrets](../external-secrets/README.md).
- **Upgrade** : bumper `targetRevision` dans `openbao.app.yaml`, commit, push. Le pod redémarre
  **scellé** — prévoir le descellement dans la foulée.
- **Debug** :
  ```bash
  kubectl -n openbao get pods,pvc,svc
  kubectl -n openbao logs openbao-0
  kubectl -n openbao exec -ti openbao-0 -- bao status
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers   # descellé requis
  kubectl get httproute -n openbao openbao -o yaml                        # Accepted/ResolvedRefs
  ```
  Si le pod échoue au démarrage sur une erreur `mlock` / `cannot allocate memory` : le chart pose
  `SKIP_SETCAP=true`, donc pas de capability `IPC_LOCK` (elle serait de toute façon refusée par
  le PodSecurity `baseline` de Talos). Le correctif est `disable_mlock = true` dans le bloc
  `config` de `helm-values.yaml`.
