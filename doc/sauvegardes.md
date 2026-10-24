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
- pas d'URL signées avec ces identifiants : `velero backup logs`, `download`, `describe --details` échouent ; logs via `kubectl logs deploy/velero` ;
- dépôt Kopia chiffré avec le mot de passe par défaut de Velero : la protection, c'est l'accès au bucket (et OpenBao reste chiffré par sa clé d'unseal).

Un cluster à la fois :

```sh
# malygos
C=bleu-malygos  CTX=admin@bleu-malygos

# kalecgos
C=bleu-kalecgos CTX=admin@bleu-kalecgos
```

## Vérifier

```sh
kubectl --context $CTX -n velero get backupstoragelocation   # PHASE Available
kubectl --context $CTX -n velero get ds node-agent           # READY = nb de nœuds
```

## Sauvegarder OpenBao à la main (malygos)

```sh
kubectl --context admin@bleu-malygos -n velero exec deploy/velero -c velero -- \
  /velero backup create --from-schedule openbao --wait
kubectl --context admin@bleu-malygos -n velero get backups
kubectl --context admin@bleu-malygos -n velero get podvolumebackups   # Completed
```

## Restaurer

À écrire après un test de restauration.
