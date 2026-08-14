#!/usr/bin/env bash
#
# Gestion des sauvegardes velero : lister, sauvegarder, restaurer, supprimer.
#
# POURQUOI CE SCRIPT EXISTE. Trois pièges du composant, qui coûtent tous une sauvegarde ou une
# restauration silencieusement fausse :
#
#   1. Le PÉRIMÈTRE vit sur l'objet `Backup`/`Restore`, pas sur velero. Un `includedNamespaces`
#      omis vaut `["*"]`, soit tout le cluster — 20 Gi de TSDB Prometheus par distraction. Ici la
#      spec est TOUJOURS DÉRIVÉE (d'une Schedule pour un backup, du Backup source pour un restore),
#      jamais retapée : elle ne peut pas diverger de ce qui tourne chaque nuit.
#   2. `kubectl get backups` ne montre PAS les sauvegardes velero : le nom court est ambigu avec
#      `backups.postgresql.cnpg.io` (cnpg) et kubectl tranche en faveur de CNPG. La réponse
#      `No resources found` ressemble à « aucune sauvegarde n'a tourné ». Le script écrit partout
#      le nom long `backups.velero.io`.
#   3. Une sauvegarde sans node-agent est VERTE ET VIDE : les objets passent, les données non. Le
#      nombre de volumes copiés est affiché partout — c'est le seul contrôle qui les distingue.
#
# CE N'EST PAS UNE VIOLATION DE LA RÈGLE GITOPS. Un `Backup`, un `Restore` et une
# `DeleteBackupRequest` sont des ÉVÉNEMENTS, pas des états désirés : committés, ArgoCD les
# recréerait indéfiniment après chaque expiration de TTL. Leur place est une commande, au même
# titre que `bao operator unseal`.
#
# Usage, depuis n'importe où :
#   cluster/infra/velero/velero-script.sh list [motif]
#   cluster/infra/velero/velero-script.sh show <backup>
#   cluster/infra/velero/velero-script.sh backup [schedule]
#   cluster/infra/velero/velero-script.sh restore <backup> [-n ns[,ns]] [--overwrite]
#   cluster/infra/velero/velero-script.sh delete <backup>
#
# Variables d'environnement :
#   VELERO_NAMESPACE   namespace velero (défaut `velero`)
#   TIMEOUT            plafond d'attente en secondes (défaut 1800)
#   DRY_RUN=1          affiche le manifeste qui serait créé, n'envoie rien au cluster
#   NO_WAIT=1          crée l'objet et rend la main sans suivre son déroulement
#   YES=1              passe les confirmations interactives (restore, delete)
#
# Codes de sortie : 0 = succès, 1 = échec ou pré-requis manquant, 2 = PartiallyFailed,
#                   3 = délai d'attente dépassé (l'opération, elle, continue côté cluster).

set -euo pipefail

NAMESPACE="${VELERO_NAMESPACE:-velero}"
TIMEOUT="${TIMEOUT:-1800}"
DEFAULT_SCHEDULE="velero-daily"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  local code="${1:-1}"
  cat >&2 <<'EOF'
Gestion des sauvegardes velero (le nom est explicite : ce n'est PAS la CLI `velero`, tout passe
par kubectl et jq).

  velero-script.sh list [motif]
      Sauvegardes, schedules et restaurations, avec le nombre de volumes réellement copiés.
      La colonne NS donne le NOMBRE de namespaces — « * » signifie tout le cluster.

  velero-script.sh show <backup>
      Détail d'une sauvegarde : périmètre complet, erreurs, et le tableau volume par volume.

  velero-script.sh backup [schedule]
      Sauvegarde manuelle au périmètre EXACT de la schedule (défaut : velero-daily).

  velero-script.sh restore <backup> [-n ns[,ns]] [--overwrite]
      Restaure une sauvegarde. Périmètre repris du backup source, jamais retapé.
      -n, --namespace   restreint le périmètre (doit être inclus dans celui du backup)
          --overwrite   existingResourcePolicy=update — ÉCRASE les objets déjà en place

  velero-script.sh delete <backup>
      DeleteBackupRequest : efface la sauvegarde ET ses données dans le bucket.

Variables : VELERO_NAMESPACE (velero) · TIMEOUT (1800) · DRY_RUN=1 · NO_WAIT=1 · YES=1
Codes de sortie : 0 succès · 1 erreur · 2 PartiallyFailed · 3 délai dépassé
EOF
  exit "$code"
}

# --- Socle commun -----------------------------------------------------------------------------

require_bins() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null || die "$bin est introuvable dans le PATH."
  done
}

# Sans BSL disponible, une sauvegarde échoue APRÈS avoir tout copié et une restauration ne trouve
# rien à lire : autant le dire tout de suite. Volontairement NON appelée par `list`, qui doit rester
# consultable quand le bucket est cassé — c'est justement le moment où on la lance.
require_bsl() {
  local bsl="${1:-default}" phase
  phase="$(kubectl -n "$NAMESPACE" get backupstoragelocation "$bsl" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Available" ]] \
    || die "BackupStorageLocation '$bsl' en état '${phase:-inconnu}' (attendu : Available).
       Credential, droits IAM ou bucket : voir la section Opérations du README."
}

# Confirmation par frappe exacte du nom de l'objet visé : un `y/n` se tape sans lire.
confirm() {
  local expected="$1" answer
  if [[ -n "${YES:-}" ]]; then
    log "YES=1 : confirmation passée."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "Confirmation requise mais l'entrée standard n'est pas un terminal.
       Relancer avec YES=1 en connaissance de cause."
  fi
  printf 'Taper « %s » pour confirmer (autre chose annule) : ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "Annulé — rien n'a été créé."
}

# Suit un objet jusqu'à une phase terminale. Renseigne la globale PHASE pour l'appelant.
#   $1 kind (nom LONG)   $2 nom   $3 champ de progression ("" si l'objet n'en a pas)
#   $4 phases terminales, séparées par « | » pour un motif `case`
PHASE=""
wait_phase() {
  local kind="$1" name="$2" field="$3" terminal="$4"
  local deadline=$(( SECONDS + TIMEOUT )) line last="" obj cur total missing=0
  PHASE=""
  while :; do
    if obj="$(kubectl -n "$NAMESPACE" get "$kind" "$name" -o json 2>/dev/null)"; then
      missing=0
      PHASE="$(jq -r '.status.phase // ""' <<<"$obj")"
      if [[ -n "$field" ]]; then
        cur="$(jq -r ".status.progress.$field // 0" <<<"$obj")"
        total="$(jq -r '.status.progress.totalItems // 0' <<<"$obj")"
        line="$(printf '    phase=%-16s éléments=%s/%s' "${PHASE:-…}" "$cur" "$total")"
      else
        line="$(printf '    phase=%-16s' "${PHASE:-…}")"
      fi
    else
      # L'objet peut disparaître sous nos pieds — le contrôleur velero recycle les
      # DeleteBackupRequest une fois traitées. Deux lectures manquées d'affilée : fin de partie,
      # sans quoi la boucle tournerait jusqu'au TIMEOUT sur un objet qui n'existe plus.
      missing=$(( missing + 1 ))
      if (( missing >= 2 )); then
        [[ -t 1 ]] && printf '\n' || true
        warn "$kind/$name a disparu — le contrôleur l'a recyclé avant la fin du suivi."
        PHASE="${PHASE:-Disparu}"
        return 0
      fi
      line="$(printf '    phase=%-16s' "${PHASE:-…}")"
    fi

    if [[ -t 1 ]]; then
      # Terminal : une seule ligne réécrite en place.
      printf '\r%s   ' "$line"
    elif [[ "$line" != "$last" ]]; then
      # Redirigé (cron, CI, `| tee`) : le retour chariot empilerait des lignes illisibles —
      # on n'écrit donc qu'aux CHANGEMENTS d'état.
      printf '%s\n' "$line"
      last="$line"
    fi

    # shellcheck disable=SC2254  # `terminal` est un motif case, l'absence de guillemets est voulue
    case "$PHASE" in
      $terminal) break ;;
    esac
    if (( SECONDS >= deadline )); then
      [[ -t 1 ]] && printf '\n' || true
      warn "Délai de ${TIMEOUT}s dépassé — l'opération continue côté cluster."
      exit 3
    fi
    sleep 5
  done
  [[ -t 1 ]] && printf '\n' || true
}

# Bilan des volumes attachés à un backup ou un restore. $1 kind, $2 label, $3 valeur du label.
# Le NOMBRE DE VOLUMES est le seul contrôle qui distingue une vraie sauvegarde d'une sauvegarde
# « verte et vide » : les objets Kubernetes passent toujours, les données non.
volumes_json() {
  kubectl -n "$NAMESPACE" get "$1" -l "$2=$3" -o json 2>/dev/null || echo '{"items":[]}'
}

volumes_summary() {
  jq -r '
    [.items[]] as $p
    | ($p | length) as $n
    | ([$p[].status.progress.totalBytes // 0] | add // 0) as $bytes
    | ([$p[] | select(.status.phase != "Completed")] | length) as $ko
    | "    volumes : \($n) (\($ko) non terminés) — \(($bytes/1048576*10|floor)/10) Mio"'
}

# Formatage relatif d'un timestamp RFC3339, partagé par les trois tableaux de `list`.
JQ_REL='
  def rel($t):
    if $t == null or $t == "" then "-"
    else
      (($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - now) as $d
      | (if $d < 0 then -$d else $d end) as $a
      | (if   $a < 3600  then "\(($a/60)    | floor) min"
         elif $a < 86400 then "\(($a/3600)  | floor) h"
         else                 "\(($a/86400) | floor) j" end) as $u
      | if $d < 0 then "il y a \($u)" else "dans \($u)" end
    end;
'

# --- list -------------------------------------------------------------------------------------

cmd_list() {
  local pattern="${1:-}"
  local bk pvb sc rs

  bk="$(kubectl -n "$NAMESPACE" get backups.velero.io -o json 2>/dev/null || echo '{"items":[]}')"
  pvb="$(kubectl -n "$NAMESPACE" get podvolumebackups -o json 2>/dev/null || echo '{"items":[]}')"
  sc="$(kubectl -n "$NAMESPACE" get schedules.velero.io -o json 2>/dev/null || echo '{"items":[]}')"
  rs="$(kubectl -n "$NAMESPACE" get restores.velero.io -o json 2>/dev/null || echo '{"items":[]}')"

  log "Sauvegardes${pattern:+ (motif « $pattern »)}"
  {
    printf 'NOM\tPHASE\tCREEE\tEXPIRE\tSOURCE\tNS\tOBJETS\tVOLUMES\tTAILLE\n'
    jq -r --argjson pvb "$pvb" --arg pat "$pattern" "$JQ_REL"'
      # Un seul passage sur les podvolumebackups, regroupés par sauvegarde.
      ( [ $pvb.items[]
          | { n: (.metadata.labels["velero.io/backup-name"] // ""),
              b: (.status.progress.totalBytes // 0) } ]
        | group_by(.n)
        | map({ key: .[0].n, value: { n: length, b: (map(.b) | add) } })
        | from_entries ) as $vol
      | [ .items[] | select(.metadata.name | contains($pat)) ]
      | sort_by(.metadata.creationTimestamp) | reverse
      | .[]
      | . as $b
      | ($vol[$b.metadata.name] // {n: 0, b: 0}) as $v
      | ( $b.metadata.labels["velero.io/schedule-name"] ) as $sched
      | ( $b.metadata.annotations["homelab.wittner.tech/derived-from-schedule"] ) as $der
      | [ $b.metadata.name,
          ($b.status.phase // "-"),
          rel($b.metadata.creationTimestamp),
          rel($b.status.expiration),
          (if $sched then $sched elif $der then "manuel (\($der))" else "manuel" end),
          # Compteur et non la liste : la liste grandit avec le périmètre et déformerait le
          # tableau. Le cas dangereux reste lisible — « * » = tout le cluster. Détail dans `show`.
          (($b.spec.includedNamespaces // ["*"]) | if . == ["*"] then "*" else (length | tostring) end),
          ($b.status.progress.itemsBackedUp // 0 | tostring),
          ($v.n | tostring),
          "\(($v.b/1048576*10|floor)/10) Mio",
          (if $b.status.phase == "Completed" and $v.n == 0 then "⚠ aucune donnée" else "" end) ]
      | @tsv' <<<"$bk"
  } | column -t -s $'\t'

  # Note de pied de tableau, posée seulement s'il y a au moins une ligne marquée.
  if jq -e --argjson pvb "$pvb" '
        [ $pvb.items[].metadata.labels["velero.io/backup-name"] ] as $with
        | any(.items[];
              .status.phase == "Completed"
              and ((.metadata.name as $n | $with | index($n)) | not))' \
        <<<"$bk" >/dev/null; then
    warn "⚠ = sauvegarde Completed sans AUCUN volume copié : objets sauvegardés, données absentes."
    warn "    Vérifier node-agent (label PodSecurity du namespace, taints des nœuds)."
  fi
  echo "    Détail d'une sauvegarde (périmètre complet, volume par volume) : velero-script.sh show <nom>"

  echo
  log "Schedules"
  {
    printf 'NOM\tCRON\tPAUSED\tDERNIERE\tTTL\tNAMESPACES\n'
    jq -r "$JQ_REL"'
      .items[]
      | [ .metadata.name,
          .spec.schedule,
          ((.spec.paused // false) | tostring),
          rel(.status.lastBackup),
          (.spec.template.ttl // "-"),
          ((.spec.template.includedNamespaces // ["*"]) | join(",")) ]
      | @tsv' <<<"$sc"
  } | column -t -s $'\t'

  if [[ "$(jq '.items | length' <<<"$rs")" != "0" ]]; then
    echo
    log "Restaurations"
    {
      printf 'NOM\tPHASE\tBACKUP\tCREEE\tNS\tERREURS\n'
      jq -r "$JQ_REL"'
        .items
        | sort_by(.metadata.creationTimestamp) | reverse
        | .[]
        | [ .metadata.name,
            (.status.phase // "-"),
            .spec.backupName,
            rel(.metadata.creationTimestamp),
            ((.spec.includedNamespaces // ["*"]) | if . == ["*"] then "*" else (length | tostring) end),
            ((.status.errors // 0) | tostring) ]
        | @tsv' <<<"$rs"
    } | column -t -s $'\t'
  fi
}

# --- show -------------------------------------------------------------------------------------

# Le détail d'UNE sauvegarde. Existe parce que `list` ne peut pas tout porter : la liste des
# namespaces s'allonge avec le périmètre et déformerait le tableau. C'est ici qu'on la lit, avec
# le détail volume par volume — le seul endroit où l'on voit ce qui a VRAIMENT été copié.
cmd_show() {
  local backup="${1:-}"
  [[ -n "$backup" ]] || usage

  local bk pvb
  bk="$(kubectl -n "$NAMESPACE" get backups.velero.io "$backup" -o json 2>/dev/null)" \
    || die "Sauvegarde '$backup' introuvable dans '$NAMESPACE'. Lister : velero-script.sh list"
  pvb="$(volumes_json podvolumebackups velero.io/backup-name "$backup")"

  log "Sauvegarde $backup"
  jq -r "$JQ_REL"'
    ( .metadata.labels["velero.io/schedule-name"] ) as $sched
    | ( .metadata.annotations["homelab.wittner.tech/derived-from-schedule"] ) as $der
    | "    phase         : \(.status.phase // "-")",
      "    créée         : \(.metadata.creationTimestamp) (\(rel(.metadata.creationTimestamp)))",
      "    expire        : \(.status.expiration // "-") (\(rel(.status.expiration)))",
      "    source        : \(if $sched then $sched elif $der then "manuel (\($der))" else "manuel" end)",
      "    stockage      : \(.spec.storageLocation // "default")   TTL : \(.spec.ttl // "-")",
      "    objets        : \(.status.progress.itemsBackedUp // 0)/\(.status.progress.totalItems // 0)",
      "    erreurs       : \(.status.errors // 0)   avertissements : \(.status.warnings // 0)",
      (if .status.failureReason then "    échec         : \(.status.failureReason)" else empty end),
      (if (.status.validationErrors // []) | length > 0
       then "    validation    : \(.status.validationErrors | join("; "))" else empty end),
      "    fs-backup     : \(.spec.defaultVolumesToFsBackup // false)   snapshots : \(.spec.snapshotVolumes // false)"
  ' <<<"$bk"

  echo "    namespaces    :"
  # `includedNamespaces` omis vaut TOUT LE CLUSTER : l'écrire en toutes lettres, pas juste « * ».
  jq -r '
    (.spec.includedNamespaces // ["*"])
    | if . == ["*"] then "      * (TOUT LE CLUSTER — includedNamespaces absent ou « * »)"
      else .[] | "      - \(.)" end' <<<"$bk"
  jq -r '
    (.spec.excludedNamespaces // []) | if length > 0
    then "    exclus        : \(join(", "))" else empty end' <<<"$bk"

  echo
  if [[ "$(jq '.items | length' <<<"$pvb")" == "0" ]]; then
    log "Volumes copiés : aucun"
    if [[ "$(jq -r '.status.phase' <<<"$bk")" == "Completed" ]]; then
      warn "Sauvegarde Completed sans AUCUN volume : objets sauvegardés, données absentes."
      warn "Vérifier node-agent (label PodSecurity du namespace, taints des nœuds)."
    fi
  else
    log "Volumes copiés"
    {
      printf 'NAMESPACE\tPOD\tVOLUME\tPHASE\tTAILLE\n'
      jq -r '
        .items
        | sort_by(.spec.pod.namespace, .spec.pod.name, .spec.volume)
        | .[]
        | [ (.spec.pod.namespace // "-"),
            (.spec.pod.name // "-"),
            (.spec.volume // "-"),
            (.status.phase // "-"),
            "\(((.status.progress.totalBytes // 0)/1048576*10|floor)/10) Mio" ]
        | @tsv' <<<"$pvb"
    } | column -t -s $'\t'
    volumes_summary <<<"$pvb"
  fi
}

# --- backup -----------------------------------------------------------------------------------

cmd_backup() {
  local schedule="${1:-$DEFAULT_SCHEDULE}" bsl manifest backup pvb

  kubectl -n "$NAMESPACE" get schedules.velero.io "$schedule" >/dev/null 2>&1 \
    || die "Schedule '$schedule' absente du namespace '$NAMESPACE'. Schedules connues :
$(kubectl -n "$NAMESPACE" get schedules.velero.io -o name 2>/dev/null || echo '  (aucune)')"

  # Une schedule en pause reste copiable : on prévient sans bloquer, la pause ne concerne que le
  # déclenchement automatique.
  if [[ "$(kubectl -n "$NAMESPACE" get schedules.velero.io "$schedule" -o jsonpath='{.spec.paused}')" == "true" ]]; then
    warn "La schedule '$schedule' est en PAUSE. Son périmètre reste valide, la sauvegarde manuelle part quand même."
  fi

  bsl="$(kubectl -n "$NAMESPACE" get schedules.velero.io "$schedule" -o jsonpath='{.spec.template.storageLocation}')"
  require_bsl "${bsl:-default}"

  # Aucun node-agent = les objets seront sauvegardés, les DONNÉES non, et la sauvegarde sera verte.
  local ready
  ready="$(kubectl -n "$NAMESPACE" get daemonset node-agent -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -gt 0 ]] \
    || warn "Aucun pod node-agent prêt : les données des PV ne seront PAS copiées (la sauvegarde passera quand même au vert)."

  # `.spec.template` de la Schedule = la spec du Backup, à l'identique. Le label
  # `velero.io/schedule-name` est délibérément OMIS (la CLI, elle, le pose avec `--from-schedule`) :
  # il ferait compter cette sauvegarde comme une exécution de la schedule dans les métriques, ce qui
  # éteindrait l'alerte VeleroBackupTooOld alors que la schedule n'aurait pas tourné.
  manifest="$(kubectl -n "$NAMESPACE" get schedules.velero.io "$schedule" -o json | jq \
    --arg ns "$NAMESPACE" \
    --arg sched "$schedule" '{
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
    jq . <<<"$manifest"
    exit 0
  fi

  log "Périmètre repris de la schedule '$schedule' : $(jq -c '.spec.includedNamespaces // ["*"]' <<<"$manifest")"

  backup="$(kubectl create -f - -o jsonpath='{.metadata.name}' <<<"$manifest")"
  log "Sauvegarde créée : $backup"

  if [[ -n "${NO_WAIT:-}" ]]; then
    log "NO_WAIT : suivi laissé à l'appelant."
    echo "  kubectl -n $NAMESPACE get backups.velero.io $backup -o yaml"
    exit 0
  fi

  log "Suivi (Ctrl-C interrompt l'affichage, PAS la sauvegarde)…"
  wait_phase backups.velero.io "$backup" itemsBackedUp 'Completed|PartiallyFailed|Failed|FailedValidation'

  pvb="$(volumes_json podvolumebackups velero.io/backup-name "$backup")"
  volumes_summary <<<"$pvb"

  case "$PHASE" in
    Completed)
      if [[ "$(jq '.items | length' <<<"$pvb")" == "0" ]]; then
        warn "Sauvegarde Completed mais AUCUN volume copié : objets sauvegardés, données absentes."
        warn "Vérifier node-agent (label PodSecurity du namespace, taints des nœuds)."
      fi
      log "Terminée : $backup"
      ;;
    PartiallyFailed)
      warn "PartiallyFailed : restaurable mais incomplète. Détail :"
      echo "  kubectl -n $NAMESPACE get backups.velero.io $backup -o jsonpath='{.status.failureReason}{\"\\n\"}'"
      exit 2
      ;;
    *)
      die "État final '$PHASE'. Logs du serveur : kubectl -n $NAMESPACE logs deploy/velero"
      ;;
  esac
}

# --- restore ----------------------------------------------------------------------------------

cmd_restore() {
  local backup="" wanted="" policy="none"

  while (( $# )); do
    case "$1" in
      -n|--namespace) wanted="${2:-}"; [[ -n "$wanted" ]] || usage; shift 2 ;;
      --overwrite)    policy="update"; shift ;;
      -h|--help)      usage 0 ;;
      -*)             die "Option inconnue : $1" ;;
      *)              [[ -z "$backup" ]] || die "Une seule sauvegarde à la fois (reçu « $backup » puis « $1 »)."
                      backup="$1"; shift ;;
    esac
  done
  [[ -n "$backup" ]] || usage

  local bk phase scope_json
  bk="$(kubectl -n "$NAMESPACE" get backups.velero.io "$backup" -o json 2>/dev/null)" \
    || die "Sauvegarde '$backup' introuvable dans '$NAMESPACE'. Lister : velero-script.sh list"

  # Restaurer depuis une sauvegarde en cours lirait un dépôt kopia incomplet ; depuis une
  # sauvegarde en échec, il n'y a rien à lire.
  phase="$(jq -r '.status.phase // "inconnue"' <<<"$bk")"
  case "$phase" in
    Completed) ;;
    PartiallyFailed) warn "Sauvegarde PartiallyFailed : restauration possible mais INCOMPLÈTE par construction." ;;
    *) die "Sauvegarde '$backup' en phase '$phase' — seules Completed et PartiallyFailed sont restaurables." ;;
  esac

  require_bsl "$(jq -r '(.spec.storageLocation // "") | if . == "" then "default" else . end' <<<"$bk")"

  # --- Périmètre. Dérivé du Backup, jamais retapé : un `includedNamespaces` omis vaut TOUT LE
  # CLUSTER, et restaurer tout le cluster ne peut pas être un défaut implicite.
  local backup_ns
  backup_ns="$(jq -c '.spec.includedNamespaces // ["*"]' <<<"$bk")"

  if [[ "$backup_ns" == '["*"]' && -z "$wanted" ]]; then
    die "La sauvegarde '$backup' couvre TOUT LE CLUSTER (includedNamespaces absent ou « * »).
       Restaurer l'intégralité d'un cluster ne se fait pas par défaut : préciser le périmètre.
         velero-script.sh restore $backup -n <ns>[,<ns>]"
  fi

  if [[ -n "$wanted" ]]; then
    # Un namespace absent du backup produirait un Restore vide et VERT — le refuser vaut mieux.
    scope_json="$(jq -c --arg w "$wanted" --argjson all "$backup_ns" '
      ($w | split(",") | map(select(length > 0))) as $req
      | if $all == ["*"] then $req
        else ($req - $all) as $hors
             | if ($hors | length) > 0 then error("hors périmètre : \($hors | join(", "))") else $req end
        end' <<<'{}' 2>&1)" \
      || die "Namespace(s) demandé(s) absent(s) de la sauvegarde '$backup'.
       Périmètre de la sauvegarde : $backup_ns"
  else
    scope_json="$backup_ns"
  fi

  # --- ArgoCD. Les objets déclarés dans Git y sont reposés par `selfHeal` ; ce que velero apporte
  # d'utile, ce sont les DONNÉES (PV/PVC). On avertit, on ne mute rien : un Ctrl-C au mauvais
  # moment laisserait une Application avec l'auto-sync coupé, sans que ça se voie.
  local apps
  apps="$(kubectl -n argocd get applications -o json 2>/dev/null || echo '{"items":[]}')"
  apps="$(jq -r --argjson scope "$scope_json" '
    [ .items[]
      | select((.spec.destination.namespace // "") as $n | $scope | index($n))
      | .metadata.name ] | join(" ")' <<<"$apps")"
  if [[ -n "$apps" ]]; then
    warn "Applications ArgoCD sur ce périmètre : $apps"
    warn "    « selfHeal » va reposer ce qui est déclaré dans Git, en concurrence de la restauration."
    warn "    Pour suspendre l'auto-sync le temps du restore (et le rétablir ensuite) :"
    local app
    for app in $apps; do
      warn "      kubectl -n argocd patch application $app --type=merge -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}'"
    done
  fi

  # --- Récapitulatif et confirmation
  local pvb_count
  pvb_count="$(volumes_json podvolumebackups velero.io/backup-name "$backup" | jq '.items | length')"

  local manifest
  manifest="$(jq -n \
    --arg ns "$NAMESPACE" \
    --arg backup "$backup" \
    --arg policy "$policy" \
    --argjson scope "$scope_json" '{
      apiVersion: "velero.io/v1",
      kind: "Restore",
      metadata: {
        generateName: "restore-",
        namespace: $ns,
        annotations: { "homelab.wittner.tech/derived-from-backup": $backup }
      },
      spec: {
        backupName: $backup,
        includedNamespaces: $scope,
        existingResourcePolicy: $policy
      }
    }')"

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : manifeste qui serait créé (rien n'est envoyé au cluster)"
    jq . <<<"$manifest"
    exit 0
  fi

  log "Restauration à partir de « $backup »"
  printf '    sauvegarde  : %s (%s, créée %s)\n' "$backup" "$phase" \
    "$(jq -r '.metadata.creationTimestamp' <<<"$bk")"
  printf '    namespaces  : %s\n' "$(jq -r 'join(", ")' <<<"$scope_json")"
  printf '    volumes     : %s disponibles dans la sauvegarde\n' "$pvb_count"
  printf '    politique   : existingResourcePolicy=%s%s\n' "$policy" \
    "$( [[ "$policy" == update ]] && echo '  ← ÉCRASE les objets déjà en place' || echo '' )"
  confirm "$backup"

  local restore
  restore="$(kubectl create -f - -o jsonpath='{.metadata.name}' <<<"$manifest")"
  log "Restauration créée : $restore"

  if [[ -n "${NO_WAIT:-}" ]]; then
    log "NO_WAIT : suivi laissé à l'appelant."
    echo "  kubectl -n $NAMESPACE get restores.velero.io $restore -o yaml"
    exit 0
  fi

  log "Suivi (Ctrl-C interrompt l'affichage, PAS la restauration)…"
  wait_phase restores.velero.io "$restore" itemsRestored \
    'Completed|PartiallyFailed|Failed|FailedValidation'

  local pvr
  pvr="$(volumes_json podvolumerestores velero.io/restore-name "$restore")"
  volumes_summary <<<"$pvr"

  case "$PHASE" in
    Completed)
      # Symétrique du contrôle « verte et vide » du backup : une restauration qui ne repose aucun
      # volume alors que la sauvegarde en contenait n'a restauré que des objets.
      if [[ "$pvb_count" -gt 0 && "$(jq '.items | length' <<<"$pvr")" == "0" ]]; then
        warn "Restauration Completed mais AUCUN volume repris, alors que la sauvegarde en contient $pvb_count."
        warn "Objets restaurés, données absentes — vérifier node-agent et les PVC cibles."
      fi
      log "Terminée : $restore"
      ;;
    PartiallyFailed)
      warn "PartiallyFailed : restauration incomplète. Détail :"
      echo "  kubectl -n $NAMESPACE get restores.velero.io $restore -o yaml"
      exit 2
      ;;
    *)
      die "État final '$PHASE'. Logs du serveur : kubectl -n $NAMESPACE logs deploy/velero"
      ;;
  esac
}

# --- delete -----------------------------------------------------------------------------------

cmd_delete() {
  local backup="${1:-}"
  [[ -n "$backup" ]] || usage

  local bk phase
  bk="$(kubectl -n "$NAMESPACE" get backups.velero.io "$backup" -o json 2>/dev/null)" \
    || die "Sauvegarde '$backup' introuvable dans '$NAMESPACE'. Lister : velero-script.sh list"

  phase="$(jq -r '.status.phase // "inconnue"' <<<"$bk")"
  # Supprimer une sauvegarde en cours laisse des données orphelines dans le dépôt kopia, que seule
  # la maintenance horaire finira par récupérer.
  [[ "$phase" != "InProgress" ]] \
    || die "Sauvegarde '$backup' en cours (InProgress) : attendre sa fin avant de la supprimer."

  require_bsl "$(jq -r '(.spec.storageLocation // "") | if . == "" then "default" else . end' <<<"$bk")"

  # `kubectl delete backups.velero.io` NE SUPPRIME RIEN durablement : les données restent dans le
  # bucket et le contrôleur `backup-sync` recrée l'objet à la synchro suivante (~1 min). Le seul
  # chemin qui efface aussi le contenu est une DeleteBackupRequest — ce que fabrique la CLI velero.
  local manifest
  manifest="$(jq -n --arg ns "$NAMESPACE" --arg backup "$backup" '{
    apiVersion: "velero.io/v1",
    kind: "DeleteBackupRequest",
    metadata: { generateName: "suppression-", namespace: $ns },
    spec: { backupName: $backup }
  }')"

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : manifeste qui serait créé (rien n'est envoyé au cluster)"
    jq . <<<"$manifest"
    exit 0
  fi

  log "Suppression DÉFINITIVE de « $backup » — objet ET données dans le bucket."
  printf '    phase       : %s\n' "$phase"
  printf '    namespaces  : %s\n' "$(jq -r '(.spec.includedNamespaces // ["*"]) | join(", ")' <<<"$bk")"
  printf '    volumes     : %s\n' \
    "$(volumes_json podvolumebackups velero.io/backup-name "$backup" | jq '.items | length')"
  confirm "$backup"

  local req
  req="$(kubectl create -f - -o jsonpath='{.metadata.name}' <<<"$manifest")"
  log "DeleteBackupRequest créée : $req"

  if [[ -n "${NO_WAIT:-}" ]]; then
    log "NO_WAIT : suivi laissé à l'appelant."
    echo "  kubectl -n $NAMESPACE get deletebackuprequests $req -o yaml"
    exit 0
  fi

  wait_phase deletebackuprequests "$req" "" 'Processed'

  local errors
  # La requête peut déjà avoir été recyclée par le contrôleur : son absence n'est pas une erreur.
  errors="$(kubectl -n "$NAMESPACE" get deletebackuprequests "$req" -o json 2>/dev/null \
    | jq -r '.status.errors // [] | join("\n")' 2>/dev/null || true)"
  if [[ -n "$errors" ]]; then
    warn "Suppression traitée AVEC erreurs :"
    printf '%s\n' "$errors" >&2
    exit 2
  fi

  # Le contrôleur supprime l'objet Backup lui-même après avoir vidé le bucket ; s'il est encore là,
  # c'est que la suppression n'est pas allée au bout.
  if kubectl -n "$NAMESPACE" get backups.velero.io "$backup" >/dev/null 2>&1; then
    warn "L'objet Backup '$backup' existe encore — vérifier dans une minute (backup-sync recrée ce
     qui reste dans le bucket) : kubectl -n $NAMESPACE get backups.velero.io"
  else
    log "Supprimée : $backup"
  fi
}

# --- Aiguillage -------------------------------------------------------------------------------

require_bins kubectl jq

case "${1:-}" in
  list)    shift; cmd_list "$@" ;;
  show)    shift; cmd_show "$@" ;;
  backup)  shift; cmd_backup "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  delete)  shift; cmd_delete "$@" ;;
  -h|--help|help) usage 0 ;;
  '')             usage 1 ;;
  *)       die "Commande inconnue : « $1 ». Voir : $(basename "$0") --help" ;;
esac
