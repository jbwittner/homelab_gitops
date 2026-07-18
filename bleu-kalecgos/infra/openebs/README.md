# openebs

## Rôle

Stockage node-local **LVM** (LocalPV-LVM) sur la partition brute Talos `r-lvmpv`.
Fournit la StorageClass `openebs-lvm-thin` consommée par les PVC du cluster.

## Fichiers

- `openebs.app.yaml` — Application (archétype (b) : chart parapluie + `$values` + `manifests/`)
- `helm-values.yaml` — coupe tout sauf le moteur LVM, télémétrie off, mono-nœud
- `manifests/namespace.yaml` — ns `openebs` labellisé **PSA `privileged`** (wave -1) —
  indispensable pour le DaemonSet node-plugin et le Job privileged (d'où : pas de
  `CreateNamespace`)
- `manifests/vg-bootstrap-job.yaml` — hook `Sync` (wave 0) créant PV+VG `lvmvg` sur
  `/dev/disk/by-partlabel/r-lvmpv`. **Idempotent**, recréé à chaque sync (`BeforeHookCreation`)
- `manifests/storageclass.yaml` — `openebs-lvm-thin` (wave 1), `volgroup: lvmvg`,
  `WaitForFirstConsumer`, extension à chaud

## Opérations

- **Upgrade** : bumper `targetRevision` dans `openebs.app.yaml` ; ne pas toucher
  `lvm-localpv.crds` (voir commentaires de `helm-values.yaml`).
- **Debug** : `kubectl -n openebs get pods`, `kubectl -n openebs logs job/lvmvg-bootstrap`,
  `kubectl get sc openebs-lvm-thin`.
- **PVC `Pending` sans pod** : normal — `WaitForFirstConsumer`, le volume n'est créé que
  lorsqu'un pod consomme le PVC.
