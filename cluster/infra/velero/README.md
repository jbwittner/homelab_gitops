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
`defaultVolumesToFsBackup` est activé et les snapshots de volume coupés.

Ce composant ne remplace pas les sauvegardes applicatives natives : les snapshots raft
d'[openbao](../openbao/README.md) et les backups CNPG restent la voie de restauration *cohérente*
d'une base ; velero est le filet de niveau cluster.

## Fichiers

- `velero.app.yaml` — Application (archétype (b) : Helm + `$values` + `manifests/`), ns `velero`,
  wave `1`
- `helm-values.yaml` — BSL sur le bucket GCS, plugin GCP en initContainer, node-agent/kopia,
  schedule quotidienne, snapshots de volume et Job de CRDs coupés (chaque choix est commenté sur
  place)
- `manifests/namespace.yaml` — ns `velero` (wave `-1`), labellisé **`privileged`**
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
- **Restaurer openbao ne le déscelle pas.** velero restaure le PVC raft, dont le contenu est
  chiffré : les clés de descellement et le token root restent la seule façon de le rouvrir, et ils
  ne sont dans aucune sauvegarde (cf. [openbao](../openbao/README.md)).
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
  le coffre ni les bases. **Ajouter un composant au cluster ne l'ajoute pas aux sauvegardes** :
  c'est un geste explicite dans `helm-values.yaml`. Candidats connus, à ouvrir un par un :
  `openbao` (raft 5Gi), `authentik` (Postgres CNPG 5Gi), `monitoring` (27Gi, dont 20Gi de TSDB
  Prometheus reconstructible).
- **Le TTL de 30 jours est une fenêtre de récupération, pas un réglage de taille.** Le raccourcir
  rend peu d'espace : kopia déduplique et ne stocke que des deltas, donc trente snapshots
  quotidiens d'une donnée stable ne pèsent pas trente fois un snapshot. Et l'espace d'un backup
  expiré n'est rendu qu'à la **maintenance** du dépôt kopia (toutes les heures par défaut), jamais
  au moment où le `Backup` disparaît de `kubectl get backups`. Ce qu'un TTL court coûte, en
  revanche, est immédiat : une corruption ou une suppression logique repérée au-delà de la fenêtre
  n'est plus rattrapable. Pour un historique plus long, ajouter une schedule hebdomadaire à TTL
  long (grand-père/père/fils) plutôt qu'allonger la quotidienne.
- **Une copie kopia d'une base vivante est cohérente-crash, pas cohérente-transaction.** Elle vaut
  ce que vaut un `kill -9` suivi d'un redémarrage : Postgres rejoue son WAL, openbao son raft. Pour
  une restauration *propre*, la voie reste le backup natif (CNPG, snapshot raft). Velero est le
  filet, pas le premier recours.
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
- **Lancer une sauvegarde à la main, au périmètre de la schedule.** La spec est recopiée depuis la
  Schedule : rien à retaper, donc aucune dérive possible entre les deux périmètres.
  ```bash
  kubectl -n velero get schedule velero-daily -o json \
    | jq '{apiVersion:"velero.io/v1", kind:"Backup",
           metadata:{generateName:"manual-", namespace:"velero"},
           spec:.spec.template}' \
    | kubectl create -f -
  ```
  Le label `velero.io/schedule-name` est volontairement **omis** (la CLI, elle, le pose avec
  `--from-schedule`) : il ferait compter ce backup comme une exécution de la schedule dans les
  métriques, ce qui éteindrait l'alerte `VeleroBackupTooOld` alors que la schedule n'aurait pas
  tourné. Un backup manuel doit rester `schedule=""`.

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
  `DeleteBackupRequest` — c'est exactement ce que fabrique `velero backup delete` :
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

  | CLI velero | kubectl |
  |---|---|
  | `backup create --from-schedule X` | le `jq` ci-dessus |
  | `backup delete X` | `DeleteBackupRequest` |
  | `backup describe X` | `get backups.velero.io X -o yaml` |
  | `restore create --from-backup X` | `Restore` ci-dessus |
  | `backup logs X` | `DownloadRequest` (kind `BackupLog`) → URL signée à télécharger |

  Seul `backup logs` justifie vraiment d'installer la CLI (`brew install velero`) : le diagnostic
  d'un échec passe par une `DownloadRequest` pénible à manipuler à la main.
- **Mettre en pause la schedule** (maintenance, migration de bucket) :
  ```bash
  kubectl -n velero patch schedule velero-daily --type=merge -p '{"spec":{"paused":true}}'
  ```
  Correctif durable : `schedules.daily.paused` dans `helm-values.yaml` — sinon `selfHeal` défait le
  patch à la sync suivante.
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
