# Sauvegardes (Velero)

| Fichier | Rôle |
|---|---|
| `components/velero/values.yaml` | plugin GCP, node-agent (Kopia), identifiants WIF (jeton projeté + ConfigMap) |
| `components/velero/manifests/namespace.yaml` | `velero`, PSA `privileged` (node-agent) |
| `clusters/<nom>/velero/values.yaml` | BackupStorageLocation : bucket `homelab-velero-<nom>-050ff71f` |
| `clusters/<nom>/velero/manifests/gcp-credentials.yaml` | ConfigMap `velero-gcp` (`terraform output -json velero`, pas de secret) |
| `clusters/bleu-malygos/velero/manifests/schedule-openbao.yaml` | OpenBao chaque nuit (03:00 UTC), 30 jours |

Côté `homelab_terraform` : `gcp/homelab/velero.tf` (buckets, comptes, Workload Identity Federation), `openbao/bleu-malygos/raft_snapshot.tf` (rôle du hook).

## Fonctionnement

| Point | Choix |
|---|---|
| Identifiants | aucune clé : jeton du compte `velero/velero-server` échangé contre le compte GCP `velero-<nom>` |
| Volumes | copie des fichiers par le node-agent (Kopia) ; snapshots CSI impossibles (lvm-localpv ne restaure pas un snapshot thick) |
| OpenBao | hook avant copie : `bao operator raft snapshot save /openbao/data/openbao.snap`, auth par le jeton du pod |

Limites :
- pas d'URL signées avec ces identifiants : `velero backup logs`, `download`, `describe --details` échouent ; logs via `kubectl logs -l name=velero -c velero` ;
- dépôt Kopia chiffré avec le mot de passe par défaut de Velero : la protection, c'est l'accès au bucket (et OpenBao reste chiffré par sa clé d'unseal).

Un cluster à la fois :

```sh
# malygos
C=bleu-malygos  CTX=admin@bleu-malygos

# kalecgos
C=bleu-kalecgos CTX=admin@bleu-kalecgos
```

## CLI : `script/velero.sh`

kubectl + binaire `velero` du pod serveur, rien à installer. `cluster` : `malygos` | `kalecgos`.

| Commande | Effet |
|---|---|
| `script/velero.sh` / `status [cluster]` | stockage, node-agent, schedules (les deux clusters par défaut) |
| `list [cluster]` | sauvegardes : schedule, phase, erreurs, début, expiration |
| `run <cluster> <schedule>` | sauvegarde immédiate depuis un schedule |
| `describe <cluster> <backup>` | détail (sans `--details`) |
| `logs <cluster> <backup>` | lignes du serveur Velero pour cette sauvegarde (vie du pod seulement) |
| `delete <cluster> <backup>` | supprime sauvegarde et données, après confirmation `oui` |

## Vérifier

```sh
kubectl --context $CTX -n velero get backupstoragelocation   # PHASE Available
kubectl --context $CTX -n velero get ds node-agent           # READY = nb de nœuds
```

## Sauvegarder OpenBao à la main (malygos)

```sh
# pod du serveur (deploy/velero peut tomber sur un node-agent : mêmes labels)
P=$(kubectl --context admin@bleu-malygos -n velero get pods -l name=velero -o name)
kubectl --context admin@bleu-malygos -n velero exec $P -c velero -- \
  /velero backup create --from-schedule openbao --wait
kubectl --context admin@bleu-malygos -n velero get backups
kubectl --context admin@bleu-malygos -n velero get podvolumebackups   # Completed
```

## Restaurer OpenBao

Toujours dans un namespace à part : dans `openbao`, ArgoCD (selfHeal) recrée aussitôt le StatefulSet et son PVC vide.

**1. Restaurer à côté** (testé le 2026-10-24 : données, clé d'unseal et utilisateur `jbwittner` revenus)

```sh
P=$(kubectl --context admin@bleu-malygos -n velero get pods -l name=velero -o name)
kubectl --context admin@bleu-malygos -n velero exec $P -c velero -- /velero backup get
kubectl --context admin@bleu-malygos -n velero exec $P -c velero -- \
  /velero restore create openbao-restore --from-backup <backup> \
  --namespace-mappings openbao:openbao-restore --wait
kubectl --context admin@bleu-malygos -n openbao-restore exec -it openbao-0 -- bao operator unseal   # clé d'origine
```

Les copies portent l'annotation de suivi d'ArgoCD : `openbao-malygos` les affiche et reste `Progressing` tant qu'elles sont là.

**2. Remettre en prod** (pas encore testé)

```sh
kubectl --context admin@bleu-malygos -n openbao-restore cp openbao-0:/openbao/data/openbao.snap ~/openbao.snap
```

Sur l'OpenBao de prod (vide après une reconstruction : `bao operator init` + unseal provisoires) :

```sh
kubectl --context admin@bleu-malygos -n openbao cp ~/openbao.snap openbao-0:/tmp/openbao.snap
kubectl --context admin@bleu-malygos -n openbao exec -it openbao-0 -- \
  sh -c 'bao login && bao operator raft snapshot restore -force /tmp/openbao.snap'   # token root provisoire
kubectl --context admin@bleu-malygos -n openbao exec -it openbao-0 -- bao operator unseal  # clé d'origine
```

**3. Ménage**

```sh
PV=$(kubectl --context admin@bleu-malygos -n openbao-restore get pvc data-openbao-0 -o jsonpath='{.spec.volumeName}')
kubectl --context admin@bleu-malygos delete namespace openbao-restore
kubectl --context admin@bleu-malygos -n openebs delete lvmvolume $PV
kubectl --context admin@bleu-malygos delete pv $PV
kubectl --context admin@bleu-malygos -n velero exec $P -c velero -- /velero restore delete openbao-restore --confirm
command rm ~/openbao.snap
```
