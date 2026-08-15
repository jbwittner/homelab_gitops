# velero

## Rôle

Sauvegarde et restauration du cluster vers un **bucket GCS dédié**, en deux volets qui n'ont pas
le même mécanisme :

- les **objets Kubernetes** (namespaces, Deployments, PVC, Secrets…), sérialisés par le Deployment
  `velero` et poussés dans le bucket via le plugin GCP (API GCS native) ;
- les **données des PV**, copiées fichier à fichier par le DaemonSet `node-agent` (moteur
  **kopia**), vers le même bucket.

Le second volet n'est pas optionnel ici : le stockage est
[openebs](../openebs/README.md) LocalPV-**LVM**, dont les snapshots CSI sont *node-locaux* — ils
disparaissent avec le nœud qui porte le LV, donc ne constituent pas une sauvegarde. C'est pourquoi
`defaultVolumesToFsBackup` est activé et les snapshots de volume coupés. Ce mode opt-out ramasse en
retour des volumes sans contenu restaurable — un `emptyDir` naît vide avec le pod et meurt avec lui ;
sur un pod de Job déjà terminé, kubelet l'a même démonté avant que le node-agent ne l'ouvre, ce qui
fait échouer la sauvegarde entière (`PartiallyFailed`). Une politique de volumes les ignore donc :
`manifests/volume-policies.yaml`.

Ce composant ne remplace pas les sauvegardes applicatives natives : les snapshots raft
d'[openbao](../openbao/README.md) et les backups CNPG restent la voie de restauration *cohérente*
d'une base ; velero est le filet de niveau cluster. Poussé à sa conclusion, ce raisonnement a sorti
le namespace `openbao` du périmètre : quand la sauvegarde native est meilleure ET testée, le filet
n'ajoute qu'une copie de moindre qualité — cf. Contraintes.

## Fichiers

- `velero.app.yaml` — Application (archétype (b) : Helm + `$values` + `manifests/`), ns `velero`,
  wave `1`
- `helm-values.yaml` — BSL sur le bucket GCS, plugin GCP en initContainer, node-agent/kopia,
  schedule quotidienne, snapshots de volume et Job de CRDs coupés (chaque choix est commenté sur
  place)
- `manifests/namespace.yaml` — ns `velero` (wave `-1`), labellisé **`privileged`**
- `manifests/volume-policies.yaml` — ConfigMap `velero-volume-policies`, garde-fou du mode opt-out :
  ignore la copie des `emptyDir`. Référencée par la Schedule (`template.resourcePolicy`,
  `helm-values.yaml`) ; le raisonnement est commenté sur place
- `velero-script.sh` — les gestes opérationnels : `list`, `show`, `backup`, `restore`, `delete`. Le
  périmètre y est toujours **dérivé** (d'une Schedule pour un backup, du Backup source pour un
  restore) et jamais retapé ; le nombre de volumes copiés est affiché partout. Ce n'est **pas** la
  CLI `velero` — d'où le nom — tout passe par `kubectl` et `jq`. Détail en Opérations
- `manifests/velero-gcs.sealed.yaml` — clé JSON du compte de service GCP, scellée. Seul des deux
  fichiers de secret à se committer
- `manifests/velero-gcs.secret.yaml` — **clair, gitignoré** : template d'entrée de `kubeseal` ayant
  produit le précédent. À supprimer une fois le BSL `Available` (cf. Opérations)

## Contraintes

- **Le bucket et le compte de service ne sont PAS déclarés ici : ils vivent dans le repo
  Terraform**, comme la configuration interne d'openbao. Le contrat attendu — et sans lequel le BSL
  reste `Unavailable` : un bucket **dédié** (distinct de celui des snapshots openbao, velero faisant
  son propre GC des sauvegardes expirées) et le compte de service
  `velero@homelab-499008.iam.gserviceaccount.com` lié à `roles/storage.objectAdmin` **sur ce
  bucket**. Rien côté `cluster/` ne vérifie ce contrat : la seule preuve que les deux repos
  s'accordent est l'état `Available` du `BackupStorageLocation`.
- **Le credential est un `SealedSecret`, et c'en est la seconde raison valable du repo.** velero est
  le moyen de restaurer openbao ; ranger son accès au bucket dans le coffre qu'il restaure fermerait
  un cycle — un coffre perdu emporterait alors aussi l'accès aux sauvegardes qui permettent de le
  reconstruire (règle anti-cycle, [`doc/regles-gitops.md`](../../../doc/regles-gitops.md)). Même
  raisonnement que `openbao-snapshot-gcs`.
- **Un backup manuel n'hérite RIEN de la schedule.** Le périmètre vit sur l'objet `Backup`, pas sur
  velero : `includedNamespaces` omis vaut **`["*"]`**, soit tout le cluster — y compris `monitoring`
  et ses 20 Gi de TSDB. Un `velero backup create` sans `--include-namespaces` remplit donc le bucket
  bien au-delà de la liste blanche, sans rien signaler. Se reconnaît à
  `NS: [*]` dans la sortie de `get backups.velero.io` (colonne `.spec.includedNamespaces`). La
  parade est en Opérations : dériver le backup de la Schedule plutôt que de retaper une spec.
- **`kubectl get backups` ne montre PAS les sauvegardes velero.** Le nom court `backups` est
  ambigu dans ce cluster — [cnpg](../../app/cnpg/README.md) enregistre `backups.postgresql.cnpg.io`
  et velero `backups.velero.io` — et kubectl tranche silencieusement en faveur de CNPG. La commande
  répond `No resources found in velero namespace` alors que les sauvegardes existent : le pire des
  faux négatifs, puisqu'il ressemble à « aucune sauvegarde n'a tourné ». Toujours écrire
  **`backups.velero.io`**, et de même `restores.velero.io` / `schedules.velero.io`. Les noms non
  ambigus (`podvolumebackups`, `backupstoragelocations`, `backuprepositories`) ne posent pas ce
  problème.
- **Sans le Secret `velero-gcs`, velero ne démarre pas** : le Deployment le monte en volume et
  reste en `ContainerCreating` tant qu'il manque. D'où l'ordre imposé lors d'une rotation —
  produire le `.sealed.yaml` **avant** de le déclarer dans `manifests/kustomization.yaml` : une
  ressource déclarée mais absente casse le `kustomize build`, donc la sync de toute l'Application,
  pas seulement du secret.
- **Le namespace est `privileged`, et ce label est load-bearing.** node-agent monte
  `/var/lib/kubelet/pods` en `hostPath` pour lire le contenu des volumes ; `hostPath` est interdit
  par le PodSecurity `baseline` de Talos. Sans le label, les pods node-agent sont refusés à
  l'admission — et les sauvegardes continuent de passer au **vert** en ne contenant que des objets,
  aucune donnée.
- **Un nœud sans node-agent est un nœud dont les PV ne sont pas sauvegardés.** Aucune tolération
  n'est posée sur le DaemonSet : ajouter un taint à un nœud le retire silencieusement du périmètre.
  Même famille d'échec que ci-dessus — vert, et vide.
- **La passphrase des dépôts kopia vit dans le cluster.** velero crée le Secret
  `velero-repo-credentials` dans son namespace ; sans elle, les dépôts kopia du bucket sont
  illisibles. Or le namespace `velero` est **exclu** des sauvegardes : ce Secret doit donc être
  conservé **hors cluster**, au coffre, comme les clés de descellement d'openbao.
- **velero ne sauvegarde PAS openbao, et c'est délibéré.** Le namespace a été dans la liste
  blanche, puis en a été retiré : le coffre a sa propre chaîne — snapshot raft quotidien vers un
  bucket GCS distinct — et elle est meilleure que ce que velero sait produire, `bao operator raft
  snapshot save` donnant une copie *cohérente-transaction* là où kopia ne copie le PVC que de façon
  *cohérente-crash*. Elle est aussi la seule des deux à être réellement testée
  (`openbao-script.sh verify`). Ce que le retrait a coûté — un second domaine de panne, et la
  détection passive d'une chaîne morte en silence — est remplacé par les alertes
  `OpenBaoSnapshotTooOld` / `OpenBaoSnapshotMissing`
  ([openbao-monitoring](../openbao-monitoring/README.md)). **Les deux décisions se tiennent
  ensemble** : supprimer ces alertes rend l'exclusion indéfendable, remettre `openbao` dans la
  liste blanche revient sur une décision motivée. Corollaire à ne pas perdre : restaurer le PVC
  raft n'aurait de toute façon pas descellé le coffre — son contenu est chiffré, et les clés de
  descellement comme le token root ne sont dans **aucune** sauvegarde
  (cf. [openbao](../openbao/README.md)).
- **Restaurer un namespace géré par ArgoCD entre en concurrence avec `selfHeal`.** Les objets
  déclarés dans Git y sont reposés par ArgoCD ; ce que velero apporte d'utile, ce sont les
  **données** (PV/PVC) et les objets qui n'existent pas dans Git. Restaurer un namespace entier
  ressuscite aussi des ressources supprimées à dessein — restreindre le périmètre du `restore`.
- **`spec.skipImmediately` de la Schedule ne se déclare pas dans Git.** Le contrôleur velero le
  consomme : il le repasse lui-même à `false` dès qu'il l'a pris en compte. Déclaré à `true`, il
  entre en boucle avec `selfHeal` — ArgoCD le repose, velero le retire, sans fin. Le levier
  déclaratif équivalent est le flag serveur `--schedule-skip-immediately=true`. Corollaire : créer
  ou recréer la Schedule déclenche une sauvegarde immédiate.
- **La schedule fonctionne en liste blanche : ce qui n'est pas listé n'est pas sauvegardé, sans le
  dire.** `includedNamespaces` ne contient aujourd'hui que `test-nginx` — périmètre de mise en
  route, choisi jetable pour éprouver la chaîne complète (BSL → kopia → restauration) sans engager
  les bases. **Ajouter un composant au cluster ne l'ajoute pas aux sauvegardes** : c'est un geste
  explicite dans `helm-values.yaml`. Candidats connus, à ouvrir un par un : `authentik` (Postgres
  CNPG 5Gi), `monitoring` (27Gi, dont 20Gi de TSDB Prometheus reconstructible). `openbao` n'en est
  **pas** un — exclusion motivée, cf. la contrainte plus haut.
- **Le TTL de 30 jours est une fenêtre de récupération, pas un réglage de taille.** Le raccourcir
  rend peu d'espace : kopia déduplique et ne stocke que des deltas, donc trente snapshots
  quotidiens d'une donnée stable ne pèsent pas trente fois un snapshot. Et l'espace d'un backup
  expiré n'est rendu qu'à la **maintenance** du dépôt kopia (toutes les heures par défaut), jamais
  au moment où le `Backup` disparaît de `kubectl get backups`. Ce qu'un TTL court coûte, en
  revanche, est immédiat : une corruption ou une suppression logique repérée au-delà de la fenêtre
  n'est plus rattrapable. Pour un historique plus long, ajouter une schedule hebdomadaire à TTL
  long (grand-père/père/fils) plutôt qu'allonger la quotidienne.
- **Une copie kopia d'une base vivante est cohérente-crash, pas cohérente-transaction.** Elle vaut
  ce que vaut un `kill -9` suivi d'un redémarrage : Postgres rejoue son WAL, un raft rejoue son
  journal. Pour une restauration *propre*, la voie reste le backup natif (CNPG, snapshot raft).
  Velero est le filet, pas le premier recours — et c'est l'argument qui a fini par sortir `openbao`
  de la liste blanche.
- **Le namespace `velero` ne se sauvegarde pas lui-même.** Sa configuration (BSL, schedule, RBAC)
  est déclarée dans Git ; la restaurer se battrait avec la sync ArgoCD. Même raison pour
  `kube-system`, reconstruit par Talos et le CNI. Avec une liste blanche, ils sont exclus de fait —
  aucune ligne à écrire.
- **Aucun `ServiceMonitor` n'est posé par ce composant** — ils vivent dans
  [velero-monitoring](../velero-monitoring/README.md), avec le PodMonitor du node-agent et les
  alertes. L'autodétection du chart repose sur les Capabilities Helm, donc sur la présence des
  CRDs prometheus-operator au moment du rendu — non garantie au bootstrap, `kube-prometheus-stack`
  vivant dans le tier `app`, sans relation d'ordre avec `infra`. Même découpage que pour
  [openbao](../openbao/README.md). En revanche `metrics.enabled` reste **vrai** ici : c'est lui qui
  crée le Service scrapé, et le couper viderait le ServiceMonitor du composant frère en silence.
  Dashboard Grafana : dossier *Wittnerlab*, « Sauvegardes — velero » (le ConfigMap est dans
  [kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)).
- **Renovate ne suit pas l'image du plugin.** La version du chart, dans `velero.app.yaml`, est bien
  prise en charge (manager `argocd`) ; l'image `velero-plugin-for-gcp` épinglée dans
  `helm-values.yaml` ne l'est pas — les `managerFilePatterns` du manager `kubernetes` ne couvrent
  que `manifests/`. À bumper à la main en même temps que le chart, en gardant la même famille de
  version que velero.

## Opérations

- **Vérifier le bucket et le compte de service** — ils sont posés par le repo **Terraform**, comme
  la configuration d'openbao : rien à créer ici. Le compte de service est
  `velero@homelab-499008.iam.gserviceaccount.com` (sortie `velero_service_account_email`), et il
  lui faut `roles/storage.objectAdmin` **sur le bucket** :
  ```bash
  gcloud storage buckets describe gs://homelab-velero-backups-1a91ac18 --project=homelab-499008
  gcloud storage buckets get-iam-policy gs://homelab-velero-backups-1a91ac18 --project=homelab-499008
  ```
  Ne pas poser de règle de cycle de vie sur ce bucket : la rétention est celle du `ttl` de la
  schedule, et velero supprime lui-même ce qui expire.
- **Émettre une clé pour ce compte de service** (le seul geste manuel — une clé JSON ne se sort pas
  d'un état Terraform sans l'y stocker en clair) :
  ```bash
  gcloud iam service-accounts keys create ./velero-sa.json \
    --iam-account=velero@homelab-499008.iam.gserviceaccount.com
  ```
- **Sceller la clé du compte de service** (installation initiale, et à chaque rotation) — depuis la
  racine du repo :
  ```bash
  # 1. Coller le contenu de ./velero-sa.json dans la clé `cloud` du template en clair (gitignoré)
  $EDITOR cluster/infra/velero/manifests/velero-gcs.secret.yaml

  # 2. Sceller — le chiffré est lié au couple (velero-gcs, velero)
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
    < cluster/infra/velero/manifests/velero-gcs.secret.yaml \
    > cluster/infra/velero/manifests/velero-gcs.sealed.yaml

  # 3. Committer le scellé, puis — une fois le BSL `Available` — supprimer le clair et la clé
  #    téléchargée. Ce sont les deux seules copies en clair de la clé privée du compte de service.
  rm cluster/infra/velero/manifests/velero-gcs.secret.yaml ./velero-sa.json
  ```
  Contrairement aux secrets servis par [openbao](../openbao/README.md), un scellé se refait passer
  par Git : une rotation demande un commit. Révoquer l'ancienne clé côté GCP après coup
  (`gcloud iam service-accounts keys delete`).
- **Vérifier que le bucket répond** — le BSL doit passer `Available` en moins d'une minute :
  ```bash
  kubectl -n velero get backupstoragelocation default
  kubectl -n velero logs deploy/velero | grep -i backupstoragelocation
  ```
  `Unavailable` juste après l'installation = credential absent, mal scellé, ou droits IAM
  insuffisants sur le bucket.
- **Le script `velero-script.sh`** couvre les gestes courants. Depuis la racine du repo :
  ```bash
  cluster/infra/velero/velero-script.sh list                       # tableau de bord
  cluster/infra/velero/velero-script.sh show <backup>              # détail d'une sauvegarde
  cluster/infra/velero/velero-script.sh backup                     # sauvegarde manuelle
  cluster/infra/velero/velero-script.sh restore <backup> -n <ns>   # restauration
  cluster/infra/velero/velero-script.sh delete <backup>            # suppression définitive
  ```
  Variables communes : `VELERO_NAMESPACE` (défaut `velero`), `TIMEOUT` (1800 s), `DRY_RUN=1`
  (affiche le manifeste, n'envoie rien), `NO_WAIT=1` (crée et rend la main), `YES=1` (passe les
  confirmations). Codes de sortie : `0` succès, `1` erreur, `2` PartiallyFailed, `3` délai dépassé.
  Chaque sous-commande est détaillée ci-dessous, avec la voie `kubectl` équivalente — le script ne
  fait que fabriquer ces CRs, et savoir les écrire à la main reste la porte de sortie le jour où il
  n'est pas là.
- **Lancer une sauvegarde à la main, au périmètre de la schedule** :
  ```bash
  cluster/infra/velero/velero-script.sh backup              # schedule `velero-daily`, suit jusqu'à la fin
  cluster/infra/velero/velero-script.sh backup autre-sched  # une autre schedule
  DRY_RUN=1 cluster/infra/velero/velero-script.sh backup    # affiche le manifeste, ne crée rien
  ```
  Le script recopie `.spec.template` de la Schedule : le périmètre ne peut pas diverger de celui
  qui tourne chaque nuit. Il refuse de partir si le `BackupStorageLocation` n'est pas `Available`,
  prévient si aucun `node-agent` n'est prêt, et affiche en fin de course le **nombre de volumes
  copiés** — le seul contrôle qui distingue une vraie sauvegarde d'une sauvegarde « verte et
  vide ».

  Le label `velero.io/schedule-name` est volontairement **omis** (la CLI, elle, le pose avec
  `--from-schedule`) : il ferait compter ce backup comme une exécution de la schedule dans les
  métriques, ce qui éteindrait l'alerte `VeleroBackupTooOld` alors que la schedule n'aurait pas
  tourné. Un backup manuel doit rester `schedule=manuel`. À la place, le script pose l'annotation
  `homelab.wittner.tech/derived-from-schedule`, que `list` affiche en colonne `SOURCE`.

  Pour un périmètre différent, écrire la spec à la main — et se souvenir qu'un `includedNamespaces`
  omis vaut **tout le cluster** (cf. Contraintes) :
  ```bash
  kubectl -n velero create -f - <<'EOF'
  apiVersion: velero.io/v1
  kind: Backup
  metadata:
    generateName: manual-
    namespace: velero
  spec:
    defaultVolumesToFsBackup: true
    includedNamespaces: [test-nginx]
    snapshotVolumes: false
    ttl: 720h
  EOF
  ```
- **Suivre les sauvegardes et leur contenu** :
  ```bash
  cluster/infra/velero/velero-script.sh list            # sauvegardes, schedules, restaurations
  cluster/infra/velero/velero-script.sh list manual     # filtre par sous-chaîne du nom
  cluster/infra/velero/velero-script.sh show <backup>   # détail d'une sauvegarde
  ```
  `list` donne trois tableaux. Pour chaque sauvegarde : phase, âge, expiration, **source**
  (`velero-daily` si elle vient de la schedule, `manuel (velero-daily)` si elle vient de `backup`,
  `manuel` sinon), colonne **`NS`**, objets, **volumes et taille copiés**. Une sauvegarde
  `Completed` sans aucun volume est marquée `⚠ aucune donnée` — c'est le symptôme d'un node-agent
  absent ou refusé à l'admission. `list` est la seule sous-commande qui n'exige pas un
  `BackupStorageLocation` `Available` : c'est justement quand le bucket casse qu'on la lance.

  **`NS` est un compteur, pas la liste.** La liste des namespaces grandit avec le périmètre et
  déformerait le tableau ; le seul cas qui doit sauter aux yeux reste lisible tel quel — **`*` =
  tout le cluster** (cf. Contraintes). Le périmètre complet, les erreurs, et le détail **volume par
  volume** (namespace, pod, volume, phase, taille) sont dans `show <backup>` — c'est là qu'on
  vérifie ce qui a *vraiment* été copié, et non seulement combien.

  Voie manuelle :
  ```bash
  kubectl -n velero get backups.velero.io,schedules.velero.io   # suffixe obligatoire, cf. Contraintes
  kubectl -n velero get backups.velero.io -o custom-columns=\
NAME:.metadata.name,PHASE:.status.phase,NS:.spec.includedNamespaces,ITEMS:.status.progress.itemsBackedUp
  kubectl -n velero get podvolumebackups          # un objet par volume copié par kopia
  kubectl -n velero get backups.velero.io <nom> -o yaml
  ```
  Une sauvegarde `Completed` **sans** `podvolumebackups` associés est le symptôme des deux pièges
  ci-dessus (node-agent absent ou refusé à l'admission) : les objets sont là, les données non.
- **Supprimer une sauvegarde** — ⚠️ `kubectl delete backups.velero.io <nom>` **ne supprime rien
  durablement** : les données restent dans le bucket et le contrôleur `backup-sync` recrée l'objet
  à la synchro suivante (~1 min). Le seul chemin qui efface aussi le contenu est une
  `DeleteBackupRequest` — c'est exactement ce que fabriquent `velero backup delete` et :
  ```bash
  cluster/infra/velero/velero-script.sh delete manual-xxxxx
  ```
  Le script refuse une sauvegarde `InProgress` (la supprimer en cours laisse des données
  orphelines dans le dépôt kopia), affiche ce qui va disparaître, et demande la **frappe exacte du
  nom** en confirmation. Voie manuelle :
  ```bash
  kubectl -n velero create -f - <<'EOF'
  apiVersion: velero.io/v1
  kind: DeleteBackupRequest
  metadata:
    generateName: suppression-
    namespace: velero
  spec:
    backupName: manual-xxxxx
  EOF
  kubectl -n velero get deletebackuprequests
  kubectl -n velero get backups.velero.io          # doit avoir disparu pour de bon
  ```
  Ne jamais viser une sauvegarde `InProgress` : la supprimer en cours laisse des données
  orphelines dans le dépôt kopia, que seule la maintenance finira par récupérer.
- **Restaurer** — restreindre le périmètre, ArgoCD reposant de toute façon ce qui est déclaré dans
  Git (cf. Contraintes) :
  ```bash
  cluster/infra/velero/velero-script.sh restore manual-xxxxx                    # périmètre du backup
  cluster/infra/velero/velero-script.sh restore manual-xxxxx -n test-nginx      # restreint
  cluster/infra/velero/velero-script.sh restore manual-xxxxx -n test-nginx --overwrite
  DRY_RUN=1 cluster/infra/velero/velero-script.sh restore manual-xxxxx -n test-nginx
  ```
  Le périmètre est repris des `includedNamespaces` du **Backup source**, jamais retapé. Quatre
  garde-fous, chacun correspondant à un échec silencieux constaté :
  - une sauvegarde qui couvre **tout le cluster** (`includedNamespaces` absent ou `*`) est refusée
    sans `-n` explicite — restaurer un cluster entier ne peut pas être un défaut implicite ;
  - un `-n` **hors du périmètre** du backup est refusé : il produirait un `Restore` vide et vert ;
  - les Applications **ArgoCD** qui ciblent les namespaces visés sont listées, avec la commande de
    suspension de l'auto-sync à recopier. Le script n'y touche pas lui-même : un Ctrl-C au mauvais
    moment laisserait une Application avec `automated` coupé, sans que ça se voie nulle part ;
  - en fin de course, une restauration `Completed` **sans aucun `podvolumerestore`** alors que la
    sauvegarde contenait des volumes est signalée — symétrique du « vert et vide » du backup.

  `--overwrite` passe `existingResourcePolicy` à `update` : les objets déjà en place sont
  **écrasés**. Sans lui, `none` laisse intact ce qui existe et ne repose que ce qui manque.
  Voie manuelle :
  ```bash
  kubectl -n velero create -f - <<'EOF'
  apiVersion: velero.io/v1
  kind: Restore
  metadata:
    generateName: restore-
    namespace: velero
  spec:
    backupName: manual-xxxxx
    includedNamespaces: [test-nginx]
    existingResourcePolicy: none      # `update` pour écraser les objets déjà en place
  EOF
  kubectl -n velero get restores.velero.io
  kubectl -n velero get podvolumerestores
  ```
- **Sans la CLI velero** — tout ce qui précède est en `kubectl` parce que la CLI ne fait que
  fabriquer ces mêmes CRs. Équivalences :

  | CLI velero | `velero-script.sh` | kubectl |
  |---|---|---|
  | `backup create --from-schedule X` | `backup [X]` | `Backup` dérivé de `.spec.template` |
  | `backup get` | `list` | `get backups.velero.io` |
  | `backup describe X` | `show X` | `get backups.velero.io X -o yaml` |
  | `backup delete X` | `delete X` | `DeleteBackupRequest` |
  | `restore create --from-backup X` | `restore X` | `Restore` ci-dessus |
  | `backup logs X` | — | `DownloadRequest` (kind `BackupLog`) → URL signée à télécharger |

  Seul `backup logs` justifie vraiment d'installer la CLI (`brew install velero`) : le diagnostic
  d'un échec passe par une `DownloadRequest` pénible à manipuler à la main.
- **Nettoyer un dépôt kopia orphelin.** velero crée un dépôt **par namespace sauvegardé**
  (`kopia/<ns>/` dans le bucket, plus un `BackupRepository`) et ne le supprime **jamais**, même
  quand plus aucune sauvegarde ne le référence : il continue à lancer un job de maintenance horaire
  pour rien, et le préfixe reste dans le bucket. C'est ce que laisse derrière lui un backup lancé
  sans `includedNamespaces` (cf. Contraintes). Vérifier d'abord qu'aucune sauvegarde ne couvre le
  namespace visé, puis supprimer **le CR avant le préfixe** — l'inverse laisse velero avec un dépôt
  déclaré mais introuvable, qui échoue à la maintenance suivante :
  ```bash
  kubectl -n velero get backups.velero.io \
    -o custom-columns=NAME:.metadata.name,NS:.spec.includedNamespaces
  kubectl -n velero delete backuprepository <ns>-default-kopia
  gcloud storage rm -r gs://homelab-velero-backups-1a91ac18/kopia/<ns> --project=homelab-499008
  ```
- **Repartir de zéro** (⚠️ **irréversible** — détruit toutes les sauvegardes). L'ordre est
  load-bearing : vider le bucket **d'abord**, sinon le contrôleur `backup-sync` recrée les objets
  `Backup` depuis les métadonnées restées en ligne, dans la minute.
  ```bash
  # 1. Bucket (le bucket lui-même est conservé : il vient de Terraform)
  gcloud storage rm --recursive "gs://homelab-velero-backups-1a91ac18/**" --project=homelab-499008

  # 2. CRs — les Backup disparaissent souvent d'eux-mêmes une fois leurs données absentes
  kubectl -n velero delete backups.velero.io --all
  kubectl -n velero delete podvolumebackups --all
  kubectl -n velero delete backuprepositories --all
  kubectl -n velero delete restores.velero.io --all
  kubectl -n velero delete jobs --all          # jobs de maintenance des dépôts supprimés

  # 3. Redémarrer : remet à zéro les compteurs Prometheus et force la ré-init des dépôts kopia
  kubectl -n velero rollout restart deploy/velero ds/node-agent

  # 4. Contrôle
  gcloud storage du -s gs://homelab-velero-backups-1a91ac18 --project=homelab-499008   # 0
  kubectl -n velero get backupstoragelocation default                                   # Available
  ```
  Ne PAS supprimer le Secret `velero-repo-credentials` : la passphrase kopia sert aux dépôts
  recréés, et s'en séparer rendrait illisible tout ce qui aurait survécu à l'effacement.
  Le `rollout restart` affiche des avertissements PodSecurity `restricted` — normal, le namespace
  n'impose que `enforce: privileged` (même forme que le namespace openebs), et l'avertissement est
  calculé sur le profil `warn` par défaut du cluster.
- **Mettre en pause la schedule** (maintenance, migration de bucket) :
  ```bash
  kubectl -n velero patch schedule velero-daily --type=merge -p '{"spec":{"paused":true}}'
  ```
  ⚠️ Ne pas compter sur `selfHeal` pour défaire ce patch : `paused` n'est pas rendu par le chart,
  donc absent de l'état désiré, donc **non possédé par ArgoCD** sous `ServerSideApply` — la pause
  survit indéfiniment, sans apparaître comme une dérive. Une schedule oubliée en pause ne se voit
  nulle part sauf dans `kubectl get schedules.velero.io` (colonne `PAUSED`). Pour une pause qui se
  lit dans Git et se lève par un revert : `schedules.daily.paused: true` dans `helm-values.yaml`.
- **Upgrade** : bumper `targetRevision` dans `velero.app.yaml` et, dans le même commit, l'image du
  plugin dans `helm-values.yaml` (Renovate ne la voit pas, cf. Contraintes).
- **Debug** :
  ```bash
  kubectl -n velero get pods,backupstoragelocation,backups.velero.io
  kubectl -n velero logs deploy/velero
  kubectl -n velero logs ds/node-agent
  kubectl -n velero get backuprepositories        # un dépôt kopia par (namespace, BSL)
  kubectl get events -n velero --sort-by=.lastTimestamp | tail -20
  ```
  Un pod node-agent absent de la liste sans erreur de scheduling : vérifier le label PodSecurity du
  namespace, l'admission rejette le pod au niveau du DaemonSet (l'événement est sur le DaemonSet,
  pas sur un pod).
