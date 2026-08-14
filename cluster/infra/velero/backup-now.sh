#!/usr/bin/env bash
#
# Déclenche une sauvegarde velero MANUELLE au périmètre exact de la Schedule, puis suit son
# déroulement jusqu'au bout.
#
# POURQUOI CE SCRIPT EXISTE. Le périmètre d'une sauvegarde vit sur l'objet `Backup`, pas sur
# velero : un `includedNamespaces` omis vaut `["*"]`, soit tout le cluster. Retaper la liste à la
# main, c'est prendre le risque de sauvegarder 20 Gi de TSDB Prometheus par distraction. Ici la
# spec est RECOPIÉE depuis la Schedule : elle ne peut pas diverger de ce qui tourne chaque nuit.
#
# CE N'EST PAS UNE VIOLATION DE LA RÈGLE GITOPS. Un `Backup` est un ÉVÉNEMENT, pas un état désiré :
# committé, ArgoCD le recréerait indéfiniment après chaque expiration de TTL. Sa place est une
# commande, au même titre que `bao operator unseal`.
#
# Usage, depuis n'importe où :
#   cluster/infra/velero/backup-now.sh                 # schedule `velero-daily`, attend la fin
#   cluster/infra/velero/backup-now.sh autre-schedule
#   DRY_RUN=1   cluster/infra/velero/backup-now.sh     # affiche le manifeste, ne crée rien
#   NO_WAIT=1   cluster/infra/velero/backup-now.sh     # crée et rend la main immédiatement
#   TIMEOUT=3600 cluster/infra/velero/backup-now.sh    # plafond d'attente en secondes (défaut 1800)
#
# Codes de sortie : 0 = Completed, 1 = échec ou pré-requis manquant, 2 = PartiallyFailed,
#                   3 = délai d'attente dépassé (la sauvegarde, elle, continue).

set -euo pipefail

SCHEDULE="${1:-velero-daily}"
NAMESPACE="${VELERO_NAMESPACE:-velero}"
TIMEOUT="${TIMEOUT:-1800}"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

# --- Pré-requis -------------------------------------------------------------------------------
for bin in kubectl jq; do
  command -v "$bin" >/dev/null || die "$bin est introuvable dans le PATH."
done

kubectl -n "$NAMESPACE" get schedule "$SCHEDULE" >/dev/null 2>&1 \
  || die "Schedule '$SCHEDULE' absente du namespace '$NAMESPACE'. Schedules connues :
$(kubectl -n "$NAMESPACE" get schedules.velero.io -o name 2>/dev/null || echo '  (aucune)')"

# Une schedule en pause reste copiable : on prévient sans bloquer, la pause ne concerne que le
# déclenchement automatique.
if [[ "$(kubectl -n "$NAMESPACE" get schedule "$SCHEDULE" -o jsonpath='{.spec.paused}')" == "true" ]]; then
  warn "La schedule '$SCHEDULE' est en PAUSE. Son périmètre reste valide, la sauvegarde manuelle part quand même."
fi

# Sans BSL disponible, la sauvegarde échoue après avoir tout copié : autant le dire tout de suite.
BSL="$(kubectl -n "$NAMESPACE" get schedule "$SCHEDULE" -o jsonpath='{.spec.template.storageLocation}')"
BSL="${BSL:-default}"
BSL_PHASE="$(kubectl -n "$NAMESPACE" get backupstoragelocation "$BSL" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$BSL_PHASE" == "Available" ]] \
  || die "BackupStorageLocation '$BSL' en état '${BSL_PHASE:-inconnu}' (attendu : Available).
       Credential, droits IAM ou bucket : voir la section Opérations du README."

# Aucun node-agent = les objets seront sauvegardés, les DONNÉES non, et la sauvegarde sera verte.
READY_AGENTS="$(kubectl -n "$NAMESPACE" get daemonset node-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
[[ "${READY_AGENTS:-0}" -gt 0 ]] \
  || warn "Aucun pod node-agent prêt : les données des PV ne seront PAS copiées (la sauvegarde passera quand même au vert)."

# --- Construction du manifeste ----------------------------------------------------------------
# `.spec.template` de la Schedule = la spec du Backup, à l'identique. Le label
# `velero.io/schedule-name` est délibérément OMIS (la CLI, elle, le pose avec `--from-schedule`) :
# il ferait compter cette sauvegarde comme une exécution de la schedule dans les métriques, ce qui
# éteindrait l'alerte VeleroBackupTooOld alors que la schedule n'aurait pas tourné.
MANIFEST="$(kubectl -n "$NAMESPACE" get schedule "$SCHEDULE" -o json | jq \
  --arg ns "$NAMESPACE" \
  --arg sched "$SCHEDULE" '{
    apiVersion: "velero.io/v1",
    kind: "Backup",
    metadata: {
      generateName: "manual-",
      namespace: $ns,
      annotations: { "homelab.wittner.tech/derived-from-schedule": $sched }
    },
    spec: .spec.template
  }')"

if [[ -n "${DRY_RUN:-}" ]]; then
  log "DRY_RUN : manifeste qui serait créé (rien n'est envoyé au cluster)"
  echo "$MANIFEST" | jq .
  exit 0
fi

log "Périmètre repris de la schedule '$SCHEDULE' : $(echo "$MANIFEST" | jq -c '.spec.includedNamespaces // ["*"]')"

BACKUP="$(echo "$MANIFEST" | kubectl create -f - -o jsonpath='{.metadata.name}')"
log "Sauvegarde créée : $BACKUP"

if [[ -n "${NO_WAIT:-}" ]]; then
  log "NO_WAIT : suivi laissé à l'appelant."
  echo "  kubectl -n $NAMESPACE get backups.velero.io $BACKUP -o yaml"
  exit 0
fi

# --- Suivi ------------------------------------------------------------------------------------
log "Suivi (Ctrl-C interrompt l'affichage, PAS la sauvegarde)…"
DEADLINE=$(( SECONDS + TIMEOUT ))
PHASE=""
LAST=""
while :; do
  PHASE="$(kubectl -n "$NAMESPACE" get backups.velero.io "$BACKUP" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  DONE="$(kubectl -n "$NAMESPACE" get backups.velero.io "$BACKUP" -o jsonpath='{.status.progress.itemsBackedUp}' 2>/dev/null || true)"
  TOTAL="$(kubectl -n "$NAMESPACE" get backups.velero.io "$BACKUP" -o jsonpath='{.status.progress.totalItems}' 2>/dev/null || true)"
  LINE="$(printf '    phase=%-16s éléments=%s/%s' "${PHASE:-…}" "${DONE:-0}" "${TOTAL:-?}")"

  if [[ -t 1 ]]; then
    # Terminal : une seule ligne réécrite en place.
    printf '\r%s   ' "$LINE"
  elif [[ "$LINE" != "$LAST" ]]; then
    # Redirigé (cron, CI, `| tee`) : le retour chariot empilerait des lignes illisibles —
    # on n'écrit donc qu'aux CHANGEMENTS d'état.
    printf '%s\n' "$LINE"
    LAST="$LINE"
  fi

  case "$PHASE" in
    Completed|PartiallyFailed|Failed|FailedValidation) break ;;
  esac
  (( SECONDS < DEADLINE )) || { [[ -t 1 ]] && printf '\n'; warn "Délai de ${TIMEOUT}s dépassé — la sauvegarde continue côté cluster."; exit 3; }
  sleep 5
done
[[ -t 1 ]] && printf '\n' || true

# --- Bilan ------------------------------------------------------------------------------------
# Le nombre de PodVolumeBackup est le seul contrôle qui distingue une vraie sauvegarde d'une
# sauvegarde « verte et vide » : les objets Kubernetes passent toujours, les données non.
PVB_JSON="$(kubectl -n "$NAMESPACE" get podvolumebackups \
  -l "velero.io/backup-name=$BACKUP" -o json 2>/dev/null || echo '{"items":[]}')"
echo "$PVB_JSON" | jq -r '
  [.items[]] as $p
  | ($p | length) as $n
  | ([$p[].status.progress.totalBytes // 0] | add // 0) as $bytes
  | ([$p[] | select(.status.phase != "Completed")] | length) as $ko
  | "    volumes copiés : \($n) (\($ko) non terminés) — \(($bytes/1048576*10|floor)/10) Mio"'

case "$PHASE" in
  Completed)
    if [[ "$(echo "$PVB_JSON" | jq '.items | length')" == "0" ]]; then
      warn "Sauvegarde Completed mais AUCUN volume copié : objets sauvegardés, données absentes."
      warn "Vérifier node-agent (label PodSecurity du namespace, taints des nœuds)."
    fi
    log "Terminée : $BACKUP"
    ;;
  PartiallyFailed)
    warn "PartiallyFailed : restaurable mais incomplète. Détail :"
    echo "  kubectl -n $NAMESPACE get backups.velero.io $BACKUP -o jsonpath='{.status.failureReason}{\"\\n\"}'"
    exit 2
    ;;
  *)
    die "État final '$PHASE'. Logs du serveur : kubectl -n $NAMESPACE logs deploy/velero"
    ;;
esac
