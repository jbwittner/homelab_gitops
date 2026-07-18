# openebs — bleu-kalecgos

## Rôle

Stockage node-local **LVM** (LocalPV-LVM) sur la partition brute Talos `r-lvmpv` (~370 GiB).
Fournit la StorageClass `openebs-lvm-thin` consommée par les PVC du cluster.

## Source & versions

| Quoi | Valeur |
|---|---|
| Chart | parapluie `openebs` — https://openebs.github.io/openebs |
| Version épinglée | `4.5.1` (embarque lvm-localpv `1.9.1`) |
| Namespace | `openebs` (porté par `manifests/namespace.yaml` — **pas** de CreateNamespace) |
| Release Helm | `openebs` |
| Archétype | (b) Helm + `$values` + `manifests/` |

## Fichiers

- `openebs.app.yaml` — Application (3 sources)
- `helm-values.yaml` — coupe tout sauf le moteur LVM (zfs/hostpath/mayastor/loki/alloy off),
  télémétrie off, mono-nœud
- `manifests/namespace.yaml` — ns `openebs` labellisé **PSA `privileged`** (wave -1) —
  indispensable pour le DaemonSet node-plugin et le Job privileged
- `manifests/vg-bootstrap-job.yaml` — hook `Sync` (wave 0) créant PV+VG `lvmvg` sur
  `/dev/disk/by-partlabel/r-lvmpv`. **Idempotent** (skip si PV/VG déjà présents) et recréé à
  chaque sync (`BeforeHookCreation`) — pas de conflit d'immuabilité Job
- `manifests/storageclass.yaml` — `openebs-lvm-thin` (wave 1), `volgroup: lvmvg`,
  `WaitForFirstConsumer`, extension à chaud

## Dépendances & sync-wave

Wave 0 (Application) ; l'ordonnancement interne est porté par des sync-waves de **ressource** :
ns privileged (-1) → Job VG (0, hook) → StorageClass (1). Dépend de : la partition `r-lvmpv`
(layout Talos, phase 1 du runbook). Requis par : tout PVC (`cnpg`, `test-nginx`, …).

## Opérations courantes

- **Upgrade** : bumper `targetRevision` dans `openebs.app.yaml` ; ne pas toucher
  `lvm-localpv.crds` (voir commentaires de `helm-values.yaml`).
- **Debug** : `kubectl -n openebs get pods`, `kubectl -n openebs logs job/lvmvg-bootstrap`
  (dernier run du hook), `kubectl get sc openebs-lvm-thin`.
- **PVC `Pending` sans pod** : normal — `WaitForFirstConsumer`, le volume n'est créé que
  lorsqu'un pod consomme le PVC.
