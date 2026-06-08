# local-path-provisioner (neltharion)

StorageClass **par défaut** du cluster, fournie par
[rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) selon le
guide Talos *[Local Storage](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage)*.
Sur ce mono-node Talos il n'y a pas d'autre CSI : tout PVC sans `storageClassName` atterrit ici.

## Comment c'est câblé

Application Argo **single-source Kustomize** (`local-path-provisioner.app.yaml`, wave 1). Le
`kustomization.yaml` référence le **manifest upstream pinné par tag** et lui applique 3 patches :

| Fichier | Cible | Effet |
|---------|-------|-------|
| `patch-config.yaml` | ConfigMap `local-path-config` (clé `config.json`) | PV stockés dans `/var/mnt/data/local-path-provisioner` |
| `patch-default-storageclass.yaml` | StorageClass `local-path` | `is-default-class=true` |
| `patch-namespace-psa.yaml` | Namespace `local-path-storage` | labels PSA `privileged` (helper-pods en hostPath) |

## Dépendance disque (Talos, hors de ce repo)

Le chemin `/var/mnt/data` est le point de montage du **`UserVolumeConfig name: data`** déclaré
côté `homelab-talos` (disque dédié, hors disque système). Talos monte un user volume sur
`/var/mnt/<nom>`, donc `data` → `/var/mnt/data`. Le sous-dossier `local-path-provisioner/` est
créé automatiquement par le helper-pod au premier provisioning.

> ⚠️ Si le volume `data` n'est pas appliqué sur le nœud, les PV seraient écrits sur le disque
> système. Vérifier `talosctl get uservolumeconfig` / `talosctl ls /var/mnt`.

## Bump de version

Changer le tag dans `kustomization.yaml`
(`.../local-path-provisioner/<TAG>/deploy/local-path-storage.yaml`) ; l'image du Deployment est
versionnée dans ce manifest et suit donc le tag. Dernière stable vérifiée : **v0.0.36**.

## Vérification

```bash
kubectl get sc                                   # local-path (default)
kubectl -n local-path-storage get deploy         # local-path-provisioner disponible
talosctl ls /var/mnt/data/local-path-provisioner # dossiers des PV provisionnés sur le nœud
```
