#!/usr/bin/env bash
# Voir et gérer les sauvegardes Velero des deux clusters (doc/sauvegardes.md).
# Passe par kubectl et le binaire velero du pod serveur : pas de CLI à installer.
set -euo pipefail

CLUSTERS="malygos kalecgos"

usage() {
  cat <<'USAGE'
Usage : script/velero.sh <commande> [arguments]

  status   [cluster]           emplacement de stockage, node-agent, schedules
  list     [cluster]           sauvegardes (défaut : les deux clusters)
  run      <cluster> <schedule> sauvegarde immédiate depuis un schedule
  describe <cluster> <backup>  détail d'une sauvegarde
  logs     <cluster> <backup>  lignes du serveur Velero pour cette sauvegarde
  delete   <cluster> <backup>  supprime la sauvegarde et ses données (confirmation)

cluster : malygos | kalecgos
USAGE
}

die() { echo "$*" >&2; exit 1; }

ctx() {
  case "$1" in
    malygos | kalecgos) echo "admin@bleu-$1" ;;
    *) die "cluster inconnu : $1 (malygos | kalecgos)" ;;
  esac
}

# Valide le cluster dans le shell courant (ctx en sous-shell ne ferait pas sortir).
check() { ctx "$1" >/dev/null; }

# Clusters visés : celui donné, sinon les deux.
targets() { if [ -n "${1:-}" ]; then echo "$1"; else echo "$CLUSTERS"; fi; }

k() { local c=$1; shift; kubectl --context "$(ctx "$c")" -n velero "$@"; }

# Binaire velero du pod serveur (deploy/velero peut tomber sur un node-agent : mêmes labels).
vx() {
  local c=$1; shift
  k "$c" exec "$(k "$c" get pods -l name=velero -o name)" -c velero -- /velero "$@"
}

header() { printf '\n== bleu-%s ==\n' "$1"; }

cmd_status() {
  [ -z "${1:-}" ] || check "$1"
  for c in $(targets "${1:-}"); do
    header "$c"
    k "$c" get backupstoragelocations \
      -o custom-columns='STOCKAGE:.metadata.name,PHASE:.status.phase,VALIDÉ:.status.lastValidationTime,BUCKET:.spec.objectStorage.bucket'
    k "$c" get daemonset node-agent \
      -o custom-columns='NODE-AGENT:.metadata.name,PRÊTS:.status.numberReady,NŒUDS:.status.desiredNumberScheduled'
    k "$c" get schedules \
      -o custom-columns='SCHEDULE:.metadata.name,CRON:.spec.schedule,PAUSE:.spec.paused,DERNIÈRE:.status.lastBackup,TTL:.spec.template.ttl' 2>/dev/null \
      || true
  done
}

cmd_list() {
  [ -z "${1:-}" ] || check "$1"
  for c in $(targets "${1:-}"); do
    header "$c"
    k "$c" get backups --sort-by=.status.startTimestamp \
      -o custom-columns='SAUVEGARDE:.metadata.name,SCHEDULE:.metadata.labels.velero\.io/schedule-name,PHASE:.status.phase,ERR:.status.errors,WARN:.status.warnings,DÉBUT:.status.startTimestamp,EXPIRE:.status.expiration'
  done
}

cmd_run() {
  [ $# -eq 2 ] || die "usage : run <cluster> <schedule>"
  check "$1"
  vx "$1" backup create --from-schedule "$2" --wait
}

cmd_describe() {
  [ $# -eq 2 ] || die "usage : describe <cluster> <backup>"
  check "$1"
  # pas de --details : URL signées indisponibles avec les identifiants WIF
  vx "$1" backup describe "$2"
}

cmd_logs() {
  [ $# -eq 2 ] || die "usage : logs <cluster> <backup>"
  check "$1"
  # `velero backup logs` exige une URL signée : on filtre les logs du serveur
  # (limités à la vie du pod)
  k "$1" logs -l name=velero -c velero --tail=-1 | grep -F "$2" || echo "aucune ligne (pod redémarré depuis ?)"
}

cmd_delete() {
  [ $# -eq 2 ] || die "usage : delete <cluster> <backup>"
  check "$1"
  k "$1" get backup "$2" >/dev/null
  printf 'Supprimer la sauvegarde %s de bleu-%s et ses données dans le bucket ? [oui/N] ' "$2" "$1"
  read -r answer
  [ "$answer" = "oui" ] || die "annulé"
  vx "$1" backup delete "$2" --confirm
}

command="${1:-status}"
[ $# -gt 0 ] && shift
case "$command" in
  status) cmd_status "$@" ;;
  list) cmd_list "$@" ;;
  run) cmd_run "$@" ;;
  describe) cmd_describe "$@" ;;
  logs) cmd_logs "$@" ;;
  delete) cmd_delete "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 1 ;;
esac
