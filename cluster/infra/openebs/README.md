# openebs

## Rôle

Stockage node-local **LVM** (LocalPV-LVM) taillé dans la partition brute `r-lvmpv` **de chaque
nœud**. Fournit la StorageClass `openebs-lvm-thin`, **StorageClass par défaut du cluster** : tout
PVC sans `storageClassName` explicite atterrit dessus.

**Node-local, pas répliqué** : un volume vit sur le nœud où son pod a été schedulé et le PV y
colle le pod par `nodeAffinity`. Ajouter des nœuds ajoute de la capacité et de l'étalement, **pas
de la tolérance de panne du stockage** : nœud perdu = ses volumes injoignables et ses pods
`Pending` jusqu'à son retour. La HA du stockage demanderait un moteur répliqué (mayastor, coupé
dans `helm-values.yaml`), pas un réglage de ce composant.

## Fichiers

- `openebs.app.yaml` — Application (archétype (b) : chart parapluie + `$values` + `manifests/`)
- `helm-values.yaml` — coupe tous les moteurs sauf LVM, ainsi que la télémétrie, le
  `preUpgradeHook` et l'observabilité empaquetée
- `manifests/namespace.yaml` — ns `openebs` labellisé **PSA `privileged`** (wave -1) —
  indispensable aux deux DaemonSets (node-plugin et bootstrap du VG), tous deux `privileged`
  (d'où : pas de `CreateNamespace`)
- `manifests/vg-bootstrap-daemonset.yaml` — DaemonSet (wave 0) : `pvcreate` + `vgcreate lvmvg`
  sur `/dev/disk/by-partlabel/r-lvmpv`, **sur chaque nœud**. Le travail est dans un
  initContainer, le conteneur principal dort : le DaemonSet n'est `Healthy` qu'une fois tous les
  VG créés, ce qui retient la StorageClass en wave 1. Script **idempotent**, rejoué à chaque
  démarrage de pod
- `manifests/storageclass.yaml` — `openebs-lvm-thin` (wave 1), `volgroup: lvmvg`,
  `WaitForFirstConsumer`, `allowVolumeExpansion`, classe par défaut du cluster
- `manifests/servicemonitor.yaml` — scrape des métriques du driver
- `manifests/prometheusrule.yaml` — règles d'alerte associées

## Contraintes

- **Le VG n'est pas provisionné par le driver** : LocalPV-LVM l'exige préexistant. C'est le rôle
  du DaemonSet de bootstrap, seul état réel sur disque non réconciliable par GitOps.
- **La partition brute `r-lvmpv` doit exister sur CHAQUE nœud** (prérequis de provisionnement,
  cf. [runbook](../../../doc/runbook-bootstrap.md)), ainsi que les modules `dm_mod`,
  `dm_thin_pool`, `dm_snapshot` — sinon l'initContainer échoue **sur ce nœud** (message explicite
  dans ses logs), le DaemonSet ne passe jamais `Healthy` et la StorageClass reste en attente.
- **Ordre irréductible**, porté par des sync-waves de **ressource** : namespace `privileged`
  (-1) → DaemonSet VG (0) → StorageClass (1).
- **Placement aligné sur le node-plugin** : le DaemonSet de bootstrap n'a ni `nodeSelector` ni
  `tolerations`, exactement comme celui du chart (défauts vides du sous-chart `lvm-localpv`).
  Toucher à l'un sans l'autre donne soit un nœud avec driver et sans VG (provisionnement en
  échec), soit l'inverse (VG inutile).
- **Le scheduler connaît la place restante sur chaque nœud** : le suivi de capacité CSI est actif
  (`storageCapacity`, défaut du sous-chart) — une `CSIStorageCapacity` par nœud écarte du
  scheduling ceux qui n'ont pas la place, VG absent compris. Publication **périodique** : c'est un
  amortisseur, pas une garantie, et il ne dispense pas d'avoir un VG partout.
- Ne pas toucher `lvm-localpv.crds` dans `helm-values.yaml` (cf. commentaires du fichier :
  doublon avec le sous-chart `openebs-crds`).
- **Le nom `openebs-lvm-thin` est historique** : la StorageClass est aujourd'hui en
  provisionnement **épais** (`thinProvision: "no"` — chaque PV réserve sa taille dans le VG
  immédiatement). Passer en thin change le comportement de saturation, pas le nom : renommer la
  classe casserait tous les PVC existants.

## Opérations

- **Upgrade** : bumper `targetRevision` dans `openebs.app.yaml`, commit, push.
- **Ajouter un nœud** : rien à faire dans ce dépôt. Provisionner le nœud avec la partition brute
  `r-lvmpv` et les modules noyau (fiche du cluster), le joindre : le DaemonSet y démarre, crée le
  VG et le nœud devient éligible aux PVC tout seul. Vérifier avec les commandes de debug que le
  pod du nouveau nœud est bien `Running` (et pas `Init:CrashLoopBackOff`, symptôme d'une
  partition absente).
- **Debug** :
  ```bash
  kubectl get ns openebs --show-labels                      # pod-security.kubernetes.io/enforce=privileged
  kubectl -n openebs get pods -o wide                       # controller + node plugin + bootstrap, PAR NŒUD
  kubectl -n openebs get ds lvmvg-bootstrap                 # DESIRED == READY ⇒ un VG sur chaque nœud
  # Bootstrap du VG, tous nœuds confondus (`-l` et non `ds/…` : ce dernier ne prend qu'un pod)
  kubectl -n openebs logs -l app.kubernetes.io/component=vg-bootstrap -c vg-bootstrap --prefix --tail=-1
  kubectl get sc openebs-lvm-thin
  ```
- **PVC `Pending` sans pod** : normal — `WaitForFirstConsumer`, le volume n'est taillé que
  lorsqu'un pod consomme le PVC.
- **PVC `Pending` AVEC un pod qui l'attend** : anormal. `kubectl describe pvc <nom>` — un
  `volume group lvmvg not found` signifie que le nœud retenu (annotation
  `volume.kubernetes.io/selected-node`) n'a pas de VG, malgré le suivi de capacité (cf.
  Contraintes). Le provisionnement y sera retenté en boucle sans reschedule : réparer le nœud
  (partition + pod de bootstrap `Running`), pas le PVC.
- **Agrandir un volume** : augmenter la taille dans le manifeste/les values du consommateur,
  commit, push (`allowVolumeExpansion: true`, extension à chaud).
- **Espace disponible** : le dashboard « Ressources — volumes »
  ([kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)) donne remplissage par PVC
  et état du VG.
