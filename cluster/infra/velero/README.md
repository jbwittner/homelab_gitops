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
- **Une copie kopia d'une base vivante est cohérente-crash, pas cohérente-transaction.** Elle vaut
  ce que vaut un `kill -9` suivi d'un redémarrage : Postgres rejoue son WAL, openbao son raft. Pour
  une restauration *propre*, la voie reste le backup natif (CNPG, snapshot raft). Velero est le
  filet, pas le premier recours.
- **Le namespace `velero` ne se sauvegarde pas lui-même.** Sa configuration (BSL, schedule, RBAC)
  est déclarée dans Git ; la restaurer se battrait avec la sync ArgoCD. Même raison pour
  `kube-system`, reconstruit par Talos et le CNI. Avec une liste blanche, ils sont exclus de fait —
  aucune ligne à écrire.
- **Aucun `ServiceMonitor` n'est posé par ce composant.** L'autodétection du chart repose sur les
  Capabilities Helm, donc sur la présence des CRDs prometheus-operator au moment du rendu — non
  garantie au bootstrap, `kube-prometheus-stack` vivant dans le tier `app`, sans relation d'ordre
  avec `infra`. Même découpage que pour [openbao](../openbao/README.md) : sa place est un composant
  frère `velero-monitoring`. **Conséquence directe : un échec de sauvegarde ne lève aujourd'hui
  aucune alerte** — il se voit uniquement en listant les backups.
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
- **Lancer une sauvegarde à la main** (sans CLI velero) :
  ```bash
  kubectl -n velero create -f - <<'EOF'
  apiVersion: velero.io/v1
  kind: Backup
  metadata:
    generateName: manual-
    namespace: velero
  spec:
    defaultVolumesToFsBackup: true
    includedNamespaces: [test-nginx]     # même liste blanche que la schedule
    ttl: 720h
  EOF
  ```
  Avec la CLI : `velero backup create manual-1 --include-namespaces test-nginx --wait`.
- **Suivre les sauvegardes et leur contenu** :
  ```bash
  kubectl -n velero get backups,schedules
  kubectl -n velero get podvolumebackups          # un objet par volume copié par kopia
  velero backup describe <nom> --details
  velero backup logs <nom>
  ```
  Une sauvegarde `Completed` **sans** `podvolumebackups` associés est le symptôme des deux pièges
  ci-dessus (node-agent absent ou refusé à l'admission) : les objets sont là, les données non.
- **Restaurer** — restreindre le périmètre, ArgoCD reposant de toute façon ce qui est déclaré dans
  Git (cf. Contraintes) :
  ```bash
  velero restore create --from-backup <nom> --include-namespaces <ns>
  kubectl -n velero get restores
  velero restore describe <nom-du-restore> --details
  ```
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
  kubectl -n velero get pods,backupstoragelocation
  kubectl -n velero logs deploy/velero
  kubectl -n velero logs ds/node-agent
  kubectl -n velero get backuprepositories        # un dépôt kopia par (namespace, BSL)
  kubectl get events -n velero --sort-by=.lastTimestamp | tail -20
  ```
  Un pod node-agent absent de la liste sans erreur de scheduling : vérifier le label PodSecurity du
  namespace, l'admission rejette le pod au niveau du DaemonSet (l'événement est sur le DaemonSet,
  pas sur un pod).
