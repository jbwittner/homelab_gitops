# cnpg-barman-plugin


> [!CAUTION]
> **RETIRÉ DU DÉPLOIEMENT LE 11 SEPTEMBRE 2026.** Le fichier `cnpg-barman-plugin.noapp.yaml` porte l'extension
> `.noapp.yaml` : il ne matche plus le glob du tier-2, l'`Application` a donc été *prunée* et son
> finalizer `resources-finalizer.argocd.argoproj.io` a emporté les ressources gérées.
>
> **Pourquoi :** il n'a plus rien à sauvegarder. Le seul `Cluster` CNPG sauvegardé a quitté le cluster avec son application ce jour-là. Le plugin restait déployé pour une base qui n'existait plus.
>
> **Ce qui restait au moment du retrait**, vérifié : **zéro `Cluster` CNPG et zéro `ObjectStore`** — le plugin était entièrement orphelin. ⚠️ Le bucket barman-cloud n'est PAS supprimé par ce retrait.
>
> **Pour le remettre :** renommer en `.app.yaml`. ⚠️ Remettre dans le même commit les trois règles `CNPG*Backup*` de [cnpg-monitoring](../cnpg-monitoring/README.md), commentées le même jour, ET recréer un `ObjectStore` — sans lui le plugin est déployé mais inerte, et les règles restent vertes en mentant.

## Rôle

Plugin **CNPG-I `barman-cloud`** : la sauvegarde native des bases [cnpg](../cnpg/README.md) vers un
stockage objet — sauvegardes de base **cohérentes-transaction** et **archivage WAL continu**, donc
PITR.

Composant séparé de `cnpg` parce que l'amont l'a séparé : depuis CloudNativePG **1.26**, le support
barman-cloud a été **sorti de l'opérateur** (`spec.backup.barmanObjectStore` déprécié puis retiré)
au profit d'un plugin distribué comme un chart et deux images à part. Deux charts, deux cadences de
release, deux `targetRevision` suivis séparément par Renovate → deux Applications.

> [!IMPORTANT]
> **Ce composant n'active aucune sauvegarde.** Il installe la mécanique et la CRD `ObjectStore`.
> Une base n'est prise en charge que si son `Cluster` porte explicitement `spec.plugins` — même
> logique de **liste blanche** que la schedule [velero](../../infra/velero/README.md).
>
> ⚠️ **Aujourd'hui : AUCUNE base sauvegardée.** La seule a quitté le cluster le 2026-09-11 ;
> `bankwiz-db` (dev) n'est pas sauvegardée. Les exemples de cette page utilisent `<ns>` et
> `<base>` : ils décrivent le câblage à refaire, en quatre gestes (§Opérations).

## Fichiers

- `cnpg-barman-plugin.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cnpg-system`,
  **wave `-1`**
- `helm-values.yaml` — Deployment du plugin uniquement : ressources, contextes de sécurité, CRD.
  Aucune configuration de bucket n'y vit

L'état des sauvegardes se lit dans le dashboard « PostgreSQL backups — barman-cloud »
(`manifests/dashboard-cnpg-barman-plugin.yaml` de
[kube-prometheus-stack](../kube-prometheus-stack/README.md)), pendant du dashboard velero. Il ne
regarde pas ce Deployment — qui ne transporte aucune donnée — mais les métriques du **sidecar**
servies sur l'endpoint 9187 de chaque pod d'instance, et les CRs `Backup` exposés par
kube-state-metrics.

## Contraintes

- **Le plugin DOIT tourner dans le namespace de l'opérateur** (`cnpg-system`) : c'est là que
  l'opérateur cherche le Service `barman-cloud:9090` de CNPG-I. Le déplacer ne produit aucune
  erreur de déploiement — seulement des `Cluster` dont le plugin reste injoignable.
- **Le nom du Service `barman-cloud` est câblé en dur dans les certificats.** Le values.yaml amont
  le dit en capitales : le nom DNS du certificat serveur en dérive. Le renommer casse le mTLS
  opérateur ↔ plugin, et le symptôme est un plugin injoignable, pas une erreur de rendu.
- **Deux pré-requis, dont un cross-tier** :
  - CloudNativePG **≥ 1.26** — ici **1.30.0** (chart `cloudnative-pg` 0.29.0) ;
  - **cert-manager** — le chart rend un `Issuer` auto-signé et **deux** `Certificate` (client et
    serveur). cert-manager vit dans `k8s/infra/`, donc dans un autre app-of-apps : aucune wave
    ne les ordonne. Au bootstrap à froid l'Application reste en erreur jusqu'à son arrivée, puis se
    répare seule (`selfHeal`).
- **Wave `-1`, et elle est load-bearing.** Ce composant apporte la CRD
  `objectstores.barmancloud.cnpg.io`, consommée par le `manifests/` de l'application qui possède
  une base sauvegardée (wave 0) — aucune aujourd'hui. Les deux vivant dans le **même** app-of-apps
  (`k8s/app/app.bootstrap.yaml`), la wave suffit à les ordonner — contrairement à la
  dépendance `<application> → cnpg`, qui n'est que documentée.
- **`crds.create` reste à `true`.** ArgoCD rend le chart avec `--include-crds` : la CRD fait partie
  de l'ensemble désiré et est réconciliée à chaque sync. La couper en pensant « elle est déjà là »
  la ferait **sortir** de l'ensemble désiré, et `prune: true` la supprimerait — emportant tous les
  `ObjectStore` avec elle.
- **Deux images, solidaires.** Le chart tire `plugin-barman-cloud` (le Deployment) *et*
  `plugin-barman-cloud-sidecar` (injecté dans chaque pod d'instance PostgreSQL). Les deux prennent
  l'appVersion du chart : ne pas épingler `image.tag` / `sidecarImage.tag` séparément.
- **Le travail réel est fait par le sidecar, pas par ce Deployment.** Celui-ci n'est qu'un serveur
  gRPC de contrôle et ne transporte aucune donnée. Les ressources qui comptent (upload, compression)
  se règlent **par `ObjectStore`**, dans `spec.instanceSidecarConfiguration.resources`.

## Où vit la configuration d'une sauvegarde

Rien ici. Trois objets, dans le `manifests/` de l'application qui possède la base :

| Objet | Fichier | Rôle |
| --- | --- | --- |
| `ObjectStore` | `<base>-objectstore.yaml` | bucket, credentials, rétention |
| `Cluster.spec.plugins` | `<base>.yaml` | **met la base sous archivage WAL continu** |
| `ScheduledBackup` | `<base>-scheduledbackup.yaml` | sauvegardes de base quotidiennes |

Les trois sont indissociables : un `ObjectStore` sans `spec.plugins` est inerte et ne le dit pas ;
un `spec.plugins` sans `ScheduledBackup` archive des WAL que rien ne complète.

`ObjectStore` est **namespacé** et le plugin n'en lit que dans le namespace du `Cluster` : il ne se
mutualise pas entre applications. Chaque base ajoutée veut le sien, **et** son propre SealedSecret
(sealed-secrets chiffre pour le couple nom/namespace).

## Opérations

Le geste courant passe par **[`script/cnpg-barman-plugin-script.sh`](../../../script/README.md)**
(`list`, `show`, `backup`, `restore`, `delete`). Il ne remplace pas les `kubectl` ci-dessous, qui
restent le diagnostic quand c'est le plugin lui-même qui est en cause — mais il porte les
contrôles que ces `kubectl` ne font pas.

```bash
script/cnpg-barman-plugin-script.sh list            # bases, sauvegardes, schedules, fenêtre PITR
script/cnpg-barman-plugin-script.sh backup          # sauvegarde manuelle, spec dérivée de la schedule
script/cnpg-barman-plugin-script.sh show <backup>   # LSN, WAL, durée, destination
```

> [!WARNING]
> **Deux commandes se comportent à l'inverse de leur homonyme dans
> [`velero-script.sh`](../../infra/velero/README.md)**, et l'intuition acquise là-bas est fausse
> ici :
> - **`delete` ne vide pas le bucket.** Il n'existe pas de `DeleteBackupRequest` côté CNPG. Les
>   données ne relèvent QUE de la `retentionPolicy` de l'`ObjectStore` ; supprimer l'objet
>   `Backup` ne perd que l'entrée du catalogue Kubernetes. La sauvegarde reste dans le bucket et
>   reste restaurable par son `backupId`.
>
>   Ce n'est pas une limite du script : **le plugin n'expose aucune suppression distante**.
>   Vérifié le 2026-09-08 sur v0.15.0 — les `Backup` ne portent aucun finalizer, `ObjectStore.spec`
>   n'a que trois champs (`configuration`, `instanceSidecarConfiguration`, `retentionPolicy`), et
>   le groupe `barmancloud.cnpg.io` ne contient qu'une seule CRD. Il n'y a rien à appeler.
>
>   Les deux horloges sont **indépendantes** : supprimer l'objet ne déclenche pas le GC, et la
>   rétention tourne sur l'**âge** (toutes les `retentionPolicyIntervalSeconds`, 1800 s par
>   défaut) que l'objet existe encore ou non. Supprimer l'objet n'accélère donc rien — cela rend
>   seulement la sauvegarde invisible jusqu'à son expiration.
>
>   L'absence de suppression ciblée est **délibérée en amont** : barman ne conserve que les WAL
>   nécessaires à la plus ancienne sauvegarde de base encore vivante. Purger une base au milieu
>   du catalogue casserait la fenêtre PITR de toutes celles qui la suivent. La rétention purge
>   par le bas, dans l'ordre — c'est la seule opération sûre, et le seul levier : il vit dans
>   `<base>-objectstore.yaml`, en GitOps.
> - **`restore` n'applique rien, il imprime un manifeste.** Une restauration CNPG est un `Cluster`
>   neuf en `bootstrap.recovery` : un **état désiré**, donc du Git. Le script le dérive du
>   `Cluster` source — en ne gardant que ce qu'ArgoCD a réellement déclaré (lu dans
>   `.metadata.managedFields`), et non le `.spec` défauté servi par l'API — puis le rend sur la
>   sortie standard, à relire et à committer.

> [!CAUTION]
> **Un cluster restauré qui archive sous le `serverName` de sa source écrase les WAL de
> celle-ci** — la restauration détruit la sauvegarde dont elle vient. `serverName` vaut le nom du
> `Cluster` quand il est omis : le piège ne se referme donc pas tout de suite, mais à la seconde
> où le cluster restauré est **renommé** pour prendre la place de l'original. La sous-commande
> `restore` écrit toujours un `serverName` **explicite des deux côtés** (`externalClusters` en
> lecture, `plugins` en écriture) pour cette seule raison.

- **Lire l'état des sauvegardes** — ⚠️ **pas** sur le `Cluster`. `status.firstRecoverabilityPoint`
  et `status.lastSuccessfulBackup` sont des champs de l'ancien support in-tree et valent `null`
  avec le plugin (vérifié le 2026-09-08 sur une base réelle : deux `Backup` en phase `completed`,
  les deux champs à `null`). La fenêtre de récupération réelle vit sur l'`ObjectStore` :
  ```bash
  kubectl -n <ns> get objectstore <base>-store -o jsonpath='{.status.serverRecoveryWindow}' | jq
  ```
  ⚠️ Les phases des `Backup` sont en **minuscules** (`completed`, `failed`, `running`,
  `walArchivingFailing`), contrairement à velero — un `grep Completed` ne trouve rien.

- **Vérifier le plugin** :
  ```bash
  kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud
  kubectl -n cnpg-system get certificate            # barman-cloud-client, barman-cloud-server
  kubectl -n cnpg-system logs deploy/plugin-barman-cloud
  ```
  Des `Certificate` qui restent `False` = cert-manager absent ou en erreur : le plugin démarre
  quand même et reste injoignable.

- **Vérifier qu'une base est bien prise en charge** :
  ```bash
  # ⚠️ Le sidecar est un INIT-CONTAINER (sidecar natif Kubernetes, `restartPolicy: Always`), pas un
  # conteneur ordinaire. `.spec.containers` ne renvoie que `postgres` et donne l'impression qu'il
  # manque.
  kubectl -n <ns> get pod <base>-1 \
    -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}'
  kubectl -n <ns> get cluster <base> -o jsonpath='{.status.pluginStatus}' | jq
  ```
  `pluginStatus` doit lister `barman-cloud.cloudnative-pg.io` avec la capability
  `TYPE_INSTANCE_SIDECAR_INJECTION`.

- **Mettre une nouvelle base sous sauvegarde** — quatre gestes, dans cet ordre :
  1. bucket + compte de service côté repo **Terraform** — le compte n'a de droits que sur ce
     bucket ;
  2. `ObjectStore` + SealedSecret du credential dans le `manifests/` de l'application ;
  3. `spec.plugins` sur le `Cluster` — ⚠️ **recrée le pod d'instance, avec ~200 s de coupure
     SQL** : 180 s d'arrêt smart (`smartShutdownTimeout`, consommé en entier parce qu'un pool de
     connexions applicatif ne se ferme jamais tout seul) puis ~20 s de redémarrage. Le `Cluster`
     affiche « Primary instance is being restarted without a switchover » pendant tout ce temps —
     c'est attendu, pas une panne ;
  4. `ScheduledBackup`, puis ajouter la base à `CNPGBackupChainAbsent`
     ([cnpg-monitoring](../cnpg-monitoring/README.md)) — c'est la **seule** alerte à nommer les
     bases en dur, et sans ce geste un retrait futur de `spec.plugins` passerait inaperçu.

  Puis déclencher la première sauvegarde à la main (`immediate: true` est délibérément absent de
  la `ScheduledBackup`) et vérifier qu'elle produit bien une fenêtre :
  ```bash
  script/cnpg-barman-plugin-script.sh backup <cluster>
  script/cnpg-barman-plugin-script.sh list
  ```

- **Upgrade** : bumper `targetRevision` dans `cnpg-barman-plugin.app.yaml`, commit, push. Renovate
  le suit (manager `argocd`, motif `*.app.yaml`).

## Non retenu

- **`spec.backup.barmanObjectStore` sur le `Cluster`** (support in-tree). Retiré de CloudNativePG
  depuis la 1.26. Il serait accepté par la CRD sur des versions plus anciennes et ne sauvegarderait
  rien ici.
- **Workload Identity** (`googleCredentials.gkeEnvironment: true`). Suppose un cluster GKE où
  l'authentification passe par le nœud. Ici c'est une clé JSON scellée, comme pour velero.
- **Un bucket par base.** `serverName` vaut le nom du `Cluster` quand il est omis : barman range
  déjà sous `<bucket>/<cluster>/`. Un bucket unique pour toutes les bases CNPG, distinct de celui
  de velero — chaque chaîne fait son propre GC.
