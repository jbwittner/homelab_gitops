# Stockage (OpenEBS LocalPV LVM)

| Fichier | Rôle |
|---|---|
| `components/openebs/values.yaml` | chart parapluie `openebs`, LVM seul |
| `components/openebs/manifests/namespace.yaml` | `openebs`, PSA `privileged` |
| `components/openebs/manifests/vg-bootstrap.yaml` | DaemonSet : VG `openebs-vg` sur la partition `r-lvmpv` de chaque nœud |
| `components/openebs/manifests/storageclass.yaml` | `openebs-lvm` (défaut) : thick, ext4, `Retain`, `WaitForFirstConsumer` |
| `clusters/<nom>/openebs/openebs.app.yaml` | `openebs-<cluster-court>` |

Prérequis Talos (dépôt `homelab_talos`) : `RawVolumeConfig` `lvmpv` sur le disque data, modules `dm_mod`, `dm_thin_pool`, `dm_snapshot`.

Un cluster à la fois :

```sh
# malygos
C=bleu-malygos  CTX=admin@bleu-malygos

# kalecgos
C=bleu-kalecgos CTX=admin@bleu-kalecgos
```

## Fonctionnement

| Question | Réponse |
|---|---|
| PVC de 15 Gi | 15 Gi réservés tout de suite (thick) dans le VG d'**un** nœud |
| Quel nœud | choisi au premier démarrage du pod (`WaitForFirstConsumer`), parmi ceux qui ont la place |
| Ensuite | volume et pod liés à ce nœud ; nœud arrêté = pod `Pending` jusqu'à son retour |
| Agrandir | monter `storage` dans la demande (commit) : `lvextend` + `resize2fs` à chaud, sans redémarrer le pod |
| Limite d'agrandissement | place libre du VG **de ce nœud** ; pas de déplacement vers un autre nœud |
| Réduire | impossible (Kubernetes refuse) : nouveau PVC + copie |
| StatefulSet | `volumeClaimTemplates` non modifiable : agrandir chaque PVC, puis aligner la valeur dans Git |

## Vérifier

```sh
kubectl --context $CTX -n openebs get ds                  # vg-bootstrap et lvm-localpv-node : READY = nb de nœuds
kubectl --context $CTX -n openebs get lvmnodes \
  -o custom-columns=NODE:.metadata.name,VG:.volumeGroups[*].name,FREE:.volumeGroups[*].free
kubectl --context $CTX get sc                             # openebs-lvm (default)
```

Volume jetable :

```sh
kubectl --context $CTX create -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: lvm-test, namespace: default}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: lvm-test, namespace: default}
spec:
  containers:
    - {name: t, image: busybox, command: [sh, -c, 'echo ok > /data/f && cat /data/f && sleep 3600'],
       volumeMounts: [{name: d, mountPath: /data}]}
  volumes: [{name: d, persistentVolumeClaim: {claimName: lvm-test}}]
YAML
kubectl --context $CTX logs lvm-test                      # ok (une fois Running)
PV=$(kubectl --context $CTX get pvc lvm-test -o jsonpath='{.spec.volumeName}')
kubectl --context $CTX delete pod,pvc lvm-test
```

Puis supprimer le volume (section suivante, avec `$PV`).

## Retain : après suppression d'un PVC

Le PV passe `Released`, le volume LVM reste.

| But | Commandes |
|---|---|
| Lister | `kubectl --context $CTX get pv` (STATUS `Released`) |
| Libérer la place | `kubectl --context $CTX -n openebs delete lvmvolume $PV` puis `kubectl --context $CTX delete pv $PV` |
| Réutiliser les données | `kubectl --context $CTX patch pv $PV --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'`, puis un PVC avec `volumeName: $PV` |

Supprimer seulement le PV ne libère rien : c'est la suppression du `LVMVolume` qui efface le volume LVM.

## Vider un VG (disque réutilisé, ancien VG)

Destructif. Refuse si le VG contient encore des volumes. Talos n'a pas lvm : pod `debug` avec l'image du driver, dans `kube-system` (exempté de PSA).

```sh
VG=lvmvg   # nom trouvé par `vgs`

for N in $(kubectl --context $CTX get nodes -o name); do
  kubectl --context $CTX -n kube-system debug $N -it --profile=sysadmin \
    --image=docker.io/openebs/lvm-driver:1.10.1 -- sh -ec "
      [ \$(lvs --noheadings $VG | wc -l) -eq 0 ] || { echo '$VG contient des volumes, abandon'; exit 1; }
      PV=\$(pvs --noheadings -o pv_name -S vg_name=$VG | tr -d ' ')
      vgremove -y $VG && pvremove -y \$PV && pvs"
done

kubectl --context $CTX -n kube-system get pods -o name | grep node-debugger \
  | xargs kubectl --context $CTX -n kube-system delete
```

`vg-bootstrap` recrée `openebs-vg` au démarrage suivant de ses pods.
