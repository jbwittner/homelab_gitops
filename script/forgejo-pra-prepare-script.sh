#!/usr/bin/env bash
#
# ⚠️ OBSOLÈTE DEPUIS LE 2026-09-11 — CE SCRIPT NE PEUT PLUS S'EXÉCUTER. La forge a quitté le
# cluster (archive/forgejo) : il n'y a plus de namespace `forgejo`, plus de PVC `forgejo-data`,
# plus de `Cluster` CNPG `forgejo-db`, ni aucune des deux chaînes de sauvegarde qu'il éprouve.
# Il échoue donc dès ses vérifications d'entrée. Conservé pour la MÉTHODE — les pièges encodés
# ci-dessous sont des propriétés de velero, de CNPG et de Forgejo, pas de ce montage-ci — et parce
# que le journal des dix passages (doc/forgejo-pra-exercice.md) s'y réfère.
# La sauvegarde de la forge d'aujourd'hui : doc/forgejo-docker-bascule-et-sauvegarde.md §B.
#
#
# Préparer l'exercice de PRA de forgejo : rendre les deux chaînes de sauvegarde ALIGNABLES.
#
# POURQUOI CE SCRIPT EXISTE, ET POURQUOI IL EST SÉPARÉ DE L'EXERCICE.
#
# L'exercice ([forgejo-pra-script.sh](forgejo-pra-script.sh)) restaure les DEUX moitiés du
# composant — le PVC par velero, la base par barman-cloud — et vérifie qu'elles décrivent le même
# ensemble de dépôts. Cette vérification n'a de sens que si les deux moitiés peuvent venir du même
# instant. Ce n'est PAS acquis, et ça ne se répare pas pendant l'exercice :
#
#   Le PVC ne se déplace pas dans le temps. Il n'existe qu'aux instants où kopia a copié. La base,
#   elle, se rejoue — mais seulement jusqu'où ses WAL sont ARCHIVÉS. Pour que la base puisse
#   rejoindre l'instant du PVC, il faut qu'un WAL couvrant cet instant soit parti dans le bucket.
#
# Or, deux faits se combinent mal :
#
#   1. `archive_timeout = 300` NE VEUT PAS DIRE « un WAL toutes les 5 minutes ». PostgreSQL ne
#      force un basculement de segment sur ce délai QUE s'il y a eu de l'activité WAL depuis le
#      précédent. Une base au repos n'archive RIEN, indéfiniment — relevé 144 221 s, soit 40 h, sur
#      une instance en parfaite santé. Sur cette forge, c'est le régime normal.
#   2. La fenêtre PITR est donc figée à la dernière sauvegarde de base, pendant que velero, lui,
#      continue de copier le PVC toutes les nuits. Les deux dérivent l'une de l'autre.
#
# D'où ce script, et l'ORDRE qu'il impose — le même que celui de la production (base 02:00, PVC
# 03:00), et pour la même raison :
#
#   1. copie velero du PVC       → fige un instant T
#   2. sauvegarde de base CNPG   → son `pg_backup_stop` FORCE un basculement de WAL, ce qui archive
#                                  le segment couvrant T et pousse la fenêtre PITR AU-DELÀ de T
#
# ⚠️ INVERSER LES DEUX NE PRODUIT AUCUNE ERREUR ET NE PRÉPARE RIEN : la fenêtre s'arrêterait AVANT
# l'instant du PVC, et l'exercice refuserait de partir en annonçant qu'aucune sauvegarde velero
# n'est alignable — ce qui ressemble à un bug du script alors que c'est l'ordre qui était faux.
#
# CE QUE `run` CRÉE EST RÉEL, ET COMPTE. Deux sauvegardes de production s'ajoutent à leur rétention
# respective (30 j). Aucune n'est destructive : une sauvegarde est un ÉVÉNEMENT, elle ne modifie
# ni le PVC ni la base. Mais ce ne sont pas des objets de test — elles sont restaurables comme les
# autres, et c'est d'ailleurs le but.
#
# Usage, depuis la racine du dépôt :
#   script/forgejo-pra-prepare-script.sh check    état du recouvrement, ne crée RIEN
#   script/forgejo-pra-prepare-script.sh run      crée les deux sauvegardes, dans l'ordre, et
#                                                 prouve que le recouvrement existe ensuite
#
# Variables d'environnement :
#   YES=1     passe la confirmation de `run`
#   TIMEOUT   transmis aux deux scripts de sauvegarde
#
# Codes de sortie : 0 = l'exercice peut partir, 1 = erreur ou pré-requis manquant,
#                   2 = `check` : aucun recouvrement (rien n'est cassé, il faut juste `run`).

set -euo pipefail

SRC_NS="forgejo"
SRC_CLUSTER="forgejo-db"
SRC_STORE="forgejo-db-store"
VELERO_NS="velero"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CNPG_SCRIPT="$HERE/cnpg-barman-plugin-script.sh"
VELERO_SCRIPT="$HERE/velero-script.sh"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok  \033[0m %s\n' "$*"; }
ko()   { printf '  \033[31mKO  \033[0m %s\n' "$*"; }
note() { printf '  \033[36mnote\033[0m %s\n' "$*"; }

usage() {
  local code="${1:-1}"
  cat >&2 <<'USAGE'
Préparer l'exercice de PRA de forgejo : rendre les deux chaînes de sauvegarde alignables.

  forgejo-pra-prepare-script.sh check
      État du recouvrement entre la fenêtre PITR de barman et les sauvegardes velero. Ne crée
      RIEN. Sortie 0 si l'exercice peut partir, 2 sinon.

  forgejo-pra-prepare-script.sh run
      Crée les deux sauvegardes DANS L'ORDRE — copie velero du PVC, PUIS sauvegarde de base CNPG
      dont le pg_backup_stop force le basculement de WAL qui couvre cet instant — puis rejoue
      `check` pour prouver le résultat.

      ⚠️ Deux sauvegardes RÉELLES de production, comptant dans leur rétention (30 j). Aucune
      n'est destructive.

Ensuite : script/forgejo-pra-script.sh drill
Variables : YES=1 · TIMEOUT
Codes de sortie : 0 prêt · 1 erreur · 2 pas de recouvrement
Documentation : doc/forgejo-pra-exercice.md
USAGE
  exit "$code"
}

require_bins() {
  local bin
  for bin in "$@"; do command -v "$bin" >/dev/null || die "$bin est introuvable dans le PATH."; done
}

confirm() {
  local expected="$1" answer
  if [[ -n "${YES:-}" ]]; then log "YES=1 : confirmation passée."; return 0; fi
  if [[ ! -t 0 ]]; then
    die "Confirmation requise mais l'entrée standard n'est pas un terminal. Relancer avec YES=1."
  fi
  printf 'Taper « %s » pour confirmer (autre chose annule) : ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "Annulé — aucune sauvegarde n'a été créée."
}

# --- Lecture de l'état ---------------------------------------------------------------------------

WIN="" WIN_FIRST="" WIN_LAST="" ALIGNED="" ALIGNED_AT="" SRV=""

# ⚠️ `serverName` SE LIT SUR LE CLUSTER, IL NE SE DÉDUIT PAS DE SON NOM. Il vaut le nom du Cluster
# quand il est OMIS, mais un cluster repris en porte un explicite — la reprise sous le nom d'origine
# fait justement porter les générations par ce champ (`forgejo-db`, puis `-v3`, `-v4`…). Le déduire
# fait lire la fenêtre de la génération MORTE, et c'est un faux positif silencieux dans le pire sens
# possible : les sauvegardes récentes sont déclarées « hors fenêtre », et le script désigne comme
# alignable un couple OBSOLÈTE, sur lequel il ferait ensuite restaurer.
#
# Constaté le 2026-09-09, juste après la première reprise générationnelle : fenêtre affichée
# 15:02→10:44 (génération `forgejo-db`, morte) au lieu de 11:34→12:33 (`forgejo-db-v3`, vivante),
# et une sauvegarde velero de 10:44 retenue à la place de celle de 12:33 prise trente secondes plus
# tôt. `cnpg-barman-plugin-script.sh` lit ce champ correctement depuis toujours et documente le
# piège ; ce script-ci le déduisait.
resolve_server_name() {
  local cl_json srv
  cl_json="$(kubectl -n "$SRC_NS" get clusters.postgresql.cnpg.io "$SRC_CLUSTER" -o json 2>/dev/null || echo '{}')"
  srv="$(jq -r --arg p "barman-cloud.cloudnative-pg.io" --arg c "$SRC_CLUSTER" '
      ([ .spec.plugins[]? | select(.name == $p) ] | first | .parameters.serverName) // $c' <<<"$cl_json")"
  printf '%s' "$srv"
}

read_state() {
  # Global : le serverName résolu est repris dans les messages, qui sinon nommeraient le CLUSTER et
  # enverraient chercher la fenêtre sous la mauvaise clé — la confusion même que ce correctif règle.
  SRV="$(resolve_server_name)"
  WIN="$(kubectl -n "$SRC_NS" get objectstores.barmancloud.cnpg.io "$SRC_STORE" \
        -o jsonpath="{.status.serverRecoveryWindow.$SRV}" 2>/dev/null || true)"
  if [[ -n "$WIN" ]]; then
    WIN_FIRST="$(jq -r '.firstRecoverabilityPoint // ""' <<<"$WIN")"
    WIN_LAST="$(jq -r '.lastSuccessfulBackupTime // ""' <<<"$WIN")"
  fi

  # La dernière sauvegarde velero du namespace dont l'instant de FIN tombe dans la fenêtre. C'est
  # exactement le critère de `forgejo-pra-script.sh` : les deux scripts doivent choisir la même,
  # sans quoi `check` dirait « prêt » et l'exercice refuserait de partir.
  if [[ -n "$WIN_FIRST" && -n "$WIN_LAST" ]]; then
    read -r ALIGNED ALIGNED_AT <<<"$(kubectl -n "$VELERO_NS" get backups.velero.io -o json 2>/dev/null \
      | jq -r --arg ns "$SRC_NS" --arg a "$WIN_FIRST" --arg b "$WIN_LAST" '
          [ .items[]
            | select(.status.phase == "Completed")
            | select((.spec.includedNamespaces // []) | index($ns))
            | select(.status.completionTimestamp >= $a and .status.completionTimestamp <= $b) ]
          | sort_by(.status.completionTimestamp) | last
          | if . == null then "" else "\(.metadata.name) \(.status.completionTimestamp)" end')"
  fi
}

# --- check ---------------------------------------------------------------------------------------

cmd_check() {
  read_state

  log "Fenêtre PITR de la base"
  if [[ -z "$WIN" ]]; then
    ko "aucune fenêtre de récupération pour le serverName « $SRV » sur l'ObjectStore « $SRC_STORE »"
    warn "Le bucket barman ne contient AUCUNE sauvegarde de base exploitable. Ce n'est pas un
    problème de préparation : la chaîne native n'a jamais abouti.
    Diagnostic : script/cnpg-barman-plugin-script.sh list"
    return 2
  fi
  ok "$WIN_FIRST → $WIN_LAST"

  log "Sauvegardes velero du namespace « $SRC_NS »"
  local rows
  rows="$(kubectl -n "$VELERO_NS" get backups.velero.io -o json 2>/dev/null \
    | jq -r --arg ns "$SRC_NS" --arg a "$WIN_FIRST" --arg b "$WIN_LAST" '
        [ .items[]
          | select((.spec.includedNamespaces // []) | index($ns)) ]
        | sort_by(.status.completionTimestamp // "") | reverse | .[0:6][]
        | [ .metadata.name,
            (.status.phase // "-"),
            (.status.completionTimestamp // "-"),
            (if (.status.completionTimestamp // "") >= $a and (.status.completionTimestamp // "") <= $b
             then "DANS la fenêtre" else "hors fenêtre" end) ]
        | @tsv')"
  if [[ -z "$rows" ]]; then
    ko "aucune sauvegarde velero ne couvre le namespace « $SRC_NS »"
    return 2
  fi
  { printf 'NOM\tPHASE\tFIN\tALIGNEMENT\n'; printf '%s\n' "$rows"; } | column -t -s $'\t' | sed 's/^/    /'

  echo
  # ⚠️ Le nombre de VOLUMES, et pas seulement la phase. Une sauvegarde velero sans node-agent est
  # VERTE ET VIDE : les objets passent, les données non. L'exercice restaurerait alors un PVC vide
  # et « prouverait » une reprise qui n'en est pas une.
  if [[ -n "$ALIGNED" ]]; then
    local vols
    vols="$(kubectl -n "$VELERO_NS" get podvolumebackups -l "velero.io/backup-name=$ALIGNED" \
            -o json 2>/dev/null | jq '[.items[] | select(.status.phase == "Completed")] | length')"
    ok "sauvegarde alignable : $ALIGNED (fin $ALIGNED_AT, ${vols:-0} volume(s) copié(s))"
    if [[ "${vols:-0}" -eq 0 ]]; then
      ko "cette sauvegarde ne porte AUCUN volume — objets sauvegardés, données absentes"
      warn "Une sauvegarde velero sans node-agent est verte et vide. L'exercice restaurerait un PVC
    vide. Vérifier le daemonset node-agent avant de préparer :
      kubectl -n $VELERO_NS get daemonset node-agent"
      return 2
    fi
    log "Prêt. L'exercice peut partir :"
    echo "    script/forgejo-pra-script.sh drill"
    return 0
  fi

  ko "aucune sauvegarde velero ne tombe dans la fenêtre PITR"
  note "Ce n'est pas une panne, c'est le régime normal d'une base peu écrite : la fenêtre est figée
       à la dernière sauvegarde de base pendant que velero continue de copier le PVC chaque nuit."
  log "Préparer :"
  echo "    script/forgejo-pra-prepare-script.sh run"
  return 2
}

# --- run -----------------------------------------------------------------------------------------

cmd_run() {
  log "Pré-requis"

  # Les trois contrôles ci-dessous portent sur ce qui rend une sauvegarde SILENCIEUSEMENT INUTILE.
  # Aucun ne bloque une sauvegarde : tous les trois la laissent passer au vert et vide ou
  # incomplète. Les faire ici, avant, évite de préparer un exercice qui prouverait le contraire de
  # ce qu'on croit.
  local ready
  ready="$(kubectl -n "$VELERO_NS" get daemonset node-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -gt 0 ]] \
    && ok "node-agent velero : ${ready} pod(s) prêt(s)" \
    || die "Aucun pod node-agent prêt dans « $VELERO_NS ». La sauvegarde du PVC partirait au VERT
       et VIDE : les objets seraient copiés, les données non. Préparer l'exercice dans cet état
       reviendrait à lui faire prouver une reprise qui n'en est pas une."

  local phase
  phase="$(kubectl -n "$VELERO_NS" get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Available" ]] \
    && ok "BackupStorageLocation « default » : Available" \
    || die "BackupStorageLocation « default » en état « ${phase:-inconnu} ». La sauvegarde
       échouerait APRÈS avoir tout copié."

  local arch
  arch="$(kubectl -n "$SRC_NS" get cluster "$SRC_CLUSTER" -o json 2>/dev/null \
    | jq -r '[.status.conditions[]? | select(.type == "ContinuousArchiving")] | first | .status // "?"')"
  [[ "$arch" == "True" ]] \
    && ok "archivage WAL continu : actif" \
    || die "Condition ContinuousArchiving = « $arch » sur « $SRC_NS/$SRC_CLUSTER ».
       L'archivage WAL est cassé : la sauvegarde de base peut réussir sans qu'aucun WAL ne
       l'accompagne, et la fenêtre PITR ne bougera pas. Diagnostic :
       kubectl -n $SRC_NS logs $SRC_CLUSTER-1 -c plugin-barman-cloud"

  [[ -x "$VELERO_SCRIPT" ]] || die "$VELERO_SCRIPT introuvable ou non exécutable."
  [[ -x "$CNPG_SCRIPT" ]]   || die "$CNPG_SCRIPT introuvable ou non exécutable."

  echo
  log "Deux sauvegardes RÉELLES vont être créées sur la production"
  printf '    1. copie velero du namespace « %s »  — fige l instant du PVC\n' "$SRC_NS"
  printf '    2. sauvegarde de base CNPG de « %s » — force le basculement de WAL qui le couvre\n' "$SRC_CLUSTER"
  printf '    Aucune n est destructive. Les deux comptent dans leur rétention (30 j).\n'
  confirm "$SRC_NS"

  echo
  # ⚠️ L'ORDRE EST LA RAISON D'ÊTRE DE CE SCRIPT. Inversé, il ne prépare rien — voir l'en-tête.
  log "1/2 Copie velero du PVC"
  "$VELERO_SCRIPT" backup || die "La sauvegarde velero a échoué. La rejouer seule pour voir le
       détail : script/velero-script.sh backup"

  echo
  log "2/2 Sauvegarde de base CNPG"
  "$CNPG_SCRIPT" backup || die "La sauvegarde de base CNPG a échoué. La rejouer seule pour voir le
       détail : script/cnpg-barman-plugin-script.sh backup"

  echo
  # La preuve, et non la promesse : on relit l'état plutôt que de supposer que les deux commandes
  # ont produit l'effet attendu.
  log "Vérification du résultat"
  cmd_check
}

# --- Aiguillage ------------------------------------------------------------------------------------

require_bins kubectl jq column

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  run)   shift; cmd_run "$@" ;;
  -h|--help|help) usage 0 ;;
  '')             usage 1 ;;
  *)     die "Commande inconnue : « $1 ». Voir : $(basename "$0") --help" ;;
esac
