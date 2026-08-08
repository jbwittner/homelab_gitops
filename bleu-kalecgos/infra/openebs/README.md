# openebs

## Rôle

Stockage node-local **LVM** (LocalPV-LVM) taillé dans la partition brute `r-lvmpv` du nœud.
Fournit la StorageClass `openebs-lvm-thin`, **StorageClass par défaut du cluster** : tout PVC
sans `storageClassName` explicite atterrit dessus.

## Fichiers

- `openebs.app.yaml` — Application (archétype (b) : chart parapluie + `$values` + `manifests/`)
- `helm-values.yaml` — coupe tous les moteurs sauf LVM, ainsi que la télémétrie, le
  `preUpgradeHook` et l'observabilité empaquetée ; mono-nœud
- `manifests/namespace.yaml` — ns `openebs` labellisé **PSA `privileged`** (wave -1) —
  indispensable au DaemonSet node-plugin et au Job, tous deux `privileged` (d'où : pas de
  `CreateNamespace`)
- `manifests/vg-bootstrap-job.yaml` — hook `Sync` (wave 0) : `pvcreate` + `vgcreate lvmvg` sur
  `/dev/disk/by-partlabel/r-lvmpv`. **Idempotent**, recréé à chaque sync
  (`hook-delete-policy: BeforeHookCreation`)
- `manifests/storageclass.yaml` — `openebs-lvm-thin` (wave 1), `volgroup: lvmvg`,
  `WaitForFirstConsumer`, `allowVolumeExpansion`, classe par défaut du cluster
- `manifests/servicemonitor.yaml` — scrape des métriques du driver
- `manifests/prometheusrule.yaml` — règles d'alerte associées

## Contraintes

- **Le VG n'est pas provisionné par le driver** : LocalPV-LVM l'exige préexistant. C'est le rôle
  du hook, seul état réel sur disque non réconciliable par GitOps.
- **La partition brute `r-lvmpv` doit exister sur le nœud** (prérequis de provisionnement, cf.
  [runbook](../../../doc/runbook-bootstrap-kalecgos.md)) — sinon le Job échoue et aucun PVC ne
  peut être satisfait.
- **Ordre irréductible**, porté par des sync-waves de **ressource** : namespace `privileged`
  (-1) → hook VG (0) → StorageClass (1). Le hook est en `Sync` et non `PreSync` : un `PreSync`
  tournerait avant la pose du label et serait rejeté par l'admission `baseline`.
- Ne pas toucher `lvm-localpv.crds` dans `helm-values.yaml` (cf. commentaires du fichier :
  doublon avec le sous-chart `openebs-crds`).
- **Le nom `openebs-lvm-thin` est historique** : la StorageClass est aujourd'hui en
  provisionnement **épais** (`thinProvision: "no"` — chaque PV réserve sa taille dans le VG
  immédiatement). Passer en thin change le comportement de saturation, pas le nom : renommer la
  classe casserait tous les PVC existants.

## Opérations

- **Upgrade** : bumper `targetRevision` dans `openebs.app.yaml`, commit, push.
- **Debug** :
  ```bash
  kubectl get ns openebs --show-labels          # pod-security.kubernetes.io/enforce=privileged
  kubectl -n openebs get pods                   # controller + node plugin
  kubectl -n openebs logs job/lvmvg-bootstrap   # dernier run du hook (conservé jusqu'au sync suivant)
  kubectl get sc openebs-lvm-thin
  ```
- **PVC `Pending` sans pod** : normal — `WaitForFirstConsumer`, le volume n'est taillé que
  lorsqu'un pod consomme le PVC.
- **Agrandir un volume** : augmenter la taille dans le manifeste/les values du consommateur,
  commit, push (`allowVolumeExpansion: true`, extension à chaud).
- **Espace disponible** : le dashboard « Ressources — volumes »
  ([kube-prometheus-stack](../../app/kube-prometheus-stack/README.md)) donne remplissage par PVC
  et état du VG.
