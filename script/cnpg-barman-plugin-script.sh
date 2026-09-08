#!/usr/bin/env bash
#
# Gestion des sauvegardes CNPG barman-cloud : lister, sauvegarder, restaurer, supprimer.
#
# POURQUOI CE SCRIPT EXISTE. Six pièges du composant. Les trois premiers font LIRE un état faux,
# les trois suivants font PERDRE une sauvegarde — dont un qui détruit la sauvegarde source.
#
#   1. `cluster.status.firstRecoverabilityPoint` et `cluster.status.lastSuccessfulBackup` valent
#      `null` AVEC LE PLUGIN. Ce sont des champs de l'ancien support in-tree
#      (`spec.backup.barmanObjectStore`), que plus rien ne renseigne depuis CloudNativePG 1.26.
#      Vérifié le 2026-09-08 sur `forgejo-db` : deux `Backup` en phase `completed`, et les deux
#      champs à `null`. La fenêtre de récupération RÉELLE vit ailleurs, sur l'ObjectStore :
#      `.status.serverRecoveryWindow["<serverName>"]`. C'est elle que le script affiche partout.
#   2. Les phases CNPG sont en MINUSCULES (`completed`, `failed`, `running`, `walArchivingFailing`)
#      là où velero les écrit en Capitales. Un `case` sur `Completed` ne matche jamais : la boucle
#      de suivi tourne jusqu'au TIMEOUT sur une sauvegarde terminée depuis longtemps.
#   3. Le nom court `backups` est AMBIGU entre `backups.postgresql.cnpg.io` et `backups.velero.io`.
#      kubectl tranche aujourd'hui en faveur de CNPG — l'inverse exact du piège de
#      `velero-script.sh` — mais cet arbitrage ne dépend que de l'ordre de découverte des groupes
#      d'API et n'est garanti par rien. Le nom long est écrit partout.
#   4. Supprimer un objet `Backup` NE SUPPRIME PAS les données du bucket. Là encore l'inverse de
#      velero, où seule une `DeleteBackupRequest` efface le contenu : ici les données ne relèvent
#      QUE de la `retentionPolicy` de l'ObjectStore. Supprimer l'objet ne perd que le catalogue
#      côté Kubernetes — la sauvegarde reste dans le bucket et reste restaurable par son backupId.
#
#      ⚠️ Et ce n'est PAS une limite de ce script : le plugin n'expose AUCUNE API de suppression
#      distante. Vérifié le 2026-09-08 sur v0.15.0 — les `Backup` ne portent aucun finalizer,
#      `ObjectStore.spec` n'a que trois champs (`configuration`, `instanceSidecarConfiguration`,
#      `retentionPolicy`), et le groupe `barmancloud.cnpg.io` ne contient qu'une seule CRD. Il n'y
#      a rien à appeler. La rétention est le seul GC, et c'est délibéré côté amont : supprimer une
#      sauvegarde de base hors ordre casserait la fenêtre PITR de TOUTES celles qui la suivent,
#      les WAL nécessaires partant de la plus ancienne base encore vivante.
#   5. `spec.plugins` sans `isWALArchiver: true` charge le plugin sans réécrire `archive_command` :
#      les sauvegardes de base partent, aucun WAL ne les complète, elles sont VERTES et le PITR
#      est inexistant. Contrôlé avant chaque sauvegarde manuelle.
#   6. ⚠️ Un cluster restauré qui archive sous le `serverName` de sa SOURCE écrase les WAL de
#      celle-ci — la restauration détruit la sauvegarde dont elle vient. `serverName` vaut le nom
#      du `Cluster` quand il est omis, donc un manifeste de recovery recopié sans y penser tombe
#      dans le piège dès que le cluster restauré est renommé pour prendre la place de l'original.
#      La sous-commande `restore` pose toujours un `serverName` explicite des DEUX côtés.
#
# CE N'EST PAS UNE VIOLATION DE LA RÈGLE GITOPS — ET `restore` NE CRÉE RIEN. Un `Backup` est un
# ÉVÉNEMENT, comme un `Backup` velero : committé, ArgoCD le rejouerait sans fin. Sa place est une
# commande. Une RESTAURATION CNPG, elle, n'est pas un événement : c'est un `Cluster` neuf en
# `bootstrap.recovery`, donc un ÉTAT DÉSIRÉ, donc un manifeste à committer. `restore` l'imprime et
# n'envoie rien au cluster — c'est délibéré, pas une limitation.
#
# Usage, depuis n'importe où :
#   script/cnpg-barman-plugin-script.sh list [motif]
#   script/cnpg-barman-plugin-script.sh show <backup> [-n ns]
#   script/cnpg-barman-plugin-script.sh backup [cluster] [-n ns]
#   script/cnpg-barman-plugin-script.sh restore <cluster> [-n ns] [--name X] [--immediate |
#                                       --target-time T | --backup-id ID] [--no-archive]
#   script/cnpg-barman-plugin-script.sh delete <backup> [-n ns]
#
# Variables d'environnement :
#   CNPG_NAMESPACE     restreint à un namespace (défaut : tous — les ObjectStore et les Backup
#                      sont namespacés et vivent auprès de l'application qui possède la base)
#   CNPG_SYSTEM_NAMESPACE  namespace de l'opérateur et du plugin (défaut `cnpg-system`)
#   TIMEOUT            plafond d'attente en secondes (défaut 1800)
#   DRY_RUN=1          affiche le manifeste qui serait créé, n'envoie rien au cluster
#   NO_WAIT=1          crée l'objet et rend la main sans suivre son déroulement
#   YES=1              passe les confirmations interactives (delete)
#
# Codes de sortie : 0 = succès, 1 = échec ou pré-requis manquant, 2 = terminé avec réserve
#                   (`walArchivingFailing`), 3 = délai d'attente dépassé (l'opération, elle,
#                   continue côté cluster).

set -euo pipefail

NAMESPACE="${CNPG_NAMESPACE:-}"
SYSTEM_NS="${CNPG_SYSTEM_NAMESPACE:-cnpg-system}"
TIMEOUT="${TIMEOUT:-1800}"
PLUGIN_NAME="barman-cloud.cloudnative-pg.io"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  local code="${1:-1}"
  cat >&2 <<'USAGE'
Gestion des sauvegardes CNPG barman-cloud (le nom est explicite : ce n'est PAS la CLI `cnpg`,
ni `barman-cloud-*` — tout passe par kubectl et jq).

  cnpg-barman-plugin-script.sh list [motif]
      Bases sous sauvegarde, sauvegardes, schedules. La fenêtre de récupération est lue sur
      l'ObjectStore, PAS sur le Cluster (dont les champs de sauvegarde valent null avec le plugin).
      Chaque sauvegarde porte deux plages : PLAGE-UTC = début → fin de la copie ; PITR-UTC =
      ce qui est restaurable DEPUIS elle (fin de la copie → dernier point garanti par l'ObjectStore).

  cnpg-barman-plugin-script.sh show <backup> [-n ns]
      Détail d'une sauvegarde : LSN et WAL de début/fin, durée, erreur, fenêtre de l'ObjectStore.

  cnpg-barman-plugin-script.sh backup [cluster] [-n ns]
      Sauvegarde de base manuelle, à la spec EXACTE de la ScheduledBackup du cluster.
      Sans argument : le seul cluster sous sauvegarde du périmètre, s'il n'y en a qu'un.

  cnpg-barman-plugin-script.sh restore <cluster> [-n ns] [options]
      IMPRIME le manifeste du Cluster de recovery — n'envoie RIEN au cluster : une restauration
      CNPG est un état désiré, donc du Git. Spec dérivée du Cluster source, jamais retapée.
          --name X          nom du cluster restauré (défaut : <cluster>-restore)
          --immediate       s'arrêter dès la cohérence atteinte (pas de rejeu de WAL)
          --target-time T   PITR à une date (RFC3339, dans la fenêtre de récupération)
          --backup-id ID    REPARTIR d'une sauvegarde de base précise (cf. `show`). ⚠️ Seul, il
                            rejoue ensuite tout le WAL et atterrit au même endroit que sans
                            option. Pour l'état À cette sauvegarde : `--backup-id ID --immediate`
          --no-archive      clone jetable : pas de spec.plugins, donc aucun archivage WAL

  cnpg-barman-plugin-script.sh delete <backup> [-n ns]
      Supprime l'OBJET Backup. ⚠️ Les données RESTENT dans le bucket (contrairement à velero) :
      leur seul GC est la `retentionPolicy` de l'ObjectStore.

Variables : CNPG_NAMESPACE (tous) · CNPG_SYSTEM_NAMESPACE (cnpg-system) · TIMEOUT (1800) ·
            DRY_RUN=1 · NO_WAIT=1 · YES=1
Codes de sortie : 0 succès · 1 erreur · 2 terminé avec réserve · 3 délai dépassé
USAGE
  exit "$code"
}

# --- Socle commun -----------------------------------------------------------------------------

require_bins() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null || die "$bin est introuvable dans le PATH."
  done
}

# `kubectl get` sur le périmètre courant : un namespace précis, ou tout le cluster. Le défaut est
# « tous » et non un namespace fixe — contrairement à velero, dont tout tient dans `velero`, ici
# chaque base a son ObjectStore et ses Backup dans le namespace de SON application.
kget() {
  if [[ -n "$NAMESPACE" ]]; then
    kubectl -n "$NAMESPACE" get "$@" -o json 2>/dev/null || echo '{"items":[]}'
  else
    kubectl get "$@" -A -o json 2>/dev/null || echo '{"items":[]}'
  fi
}

# Retrouve le namespace d'un objet nommé quand `-n` n'a pas été donné. Une homonymie entre
# namespaces est refusée plutôt qu'arbitrée : agir sur la mauvaise base est le seul échec qui ne
# se voit pas.
resolve_ns() {
  local kind="$1" name="$2" hits
  if [[ -n "$NAMESPACE" ]]; then printf '%s' "$NAMESPACE"; return 0; fi
  hits="$(kubectl get "$kind" -A -o json 2>/dev/null \
    | jq -r --arg n "$name" '[.items[] | select(.metadata.name == $n) | .metadata.namespace] | .[]')"
  case "$(wc -w <<<"$hits" | tr -d ' ')" in
    0) die "$kind « $name » introuvable dans le cluster. Lister : cnpg-barman-plugin-script.sh list" ;;
    1) printf '%s' "$hits" ;;
    *) die "$kind « $name » existe dans plusieurs namespaces ($(tr '\n' ' ' <<<"$hits")).
       Préciser lequel : -n <namespace>" ;;
  esac
}

# Le plugin absent ou non prêt ne casse pas la CRD : l'objet Backup est accepté, reste en `pending`
# et n'ira jamais nulle part. Autant le dire avant.
require_plugin() {
  local ready
  ready="$(kubectl -n "$SYSTEM_NS" get deploy plugin-barman-cloud \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -gt 0 ]] || die "Aucun réplica disponible du Deployment 'plugin-barman-cloud'
       dans '$SYSTEM_NS'. Sans lui, un Backup reste en 'pending' indéfiniment.
       Diagnostic : kubectl -n $SYSTEM_NS get deploy,certificate
       Des Certificate à False = cert-manager absent : le plugin démarre et reste injoignable."
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
  [[ "$answer" == "$expected" ]] || die "Annulé — rien n'a été fait."
}

fmt_duration() {
  local s="$1"
  if (( s >= 3600 )); then
    printf '%d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
  else
    printf '%02d:%02d' $(( s / 60 )) $(( s % 60 ))
  fi
}

# Suit un Backup jusqu'à une phase terminale. Renseigne la globale PHASE pour l'appelant.
#   $1 namespace   $2 nom   $3 phases terminales, séparées par « | »
PHASE=""
wait_phase() {
  local ns="$1" name="$2" terminal="$3"
  local deadline=$(( SECONDS + TIMEOUT )) start=$SECONDS line last="" obj missing=0
  PHASE=""
  while :; do
    if obj="$(kubectl -n "$ns" get backups.postgresql.cnpg.io "$name" -o json 2>/dev/null)"; then
      missing=0
      PHASE="$(jq -r '.status.phase // ""' <<<"$obj")"
    else
      # Une ScheduledBackup en `backupOwnerReference: self` emporte ses Backup si elle est
      # supprimée sous nos pieds. Deux lectures manquées d'affilée : fin de partie, sans quoi la
      # boucle tournerait jusqu'au TIMEOUT sur un objet qui n'existe plus.
      missing=$(( missing + 1 ))
      if (( missing >= 2 )); then
        [[ -t 1 ]] && printf '\n' || true
        warn "backups.postgresql.cnpg.io/$name a disparu pendant le suivi."
        PHASE="${PHASE:-Disparu}"
        return 0
      fi
    fi
    line="$(printf '    phase=%-20s' "${PHASE:-…}")"

    if [[ -t 1 ]]; then
      # Terminal : une seule ligne réécrite en place, avec le chronomètre — une sauvegarde
      # manuelle sert justement à MESURER (comparer à la nuit précédente, dimensionner TIMEOUT).
      # Le CNPG n'expose aucun compteur de progression, la durée est la seule mesure disponible.
      printf '\r%s  écoulé=%s   ' "$line" "$(fmt_duration $(( SECONDS - start )))"
    elif [[ "$line" != "$last" ]]; then
      # Redirigé (cron, CI, `| tee`) : le retour chariot empilerait des lignes illisibles — on
      # n'écrit qu'aux CHANGEMENTS d'état, et sans le chronomètre qui change à chaque tour.
      printf '%s\n' "$line"
      last="$line"
    fi

    # PAS de `case "$PHASE" in $terminal)` : l'alternation « | » d'un motif `case` est résolue à
    # l'analyse du source, jamais à l'expansion. Venu d'une variable, le « | » est un caractère
    # LITTÉRAL. Les « | » encadrants évitent qu'un préfixe partiel passe.
    if [[ "|$terminal|" == *"|$PHASE|"* ]]; then
      break
    fi
    if (( SECONDS >= deadline )); then
      [[ -t 1 ]] && printf '\n' || true
      warn "Délai de ${TIMEOUT}s dépassé — la sauvegarde continue côté cluster."
      exit 3
    fi
    sleep 5
  done
  [[ -t 1 ]] && printf '\n' || true
}

# Formatage relatif d'un timestamp RFC3339 et durée lisible, partagés par tous les tableaux.
JQ_LIB='
  # CNPG écrit ses timestamps tantôt en secondes entières, tantôt avec des fractions
  # (`.status.stoppedAt` en porte). `fromdateiso8601` refuse les secondes fractionnaires : la
  # troncature est faite ici, une fois, plutôt que dans chaque appelant.
  def epoch($t):
    if $t == null or $t == "" then null
    else ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;

  def rel($t):
    if epoch($t) == null then "-"
    else
      (epoch($t) - now) as $d
      | (if $d < 0 then -$d else $d end) as $a
      | (if   $a < 3600  then "\(($a/60)    | floor) min"
         elif $a < 86400 then "\(($a/3600)  | floor) h"
         else                 "\(($a/86400) | floor) j" end) as $u
      | if $d < 0 then "il y a \($u)" else "dans \($u)" end
    end;

  def span($a; $b):
    if epoch($a) == null or epoch($b) == null then "-"
    else
      (epoch($b) - epoch($a)) as $s
      | if   $s < 60   then "\($s)s"
        elif $s < 3600 then "\(($s/60)   | floor)m\($s % 60)s"
        else                "\(($s/3600) | floor)h\((($s % 3600)/60) | floor)m" end
    end;

  # Horodatage absolu, en UTC — comme tout ce que sert l’API et comme ce qu’affiche `show`.
  # Surtout PAS converti en heure locale : non étiquetée, elle se comparerait de travers aux
  # timestamps bruts lus juste à côté (`kubectl get -o yaml`, `show`, les logs du sidecar).
  # `gmtime` explicite plutôt que `strftime` sur un nombre : le second n’accepte un entier que
  # depuis jq 1.6.
  def clock($t):
    if epoch($t) == null then "-" else (epoch($t) | gmtime | strftime("%m-%d %H:%M")) end;

  # Plage d’exécution d’une copie. La date n’est répétée sur la borne haute que si elle change —
  # une sauvegarde de nuit qui déborde sur le lendemain doit se voir, les autres n’ont pas à
  # payer la largeur de colonne.
  def plage($a; $b):
    if   epoch($a) == null then "-"
    elif epoch($b) == null then "\(clock($a)) → …"
    elif (epoch($a) | gmtime | strftime("%m-%d")) == (epoch($b) | gmtime | strftime("%m-%d"))
      then "\(clock($a)) → \(epoch($b) | gmtime | strftime("%H:%M"))"
    else "\(clock($a)) → \(clock($b))" end;

  # Entrée barman du `spec.plugins`, ou null. Toute la sauvegarde tient dans cette entrée :
  # sans elle la base reste hors périmètre, quels que soient les ObjectStore et les
  # ScheduledBackup posés à côté.
  def barman($c):
    [ $c.spec.plugins[]? | select(.name == "barman-cloud.cloudnative-pg.io") ] | first;

  # `serverName` vaut le nom du Cluster quand il est omis. Cette valeur sert deux fois : comme
  # préfixe de rangement dans le bucket, et comme clé de `.status.serverRecoveryWindow` côté
  # ObjectStore.
  def server($c):
    (barman($c).parameters.serverName // $c.metadata.name);
'

# --- list -------------------------------------------------------------------------------------

cmd_list() {
  local pattern="${1:-}"
  local cl os bk sb

  cl="$(kget clusters.postgresql.cnpg.io)"
  os="$(kget objectstores.barmancloud.cnpg.io)"
  bk="$(kget backups.postgresql.cnpg.io)"
  sb="$(kget scheduledbackups.postgresql.cnpg.io)"

  log "Bases PostgreSQL${pattern:+ (motif « $pattern »)}"
  if [[ "$(jq --arg pat "$pattern" '[ .items[] | select("\(.metadata.namespace)/\(.metadata.name)" | contains($pat)) ] | length' <<<"$cl")" == "0" ]]; then
    echo "    (aucune)"
  else
  {
    printf 'NS\tCLUSTER\tINSTANCES\tPLUGIN\tWAL-ARCHIVER\tARCHIVAGE\tOBJECTSTORE\tDERNIER-BACKUP\tDEBUT-FENETRE\n'
    jq -r --argjson os "$os" --arg pat "$pattern" "$JQ_LIB"'
      ( [ $os.items[] | { key: "\(.metadata.namespace)/\(.metadata.name)", value: . } ] | from_entries ) as $stores
      | [ .items[] | select("\(.metadata.namespace)/\(.metadata.name)" | contains($pat)) ]
      | sort_by(.metadata.namespace, .metadata.name)
      | .[]
      | . as $c
      | barman($c) as $p
      | ( $p.parameters.barmanObjectName // "" ) as $osname
      | ( $stores["\($c.metadata.namespace)/\($osname)"] ) as $store
      | ( $store.status.serverRecoveryWindow[server($c)] ) as $win
      | ( [ $c.status.conditions[]? | select(.type == "ContinuousArchiving") ] | first ) as $arch
      | [ $c.metadata.namespace,
          $c.metadata.name,
          "\($c.status.readyInstances // 0)/\($c.spec.instances)",
          (if $p then "oui" else "NON" end),
          # Piège n°5 : plugin chargé SANS isWALArchiver = sauvegardes vertes, PITR inexistant.
          (if $p == null then "-" elif ($p.isWALArchiver // false) then "oui" else "NON ⚠" end),
          (if $p == null then "-"
           elif $arch == null then "?"
           elif $arch.status == "True" then "ok"
           else "KO ⚠" end),
          # ObjectStore référencé mais absent : le plugin ne résout aucune destination et
          # archive dans le vide, sans autre signal que la condition ContinuousArchiving.
          (if $p == null then "-" elif $store == null then "\($osname) ABSENT ⚠" else $osname end),
          # ⚠️ Fenêtre lue côté OBJECTSTORE. `cluster.status.lastSuccessfulBackup` vaut null
          # avec le plugin (piège n°1) : afficher ce champ annoncerait « aucune sauvegarde »
          # sur une base sauvegardée toutes les nuits.
          (if $p == null then "-" else rel($win.lastSuccessfulBackupTime) end),
          # `firstRecoverabilityPoint` REPORTÉ TEL QUEL, et surtout pas relabellisé en « plus
          # ancienne sauvegarde » : les deux ne coïncident pas. Observé le 2026-09-08 sur
          # `forgejo-db` — le champ valait déjà 15:02:11 (sauvegarde `7ghnl`) alors que `5gcxx`
          # (14:59:51) existait et était `completed`. Ce champ borne la fenêtre de rejeu, pas
          # le catalogue. Le comptage des sauvegardes se lit sur le tableau du dessous.
          (if $p == null then "-" else rel($win.firstRecoverabilityPoint) end) ]
      | @tsv' <<<"$cl"
  } | column -t -s $'\t'
  fi

  # Notes de pied de tableau, posées seulement si le cas correspondant existe réellement.
  if jq -e "$JQ_LIB"'any(.items[]; barman(.) == null)' <<<"$cl" >/dev/null; then
    warn "PLUGIN=NON : base HORS de toute chaîne de sauvegarde. Ni ObjectStore ni ScheduledBackup"
    warn "    ne suffisent — seul « spec.plugins » sur le Cluster met une base sous archivage."
  fi
  if jq -e "$JQ_LIB"'any(.items[]; barman(.) != null and (barman(.).isWALArchiver // false) == false)' \
       <<<"$cl" >/dev/null; then
    warn "WAL-ARCHIVER=NON : « archive_command » non réécrite. Les sauvegardes de base partiront et"
    warn "    seront VERTES, sans aucun WAL pour les compléter — le PITR est inexistant."
  fi

  echo
  log "Sauvegardes de base"
  if [[ "$(jq --arg pat "$pattern" '[ .items[] | select("\(.metadata.namespace)/\(.metadata.name)/\(.spec.cluster.name)" | contains($pat)) ] | length' <<<"$bk")" == "0" ]]; then
    echo "    (aucune)"
  else
    {
      printf 'NS\tNOM\tCLUSTER\tPHASE\tMETHODE\tCREEE\tPLAGE-UTC\tDUREE\tPITR-UTC\tBACKUP-ID\tSOURCE\tERREUR\n'
      jq -r --arg pat "$pattern" --argjson cl "$cl" --argjson os "$os" "$JQ_LIB"'
        ( [ $cl.items[] | { key: "\(.metadata.namespace)/\(.metadata.name)", value: . } ] | from_entries ) as $clusters
        | ( [ $os.items[] | { key: "\(.metadata.namespace)/\(.metadata.name)", value: . } ] | from_entries ) as $stores
        | [ .items[] | select("\(.metadata.namespace)/\(.metadata.name)/\(.spec.cluster.name)" | contains($pat)) ]
        | sort_by(.metadata.creationTimestamp) | reverse
        | .[]
        | . as $b
        | ( [ $b.metadata.ownerReferences[]? | select(.kind == "ScheduledBackup") ] | first ) as $own
        | ( $b.metadata.annotations["homelab.wittner.tech/derived-from-schedule"] ) as $der
        # Chaîne Backup → Cluster → ObjectStore → fenêtre, refaite ici : la borne haute du PITR
        # ne vit NI sur le Backup NI sur le Cluster (piège n°1), et le `serverName` sous lequel
        # la chercher est LU sur le Cluster, jamais déduit du nom du Backup.
        | ( $clusters["\($b.metadata.namespace)/\($b.spec.cluster.name)"] ) as $c
        | ( $stores["\($b.metadata.namespace)/\(barman($c).parameters.barmanObjectName // "")"] ) as $store
        | ( if $c == null or $store == null then null
            else ($store.status.serverRecoveryWindow[server($c)] // null) end ) as $win
        # Borne basse du PITR = fin de CETTE copie : avant elle, cette base ne peut rien rejouer.
        | ( $b.status.stoppedAt ) as $from
        | [ $b.metadata.namespace,
            $b.metadata.name,
            $b.spec.cluster.name,
            # ⚠️ Phases en MINUSCULES (piège n°2). Reproduites telles quelles, sans normalisation :
            # une capitalisation cosmétique ici induirait en erreur quiconque écrit un `grep`.
            ($b.status.phase // "-"),
            ($b.spec.method // "-"),
            rel($b.metadata.creationTimestamp),
            plage($b.status.startedAt; $b.status.stoppedAt),
            span($b.status.startedAt; $b.status.stoppedAt),
            # Une copie non `completed` n’ouvre aucune plage : `walArchivingFailing` a bien une
            # `stoppedAt`, et afficher une plage à partir d’elle annoncerait restaurable ce qui
            # ne l’est pas (le WAL de fin manque).
            (if   $b.status.phase != "completed" then "-"
             elif $win == null or epoch($from) == null then "-"
             # Le status de l’ObjectStore est rafraîchi par le plugin, pas à la seconde : une copie
             # qui vient de finir est déjà `completed` alors que `lastSuccessfulBackupTime` pointe
             # encore la précédente. Rendre la plage telle quelle afficherait une borne haute
             # ANTÉRIEURE à la borne basse — un intervalle vide, donc « rien de restaurable » sur
             # la sauvegarde la plus fraîche.
             elif (epoch($win.lastSuccessfulBackupTime) == null
                   or epoch($from) > epoch($win.lastSuccessfulBackupTime))
               then "\(clock($from)) → …"
             else "\(clock($from)) → \(clock($win.lastSuccessfulBackupTime))"
                  # Copie antérieure au début de la fenêtre : les WAL qui la prolongeaient sont
                  # partis en rétention, la base seule ne rejoue plus rien.
                  + (if (epoch($win.firstRecoverabilityPoint) != null
                         and epoch($from) < epoch($win.firstRecoverabilityPoint))
                     then " ⚠" else "" end)
             end),
            ($b.status.backupId // "-"),
            (if $own then $own.name elif $der then "manuel (\($der))" else "manuel" end),
            (($b.status.error // "") | if . == "" then "" else (.[0:60]) end) ]
        | @tsv' <<<"$bk"
    } | column -t -s $'\t'
    echo "    PLAGE-UTC = début → fin de la copie. PITR-UTC = plage restaurable DEPUIS cette copie."
    # La borne haute n'est PAS le dernier point rejouable : c'est le dernier point GARANTI par le
    # status de l'ObjectStore. Le rejeu va en réalité jusqu'au dernier WAL archivé, qui est plus
    # récent — le plugin ne l'expose nulle part. D'où « au moins », et non « jusqu'à ».
    echo "    Bornes en UTC (mm-jj hh:mm), comme les timestamps bruts de l'API. La borne haute est"
    echo "    « lastSuccessfulBackupTime » : le dernier point GARANTI. Le rejeu va au moins jusque-là,"
    echo "    et en pratique jusqu'au dernier WAL archivé — que le plugin n'expose nulle part."
    echo "    « ⚠ » : copie antérieure au « firstRecoverabilityPoint » — ses WAL sont partis en rétention."
    echo "    « … » : borne pas encore connue — copie en cours, ou status de l'ObjectStore en retard."
    echo "    Détail d'une sauvegarde (LSN, WAL, fenêtre) : cnpg-barman-plugin-script.sh show <nom>"
  fi

  echo
  log "Schedules"
  if [[ "$(jq --arg pat "$pattern" '[ .items[] | select("\(.metadata.namespace)/\(.metadata.name)/\(.spec.cluster.name)" | contains($pat)) ] | length' <<<"$sb")" == "0" ]]; then
    echo "    (aucune)"
  else
    {
      printf 'NS\tNOM\tCLUSTER\tCRON\tSUSPENDUE\tDERNIERE\tPROCHAINE\tOWNER-REF\n'
      jq -r --arg pat "$pattern" "$JQ_LIB"'
        [ .items[] | select("\(.metadata.namespace)/\(.metadata.name)/\(.spec.cluster.name)" | contains($pat)) ]
        | sort_by(.metadata.namespace, .metadata.name)
        | .[]
        | [ .metadata.namespace,
            .metadata.name,
            .spec.cluster.name,
            # ⚠️ SIX champs : le premier est les SECONDES (robfig/cron de Go, pas crontab).
            .spec.schedule,
            ((.spec.suspend // false) | tostring),
            rel(.status.lastScheduleTime),
            rel(.status.nextScheduleTime),
            (.spec.backupOwnerReference // "none") ]
        | @tsv' <<<"$sb"
    } | column -t -s $'\t'
    if jq -e 'any(.items[]; (.spec.schedule | split(" ") | length) != 6)' <<<"$sb" >/dev/null; then
      warn "Une schedule n'a PAS six champs : le premier est les SECONDES. Écrite à cinq champs,"
      warn "    elle est acceptée par l'API et se décale silencieusement d'un cran."
    fi
  fi
}

# --- show -------------------------------------------------------------------------------------

cmd_show() {
  local backup="" ns=""
  while (( $# )); do
    case "$1" in
      -n|--namespace) NAMESPACE="${2:-}"; [[ -n "$NAMESPACE" ]] || usage; shift 2 ;;
      -h|--help)      usage 0 ;;
      -*)             die "Option inconnue : $1" ;;
      *)              [[ -z "$backup" ]] || die "Une seule sauvegarde à la fois (reçu « $backup » puis « $1 »)."
                      backup="$1"; shift ;;
    esac
  done
  [[ -n "$backup" ]] || usage

  ns="$(resolve_ns backups.postgresql.cnpg.io "$backup")"

  local bk cluster osname store
  bk="$(kubectl -n "$ns" get backups.postgresql.cnpg.io "$backup" -o json 2>/dev/null)" \
    || die "Sauvegarde '$backup' introuvable dans '$ns'."

  log "Sauvegarde $ns/$backup"
  jq -r "$JQ_LIB"'
    ( [ .metadata.ownerReferences[]? | select(.kind == "ScheduledBackup") ] | first ) as $own
    | ( .metadata.annotations["homelab.wittner.tech/derived-from-schedule"] ) as $der
    | "    phase         : \(.status.phase // "-")",
      "    cluster       : \(.spec.cluster.name)",
      "    méthode       : \(.spec.method // "-")   plugin : \(.spec.pluginConfiguration.name // "-")",
      "    source        : \(if $own then $own.name elif $der then "manuel (\($der))" else "manuel" end)",
      "    créée         : \(.metadata.creationTimestamp) (\(rel(.metadata.creationTimestamp)))",
      "    démarrée      : \(.status.startedAt // "-")",
      "    arrêtée       : \(.status.stoppedAt // "-")   durée : \(span(.status.startedAt; .status.stoppedAt))",
      # backupId est LE seul identifiant utilisable pour un PITR ciblé
      # (`--backup-id`) : le nom Kubernetes de cet objet, lui, reste inconnu côté barman.
      "    backupId      : \(.status.backupId // "-")",
      "    backupName    : \(.status.backupName // "-")",
      "    instance      : \(.status.instanceID.podName // "-")   PostgreSQL \(.status.majorVersion // "?")",
      "    timeline      : \(.status.pluginMetadata.timeline // "-")   plugin v\(.status.pluginMetadata.version // "-")",
      "    WAL           : \(.status.beginWal // "-") → \(.status.endWal // "-")",
      "    LSN           : \(.status.beginLSN // "-") → \(.status.endLSN // "-")",
      "    à chaud       : \(.status.online // false)",
      (if (.status.error // "") != "" then "    erreur        : \(.status.error)" else empty end)
  ' <<<"$bk"

  # La fenêtre de récupération ne se lit ni sur le Backup ni sur le Cluster : elle vit sur
  # l'ObjectStore, sous la clé `serverName` (piège n°1).
  local srv
  cluster="$(jq -r '.spec.cluster.name' <<<"$bk")"
  # ⚠️ `serverName` est lu, pas déduit : il vaut le nom du Cluster QUAND IL EST OMIS, mais un
  # cluster restauré en porte un explicite (cf. `restore`). Le déduire ferait chercher la fenêtre
  # de récupération sous la mauvaise clé et afficherait « rien de restaurable » à tort.
  local cl_json
  cl_json="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" -o json 2>/dev/null || echo '{}')"
  osname="$(jq -r --arg p "$PLUGIN_NAME" '
      [ .spec.plugins[]? | select(.name == $p) ] | first | .parameters.barmanObjectName // ""' <<<"$cl_json")"
  srv="$(jq -r --arg p "$PLUGIN_NAME" --arg c "$cluster" '
      ([ .spec.plugins[]? | select(.name == $p) ] | first | .parameters.serverName) // $c' <<<"$cl_json")"

  echo
  if [[ -z "$osname" ]]; then
    warn "Le Cluster '$cluster' ne porte plus de plugin barman : la destination de cette sauvegarde"
    warn "    n'est plus déterminable depuis le cluster, et l'archivage WAL est arrêté."
    return 0
  fi
  store="$(kubectl -n "$ns" get objectstores.barmancloud.cnpg.io "$osname" -o json 2>/dev/null)" \
    || { warn "ObjectStore '$osname' référencé par le Cluster mais ABSENT du namespace '$ns'."; return 0; }

  log "Destination $ns/$osname"
  jq -r --arg srv "$srv" "$JQ_LIB"'
    ( .status.serverRecoveryWindow[$srv] ) as $win
    | "    bucket        : \(.spec.configuration.destinationPath)",
      "    serverName    : \($srv)   (chemin réel : \(.spec.configuration.destinationPath | sub("/$";""))/\($srv)/)",
      "    rétention     : \(.spec.retentionPolicy // "aucune ⚠")",
      "    compression   : base=\(.spec.configuration.data.compression // "-")  wal=\(.spec.configuration.wal.compression // "-")",
      "    fenêtre PITR  : \($win.firstRecoverabilityPoint // "-") → \($win.lastSuccessfulBackupTime // "-")",
      (if $win == null
       then "    ⚠ aucune fenêtre de récupération pour ce serverName — rien de restaurable."
       else empty end)
  ' <<<"$store"
}

# --- backup -----------------------------------------------------------------------------------

# Résout le cluster cible. Sans argument : le seul cluster SOUS SAUVEGARDE du périmètre, s'il n'y
# en a qu'un. Pas de défaut codé en dur — une base ajoutée au périmètre rendrait le défaut faux
# sans que rien ne le signale.
resolve_cluster() {
  local wanted="${1:-}" cl hits
  cl="$(kget clusters.postgresql.cnpg.io)"

  if [[ -n "$wanted" ]]; then
    hits="$(jq -r --arg n "$wanted" '
      .items[] | select(.metadata.name == $n) | "\(.metadata.namespace)\t\(.metadata.name)"' <<<"$cl")"
  else
    hits="$(jq -r "$JQ_LIB"'
      .items[] | select(barman(.) != null) | "\(.metadata.namespace)\t\(.metadata.name)"' <<<"$cl")"
  fi

  case "$(grep -c . <<<"${hits:-}" || true)" in
    0) [[ -n "$wanted" ]] \
         && die "Cluster '$wanted' introuvable. Lister : cnpg-barman-plugin-script.sh list" \
         || die "Aucun Cluster sous sauvegarde dans le périmètre (aucun « spec.plugins » barman).
       Lister : cnpg-barman-plugin-script.sh list" ;;
    1) printf '%s' "$hits" ;;
    *) die "Plusieurs clusters correspondent — préciser lequel :
$(sed 's|^|         |;s|\t|/|' <<<"$hits")" ;;
  esac
}

cmd_backup() {
  local wanted=""
  while (( $# )); do
    case "$1" in
      -n|--namespace) NAMESPACE="${2:-}"; [[ -n "$NAMESPACE" ]] || usage; shift 2 ;;
      -h|--help)      usage 0 ;;
      -*)             die "Option inconnue : $1" ;;
      *)              [[ -z "$wanted" ]] || die "Un seul cluster à la fois (reçu « $wanted » puis « $1 »)."
                      wanted="$1"; shift ;;
    esac
  done

  local target ns cluster
  target="$(resolve_cluster "$wanted")"
  ns="${target%%$'\t'*}"
  cluster="${target##*$'\t'}"

  require_plugin

  local cl p osname
  cl="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" -o json)"
  p="$(jq -c --arg p "$PLUGIN_NAME" '[ .spec.plugins[]? | select(.name == $p) ] | first' <<<"$cl")"

  # Sans `spec.plugins`, le Backup est accepté par la CRD et échoue à l'exécution — mais seulement
  # après avoir été créé, ce qui laisse un objet en `failed` à nettoyer pour rien.
  [[ "$p" != "null" ]] \
    || die "Le Cluster '$ns/$cluster' ne porte PAS le plugin '$PLUGIN_NAME'.
       Ni ObjectStore ni ScheduledBackup ne suffisent : « spec.plugins » est ce qui met une base
       sous sauvegarde. Voir cluster/app/cnpg-barman-plugin/README.md §Opérations."

  # Piège n°5 : sans isWALArchiver, la sauvegarde partira, sera VERTE, et n'aura aucun WAL.
  [[ "$(jq -r '.isWALArchiver // false' <<<"$p")" == "true" ]] \
    || warn "« isWALArchiver » n'est pas à true sur ce Cluster : « archive_command » n'est pas réécrite.
    La sauvegarde va partir et passer au vert, mais AUCUN WAL ne la complète — pas de PITR."

  osname="$(jq -r '.parameters.barmanObjectName // ""' <<<"$p")"
  [[ -n "$osname" ]] \
    || die "Le plugin est câblé sur '$ns/$cluster' sans « parameters.barmanObjectName » : aucune
       destination résolue."
  kubectl -n "$ns" get objectstores.barmancloud.cnpg.io "$osname" >/dev/null 2>&1 \
    || die "ObjectStore '$osname' référencé par le Cluster mais ABSENT de '$ns'.
       Un ObjectStore est NAMESPACÉ et ne se mutualise pas entre applications."

  # `ContinuousArchiving` à False = la chaîne WAL est déjà cassée (credentials, bucket, IAM). Une
  # sauvegarde de base peut réussir malgré ça et donner l'illusion d'une chaîne saine.
  local arch
  arch="$(jq -r '[ .status.conditions[]? | select(.type == "ContinuousArchiving") ] | first | .status // "?"' <<<"$cl")"
  [[ "$arch" == "True" ]] \
    || warn "Condition ContinuousArchiving = '$arch' : l'archivage WAL est en échec AVANT même cette
    sauvegarde. Elle peut réussir et rester inutilisable pour un PITR. Diagnostic :
    kubectl -n $ns logs $cluster-1 -c plugin-barman-cloud"

  # `.spec` de la ScheduledBackup = la spec du Backup, moins ce qui n'a de sens que pour une
  # schedule. Dérivée, jamais retapée : elle ne peut pas diverger de ce qui tourne chaque nuit.
  local sb sbname manifest
  sb="$(kget scheduledbackups.postgresql.cnpg.io \
    | jq -c --arg ns "$ns" --arg c "$cluster" '
        [ .items[] | select(.metadata.namespace == $ns and .spec.cluster.name == $c) ]')"
  case "$(jq 'length' <<<"$sb")" in
    0) die "Aucune ScheduledBackup pour '$ns/$cluster'. La spec d'une sauvegarde manuelle est
       DÉRIVÉE de la schedule, jamais retapée — sans schedule, la chaîne n'est pas montée.
       Voir cluster/app/cnpg-barman-plugin/README.md §Opérations." ;;
    1) ;;
    *) die "Plusieurs ScheduledBackup visent '$ns/$cluster' — la spec à dériver est ambiguë :
$(jq -r '.[] | "         " + .metadata.name' <<<"$sb")" ;;
  esac
  sbname="$(jq -r '.[0].metadata.name' <<<"$sb")"

  if [[ "$(jq -r '.[0].spec.suspend // false' <<<"$sb")" == "true" ]]; then
    warn "La schedule '$sbname' est SUSPENDUE. Sa spec reste valide, la sauvegarde manuelle part quand même."
  fi

  manifest="$(jq -n --argjson sb "$sb" --arg ns "$ns" --arg c "$cluster" --arg s "$sbname" '{
    apiVersion: "postgresql.cnpg.io/v1",
    kind: "Backup",
    metadata: {
      generateName: "\($c)-manual-",
      namespace: $ns,
      annotations: { "homelab.wittner.tech/derived-from-schedule": $s }
    },
    spec: ($sb[0].spec | del(.schedule, .suspend, .immediate, .backupOwnerReference))
  }')"

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : manifeste qui serait créé (rien n'est envoyé au cluster)"
    jq . <<<"$manifest"
    exit 0
  fi

  log "Spec reprise de la schedule '$sbname' → cluster '$ns/$cluster', destination '$osname'"

  local backup started
  backup="$(kubectl create -f - -o jsonpath='{.metadata.name}' <<<"$manifest")"
  log "Sauvegarde créée : $ns/$backup"

  if [[ -n "${NO_WAIT:-}" ]]; then
    log "NO_WAIT : suivi laissé à l'appelant."
    echo "  kubectl -n $ns get backups.postgresql.cnpg.io $backup -o yaml"
    exit 0
  fi

  log "Suivi (Ctrl-C interrompt l'affichage, PAS la sauvegarde)…"
  started=$SECONDS
  # ⚠️ Phases en minuscules (piège n°2). `walArchivingFailing` est TERMINALE et signifie que la
  # copie de base est faite mais que le WAL de fin n'a jamais pu être archivé : la sauvegarde
  # existe et n'est pas restaurable.
  wait_phase "$ns" "$backup" 'completed|failed|walArchivingFailing'

  printf '    durée   : %s\n' "$(fmt_duration $(( SECONDS - started )))"

  case "$PHASE" in
    completed)
      # Contrôle final sur l'ObjectStore, seul endroit où la fenêtre est vraie (piège n°1).
      local win
      win="$(kubectl -n "$ns" get objectstores.barmancloud.cnpg.io "$osname" -o json 2>/dev/null \
        | jq -r --arg s "$cluster" '.status.serverRecoveryWindow[$s].lastSuccessfulBackupTime // ""')"
      printf '    backupId: %s\n' \
        "$(kubectl -n "$ns" get backups.postgresql.cnpg.io "$backup" -o jsonpath='{.status.backupId}')"
      if [[ -n "$win" ]]; then
        printf '    fenêtre : dernier point restaurable %s\n' "$win"
      else
        warn "Sauvegarde 'completed' mais AUCUNE fenêtre de récupération sur l'ObjectStore '$osname'."
        warn "    Le status peut mettre quelques secondes à remonter ; s'il reste vide, vérifier"
        warn "    le serverName : kubectl -n $ns get objectstore $osname -o jsonpath='{.status}'"
      fi
      log "Terminée : $backup"
      ;;
    walArchivingFailing)
      warn "walArchivingFailing : la copie de base est dans le bucket, mais le WAL de fin n'a pas"
      warn "    pu être archivé — la sauvegarde N'EST PAS restaurable en l'état. Diagnostic :"
      echo "  kubectl -n $ns logs $cluster-1 -c plugin-barman-cloud" >&2
      exit 2
      ;;
    *)
      die "État final '$PHASE'. Détail :
       kubectl -n $ns get backups.postgresql.cnpg.io $backup -o jsonpath='{.status.error}{\"\\n\"}'
       kubectl -n $ns logs $cluster-1 -c plugin-barman-cloud"
      ;;
  esac
}

# --- restore ----------------------------------------------------------------------------------

# N'ENVOIE RIEN AU CLUSTER, et ce n'est pas une limitation : une restauration CNPG n'est pas un
# événement mais un `Cluster` neuf en `bootstrap.recovery` — un ÉTAT DÉSIRÉ, donc du Git. Le rôle
# du script est de dériver ce manifeste du Cluster source (jamais le retaper) et de poser les deux
# `serverName` explicites qui empêchent le cluster restauré d'écraser sa propre source.
cmd_restore() {
  local wanted="" newname="" archive=1
  # ⚠️ Les trois cibles se COMPOSENT, elles ne s'excluent pas — et c'est la raison d'être de ces
  # trois variables plutôt qu'un seul `rt_json` réécrit à chaque option. La CRD est explicite :
  # `backupID` est « the ID of the backup from which to START the recovery process », un point de
  # DÉPART ; `targetImmediate` est « end recovery as soon as a consistent state is reached », le
  # point d'ARRÊT. Le défaut, lui, est d'appliquer TOUT le WAL disponible.
  # Conséquence : `--backup-id` SEUL ne rend pas l'état de cette sauvegarde-là. Il repart d'elle et
  # rejoue jusqu'au bout de l'archive — donc il atterrit au même endroit que sans option du tout.
  # Pour obtenir l'état À cette sauvegarde, il faut `--backup-id X --immediate`.
  local rt_immediate=0 rt_time="" rt_backup=""

  while (( $# )); do
    case "$1" in
      -n|--namespace) NAMESPACE="${2:-}"; [[ -n "$NAMESPACE" ]] || usage; shift 2 ;;
      --name)         newname="${2:-}"; [[ -n "$newname" ]] || usage; shift 2 ;;
      --immediate)    rt_immediate=1; shift ;;
      --target-time)  [[ -n "${2:-}" ]] || usage; rt_time="$2"; shift 2 ;;
      --backup-id)    [[ -n "${2:-}" ]] || usage; rt_backup="$2"; shift 2 ;;
      --no-archive)   archive=0; shift ;;
      -h|--help)      usage 0 ;;
      -*)             die "Option inconnue : $1" ;;
      *)              [[ -z "$wanted" ]] || die "Un seul cluster à la fois (reçu « $wanted » puis « $1 »)."
                      wanted="$1"; shift ;;
    esac
  done
  [[ -n "$wanted" ]] || usage

  [[ -z "$rt_time" || $rt_immediate -eq 0 ]] \
    || die "--target-time et --immediate se contredisent : l'un demande de rejouer JUSQU'À une
       date, l'autre de s'arrêter dès la cohérence atteinte. Choisir."

  local rt_json='null'
  if [[ -n "$rt_backup" || -n "$rt_time" || $rt_immediate -eq 1 ]]; then
    rt_json="$(jq -nc \
      --arg b "$rt_backup" --arg t "$rt_time" --argjson imm "$rt_immediate" '
        {}
        | (if $b != "" then .backupID = $b else . end)
        | (if $t != "" then .targetTime = $t else . end)
        | (if $imm == 1 then .targetImmediate = true else . end)')"
  fi

  local target ns cluster
  target="$(resolve_cluster "$wanted")"
  ns="${target%%$'\t'*}"
  cluster="${target##*$'\t'}"
  newname="${newname:-${cluster}-restore}"

  [[ "$newname" != "$cluster" ]] \
    || die "Le cluster restauré ne peut pas porter le nom de sa source ('$cluster')."

  local cl p osname srv store win
  # `--show-managed-fields` : kubectl les masque par défaut depuis la 1.21, et c'est d'eux que
  # dépend tout le tri ci-dessous entre intention déclarée et défauts de l'opérateur.
  cl="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" --show-managed-fields -o json)"
  p="$(jq -c --arg p "$PLUGIN_NAME" '[ .spec.plugins[]? | select(.name == $p) ] | first' <<<"$cl")"
  [[ "$p" != "null" ]] \
    || die "Le Cluster '$ns/$cluster' ne porte pas le plugin barman : il n'a aucune sauvegarde
       depuis laquelle restaurer."

  osname="$(jq -r '.parameters.barmanObjectName' <<<"$p")"
  srv="$(jq -r --arg c "$cluster" '.parameters.serverName // $c' <<<"$p")"
  store="$(kubectl -n "$ns" get objectstores.barmancloud.cnpg.io "$osname" -o json 2>/dev/null)" \
    || die "ObjectStore '$osname' absent de '$ns' : rien à restaurer."
  win="$(jq -c --arg s "$srv" '.status.serverRecoveryWindow[$s] // null' <<<"$store")"
  [[ "$win" != "null" ]] \
    || die "Aucune fenêtre de récupération pour serverName '$srv' sur l'ObjectStore '$osname' :
       le bucket ne contient aucune sauvegarde de base exploitable."

  # --- Spec DÉRIVÉE du Cluster source, mais PAS de son `.spec` brut.
  #
  # Le `.spec` servi par l'API est l'objet DÉFAUTÉ : l'opérateur y a écrit une centaine de champs
  # que personne n'a déclarés (`postgresGID`, `logLevel`, `probes`, les ~25 `postgresql.parameters`
  # qu'il calcule lui-même, l'`imageName` résolu…). Le committer figerait dans Git des défauts
  # d'opérateur — qui cesseraient alors de bouger aux upgrades, silencieusement, et pour le seul
  # cluster restauré.
  #
  # Ce qui a été DÉCLARÉ se lit dans `.metadata.managedFields` : ArgoCD applique en Server-Side
  # Apply, donc son entrée `operation: "Apply"` liste exactement les champs du manifeste Git.
  # `prune` retaille le `.spec` sur cet arbre. Sur `forgejo-db` (2026-09-08) : 5 clés retenues
  # (`affinity`, `instances`, `monitoring`, `plugins`, `storage`) sur les ~30 servies par l'API.
  #
  # Repli explicite si aucune entrée Apply n'existe (objet créé à la main, hors ArgoCD) : le spec
  # complet, avec un avertissement — mieux vaut un manifeste bavard qu'un manifeste amputé.
  local applied
  applied="$(jq -c '
    [ .metadata.managedFields[]? | select(.operation == "Apply" and (.subresource // "") == "")
      | .fieldsV1["f:spec"] ]
    | if length == 0 then null else reduce .[] as $x ({}; . * $x) end' <<<"$cl")"
  if [[ "$applied" == "null" ]]; then
    warn "Aucun gestionnaire Server-Side Apply sur '$ns/$cluster' : impossible de distinguer ce qui"
    warn "    a été déclaré de ce que l'opérateur a défauté. Le manifeste ci-dessous reprend le spec"
    warn "    COMPLET — relire et retirer les défauts avant de committer."
  fi

  local manifest
  manifest="$(jq -n \
    --argjson cl "$cl" \
    --arg ns "$ns" \
    --arg src "$cluster" \
    --arg new "$newname" \
    --arg os "$osname" \
    --arg srv "$srv" \
    --arg plugin "$PLUGIN_NAME" \
    --argjson rt "$rt_json" \
    --argjson archive "$archive" \
    --argjson applied "$applied" '
    # Retaille un objet sur le `fieldsV1` qui le décrit. Un nœud portant "." est pris en entier
    # (feuille déclarée), un nœud sans aucune clé `f:` aussi : ce dernier cas couvre les listes,
    # dont les entrées sont indexées `k:`/`v:`/`i:` et que ce script ne cherche pas à recomposer.
    def prune($f):
      if   ($f | type) != "object" then .
      elif ($f | has("."))         then .
      elif (type) != "object"      then .
      else
        ([ $f | keys_unsorted[] | select(startswith("f:")) ]) as $ks
        | if ($ks | length) == 0 then .
          else
            . as $o
            | reduce $ks[] as $k ({};
                ($k[2:]) as $n
                | if ($o | has($n)) then . + { ($n): ($o[$n] | prune($f[$k])) } else . end)
          end
      end;
    {
      apiVersion: "postgresql.cnpg.io/v1",
      kind: "Cluster",
      metadata: {
        name: $new,
        namespace: $ns,
        annotations: { "homelab.wittner.tech/restored-from": "\($src)@\($srv)" }
      }
      + (if (($cl.metadata.labels // {}) | length) > 0 then { labels: $cl.metadata.labels } else {} end),
      spec: (
        ($cl.spec | prune($applied))
        | del(.bootstrap, .superuserSecret, .plugins)
        | .bootstrap = { recovery: ({ source: "origin" } + (if $rt == null then {} else { recoveryTarget: $rt } end)) }
        | .externalClusters = [ {
            name: "origin",
            plugin: {
              name: $plugin,
              # Lecture seule : `isWALArchiver` est volontairement absent ici. Le mettre ferait
              # archiver le cluster restauré DANS la source.
              parameters: { barmanObjectName: $os, serverName: $srv }
            }
          } ]
        | (if $archive == 1 then
             .plugins = [ {
               name: $plugin,
               isWALArchiver: true,
               # ⚠️ LOAD-BEARING : serverName DIFFÉRENT de celui de la source. Omis, il vaudrait
               # le nom du Cluster — ce qui est sans danger tant que le cluster restauré garde ce
               # nom, et devient destructeur à la seconde où on le renomme en `\($src)` pour
               # lui faire prendre la place du cluster original.
               parameters: { barmanObjectName: $os, serverName: $new }
             } ]
           else . end)
      )
    }')"

  # ⚠️ TOUT le cadre humain part sur stderr, et STDOUT ne porte QUE le manifeste. C'est ce qui
  # rend la commande pipeable (`> cluster.json`, `| kubectl apply -f -`, `| yq -P`) : un récapitulatif
  # mélangé au manifeste produirait un fichier invalide, et le découper à coups de `sed` serait la
  # première chose à casser au prochain changement de libellé. L'indentation décorative n'est
  # ajoutée que si stdout EST un terminal — redirigé, le manifeste sort brut.
  log "Manifeste de restauration — À COMMITTER, rien n'a été envoyé au cluster" >&2
  {
    printf '    source        : %s/%s (serverName « %s »)\n' "$ns" "$cluster" "$srv"
    printf '    destination   : %s/%s (serverName « %s »)\n' "$ns" "$newname" \
      "$( (( archive )) && echo "$newname" || echo 'aucun — archivage désactivé' )"
    printf '    objectStore   : %s\n' "$osname"
    printf '    fenêtre PITR  : %s → %s\n' \
      "$(jq -r '.firstRecoverabilityPoint // "-"' <<<"$win")" \
      "$(jq -r '.lastSuccessfulBackupTime // "-"' <<<"$win")"
    printf '    cible         : %s\n' \
      "$( [[ "$rt_json" == "null" ]] && echo 'dernier WAL archivé (fin de la fenêtre)' || jq -c . <<<"$rt_json" )"
    echo
  } >&2

  if [[ "$rt_json" == *targetTime* ]]; then
    warn "--target-time doit tomber DANS la fenêtre ci-dessus. En dehors, le rejeu s'arrête où il"
    warn "    peut et le cluster démarre sur un état antérieur SANS erreur — la perte est muette."
  fi
  if (( archive == 0 )); then
    warn "--no-archive : le cluster restauré n'a AUCUNE chaîne de sauvegarde. Clone de validation"
    warn "    uniquement — ne pas le promouvoir en production en l'état."
  fi
  warn "Avant de committer, deux points qui ne se voient pas dans le manifeste :"
  warn "  1. le service de connexion change de nom (« $newname-rw ») — tout ce qui pointait"
  warn "     « $cluster-rw » (ici gitea.config.database.HOST) doit suivre, sinon l'applicatif"
  warn "     continue de parler à la base d'origine sans rien signaler ;"
  warn "  2. l'opérateur génère un nouveau secret « $newname-app » et réaligne le mot de passe du"
  warn "     rôle applicatif dessus — les identifiants de la source ne sont pas conservés."
  echo

  if [[ -t 1 ]]; then
    jq . <<<"$manifest" | sed 's|^|  |'
    echo
    echo "  Destination suggérée : cluster/app/<application>/manifests/${newname}.yaml"
    echo "  (puis l'ajouter au kustomization.yaml du même dossier)"
  else
    jq . <<<"$manifest"
    {
      echo
      echo "  Destination suggérée : cluster/app/<application>/manifests/${newname}.yaml"
      echo "  (puis l'ajouter au kustomization.yaml du même dossier)"
    } >&2
  fi
}

# --- delete -----------------------------------------------------------------------------------

cmd_delete() {
  local backup=""
  while (( $# )); do
    case "$1" in
      -n|--namespace) NAMESPACE="${2:-}"; [[ -n "$NAMESPACE" ]] || usage; shift 2 ;;
      -h|--help)      usage 0 ;;
      -*)             die "Option inconnue : $1" ;;
      *)              [[ -z "$backup" ]] || die "Une seule sauvegarde à la fois (reçu « $backup » puis « $1 »)."
                      backup="$1"; shift ;;
    esac
  done
  [[ -n "$backup" ]] || usage

  local ns bk phase
  ns="$(resolve_ns backups.postgresql.cnpg.io "$backup")"
  bk="$(kubectl -n "$ns" get backups.postgresql.cnpg.io "$backup" -o json 2>/dev/null)" \
    || die "Sauvegarde '$backup' introuvable dans '$ns'."

  phase="$(jq -r '.status.phase // "inconnue"' <<<"$bk")"
  case "$phase" in
    completed|failed|walArchivingFailing) ;;
    *) die "Sauvegarde '$backup' en phase '$phase' (non terminale) : attendre sa fin.
       Supprimer l'objet n'annule pas la copie en cours côté sidecar." ;;
  esac

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : commande qui serait exécutée (rien n'est envoyé au cluster)"
    echo "  kubectl -n $ns delete backups.postgresql.cnpg.io $backup"
    exit 0
  fi

  # ⚠️ Piège n°4, et c'est l'inverse de velero : cette suppression ne touche PAS au bucket.
  log "Suppression de l'OBJET Backup « $ns/$backup »"
  printf '    phase       : %s\n' "$phase"
  printf '    cluster     : %s\n' "$(jq -r '.spec.cluster.name' <<<"$bk")"
  printf '    backupId    : %s\n' "$(jq -r '.status.backupId // "-"' <<<"$bk")"
  warn "Les DONNÉES restent dans le bucket : contrairement à velero, il n'y a pas de"
  warn "    DeleteBackupRequest ici. Leur seul GC est la « retentionPolicy » de l'ObjectStore."
  warn "    Le plugin n'expose aucune suppression distante — ni finalizer, ni champ, ni CRD."
  warn "Ce qui est perdu, c'est l'entrée du catalogue Kubernetes — donc la visibilité, pas la"
  warn "    sauvegarde. Elle reste restaurable par son backupId ci-dessus."
  confirm "$backup"

  kubectl -n "$ns" delete backups.postgresql.cnpg.io "$backup"
  log "Objet supprimé : $ns/$backup"

  # Une ScheduledBackup en `backupOwnerReference: self` possède ses Backup : ArgoCD ne les gère
  # pas, mais le contrôleur peut en recréer un à la prochaine occurrence de la schedule.
  if jq -e '[ .metadata.ownerReferences[]? | select(.kind == "ScheduledBackup") ] | length > 0' \
       <<<"$bk" >/dev/null; then
    log "Cette sauvegarde appartenait à une ScheduledBackup — la prochaine occurrence en créera une neuve."
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
