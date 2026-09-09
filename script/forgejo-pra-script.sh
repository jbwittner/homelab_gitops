#!/usr/bin/env bash
#
# Éprouver le PRA de forgejo : restaurer les DEUX chaînes dans une préprod jetable, la vérifier,
# la détruire.
#
# POURQUOI CE SCRIPT EXISTE. Une sauvegarde qui existe ne prouve rien. Ce composant a deux chaînes
# indépendantes — le PVC par velero/kopia, la base par barman-cloud — et six façons documentées
# d'obtenir une restauration VERTE ET FAUSSE. Les rejouer à la main demande une trentaine de
# commandes dont l'ordre est load-bearing ; les rejouer souvent ne se fait qu'automatisé.
#
# LES SIX PIÈGES, TOUS ENCODÉS ICI (détail : doc/forgejo-pra.md §7) :
#
#   1. Restaurer le PVC seul ne restaure AUCUNE donnée. La copie kopia est attachée au POD, pas au
#      PVC : c'est le PodVolumeRestore, déclenché par la restauration du Pod, qui écrit le volume.
#      Un Restore limité à `persistentvolumeclaims` crée un PVC vide, sans un message.
#   2. Le HTTPRoute de la sauvegarde porte le hostname PUBLIC (`forgejo.wittner.tech`,
#      `sectionName: https-public`). Restauré dans un autre namespace, il pose une SECONDE route
#      sur le hostname de production et le trafic se répartit entre deux backends, dont celui-ci.
#      C'est la ligne la plus importante du fichier : `excludedResources`.
#   3. velero EFFACE les ownerReferences. Les objets CNPG restaurés (pod, PVC, Services) sont donc
#      des orphelins permanents — et un PVC `forgejo-db-1` déjà présent est ADOPTÉ par le Cluster
#      de reprise : le `bootstrap.recovery` n'a pas lieu, silencieusement. D'où leur suppression
#      explicite avant l'étape suivante.
#   4. `recovery_target_time` exige un enregistrement de commit d'horodatage >= la cible. Sur une
#      base sans écriture depuis la sauvegarde de base, il n'y en a aucun : PostgreSQL sort en
#      `FATAL: recovery ended before configured recovery target was reached` au lieu de s'arrêter
#      au plus proche. D'où l'ABSENCE de cible par défaut — le rejeu complet donne le même état.
#   5. Un cluster restauré qui archive écrase les WAL de sa source. La préprod n'archive JAMAIS :
#      `--no-archive` est câblé en dur, non désactivable. Vérifié : la reprise fonctionne quand
#      même, le sidecar barman étant injecté depuis `externalClusters[].plugin` seul.
#   6. Une copie de la forge parle au monde extérieur — mailer Brevo armé, webhooks vers
#      `external`, miroirs de dépôts. Le pod restauré repart TOUT SEUL dès que la base apparaît.
#      Les neutralisations de `up` ne sont pas des options.
#
# CE N'EST PAS UNE VIOLATION DE LA RÈGLE GITOPS, ET LA FRONTIÈRE EST ÉTROITE. Ce script écrit dans
# le cluster, ce que les autres scripts du dossier ne font pas. Trois bornes le tiennent :
#   - il n'écrit QUE dans le namespace `forgejo-preprod`, qu'ArgoCD ne gère pas ;
#   - il ne touche à RIEN dans `forgejo` — la production est lue, jamais modifiée ;
#   - `down` fait partie de la procédure, pas des options.
# Tout ce qui doit durer redevient un manifeste sous `cluster/`.
#
# PRÉ-REQUIS, ET C'EST UN SCRIPT À PART. L'exercice exige que les deux chaînes se RECOUVRENT : une
# sauvegarde velero dont l'instant tombe dans la fenêtre PITR de barman. Sur une base peu écrite,
# ce n'est pas acquis — la fenêtre est figée à la dernière sauvegarde de base pendant que velero
# copie le PVC chaque nuit. Ce script REFUSE de partir sans, plutôt que de fabriquer lui-même sa
# condition d'exécution : la préparation vit dans
# [forgejo-pra-prepare-script.sh](forgejo-pra-prepare-script.sh).
#
#   script/forgejo-pra-prepare-script.sh check    # l exercice peut-il partir ?
#   script/forgejo-pra-prepare-script.sh run      # rendre les deux chaînes alignables
#   script/forgejo-pra-script.sh drill            # l exercice
#
# Usage, depuis la racine du dépôt :
#   script/forgejo-pra-script.sh up [backup]     monte la préprod (défaut : dernière sauvegarde
#                                                velero alignée sur la fenêtre PITR de barman)
#   script/forgejo-pra-script.sh verify          checklist d'intégrité — c'est ELLE, le test
#   script/forgejo-pra-script.sh status          ce qui tourne, et ce que ça coûte
#   script/forgejo-pra-script.sh down            détruit tout
#   script/forgejo-pra-script.sh drill [backup]  up + verify + down, sortie non nulle si un
#                                                contrôle échoue — la forme pour un cron
#
# Variables d'environnement :
#   PREPROD_NAMESPACE  namespace de la préprod (défaut `forgejo-preprod`)
#   PREPROD_HOST       hostname LAN (défaut `forgejo-preprod.lan.wittner.tech`)
#   GATEWAY_IP         IP du Gateway, pour attaquer sans dépendre du DNS (défaut 192.168.1.80)
#   PROXY_IP           IP du reverse proxy LAN, contrôle informatif (défaut 192.168.1.50)
#   TARGET_TIME        cible PITR explicite (RFC3339). ⚠️ Lire le piège n°4 avant de la poser.
#   TIMEOUT            plafond d'attente en secondes (défaut 900)
#   YES=1              passe la confirmation de `down`
#
# Codes de sortie : 0 = succès, 1 = échec ou pré-requis manquant, 2 = `verify` a trouvé au moins
#                   un contrôle en échec, 3 = délai d'attente dépassé.

set -euo pipefail

SRC_NS="forgejo"
SRC_CLUSTER="forgejo-db"
SRC_STORE="forgejo-db-store"
SRC_GCS_SECRET="forgejo-db-gcs"
# Secrets produits par sealed-secrets, donc reproductibles depuis Git — et EXCLUS des sauvegardes
# velero par le label `velero.io/exclude-from-backup` porté par leurs SealedSecret. Ils ne peuvent
# donc plus arriver dans la préprod par la restauration : il faut les y recopier.
#
# ⚠️ Et le déchiffrement ne peut PAS les produire ici : les SealedSecret sont en scope STRICT, liés
# au couple nom+namespace. Restaurée dans « $NS », une SealedSecret de « forgejo » ne déchiffre pas.
# C'est aussi pour ça que forgejo-db-gcs se recopiait déjà avant ce changement.
SRC_SEALED_SECRETS=(forgejo-db-gcs forgejo-secrets forgejo-smtp forgejo-admin)
VELERO_NS="velero"

NS="${PREPROD_NAMESPACE:-forgejo-preprod}"
HOST="${PREPROD_HOST:-forgejo-preprod.lan.wittner.tech}"
GW_IP="${GATEWAY_IP:-192.168.1.80}"
PROXY_IP="${PROXY_IP:-192.168.1.50}"
TIMEOUT="${TIMEOUT:-900}"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CNPG_SCRIPT="$HERE/cnpg-barman-plugin-script.sh"
VELERO_SCRIPT="$HERE/velero-script.sh"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

FAILED=0
ok()   { printf '  \033[32mok  \033[0m %s\n' "$*"; }
ko()   { printf '  \033[31mKO  \033[0m %s\n' "$*"; FAILED=$(( FAILED + 1 )); }
note() { printf '  \033[36mnote\033[0m %s\n' "$*"; }

usage() {
  local code="${1:-1}"
  cat >&2 <<'USAGE'
Éprouver le PRA de forgejo : restaurer les deux chaînes dans une préprod jetable, la vérifier,
la détruire. Ne modifie JAMAIS le namespace `forgejo`.

  forgejo-pra-script.sh up [backup]
      Monte la préprod : namespace, credential et ObjectStore recopiés, Restore velero du PVC et
      des objets, Cluster CNPG en bootstrap.recovery, neutralisations, HTTPRoute LAN + netpol.
      Sans argument : la dernière sauvegarde velero dont l'instant tombe DANS la fenêtre PITR de
      barman — la seule qui permette d'aligner les deux moitiés. S'il n'y en a aucune, `up`
      REFUSE : la condition se prépare avec forgejo-pra-prepare-script.sh, pas ici.

  forgejo-pra-script.sh verify
      La checklist. Dépôts sur le disque vs dépôts en base, `git fsck`, `forgejo doctor`, les
      quatre secrets d'app.ini, les neutralisations, la réponse HTTP. Sortie 2 si un contrôle
      échoue.

  forgejo-pra-script.sh status      ce qui tourne, et le volume immobilisé
  forgejo-pra-script.sh down        détruit le namespace et l'objet Restore
  forgejo-pra-script.sh drill [backup]
      up + verify + down. `down` est exécuté MÊME si `verify` échoue ; le code de sortie est celui
      de `verify`.

Variables : PREPROD_NAMESPACE · PREPROD_HOST · GATEWAY_IP · PROXY_IP · TARGET_TIME · TIMEOUT · YES=1
Codes de sortie : 0 succès · 1 erreur · 2 contrôle en échec · 3 délai dépassé
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
  if [[ ! -t 0 ]]; then die "Confirmation requise mais l'entrée standard n'est pas un terminal.
       Relancer avec YES=1."; fi
  printf 'Taper « %s » pour confirmer (autre chose annule) : ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "Annulé — rien n'a été fait."
}

# Attend qu'une expression jsonpath prenne une valeur attendue. $1 kind/name  $2 jsonpath
# $3 valeurs terminales séparées par « | »  $4 libellé
wait_for() {
  local target="$1" path="$2" terminal="$3" label="$4"
  local deadline=$(( SECONDS + TIMEOUT )) cur last=""
  while :; do
    cur="$(kubectl -n "$NS" get "$target" -o jsonpath="$path" 2>/dev/null || true)"
    if [[ -t 1 ]]; then
      printf '\r    %s : %-42s' "$label" "${cur:-…}"
    elif [[ "$cur" != "$last" ]]; then
      printf '    %s : %s\n' "$label" "${cur:-…}"; last="$cur"
    fi
    # Motif `case` interdit : venue d'une variable, l'alternation « | » est un caractère LITTÉRAL.
    [[ "|$terminal|" == *"|$cur|"* ]] && break
    if (( SECONDS >= deadline )); then
      [[ -t 1 ]] && printf '\n' || true
      die "Délai de ${TIMEOUT}s dépassé sur $target ($label = « ${cur:-vide} »)."
    fi
    sleep 5
  done
  [[ -t 1 ]] && printf '\n' || true
}

# Recopie un objet du namespace source vers la préprod, débarrassé de tout ce qui appartient à son
# instance d'origine. `del(.metadata.namespace)` est load-bearing : sans lui, `kubectl -n` est
# ignoré et l'objet repart dans `forgejo`.
copy_object() {
  local kind="$1" name="$2"
  kubectl -n "$SRC_NS" get "$kind" "$name" -o json \
    | jq 'del(.status, .metadata.namespace, .metadata.uid, .metadata.resourceVersion,
              .metadata.creationTimestamp, .metadata.generation, .metadata.ownerReferences,
              .metadata.managedFields, .metadata.annotations, .metadata.labels)' \
    | kubectl -n "$NS" apply -f - >/dev/null
}

# --- Choix de la sauvegarde ---------------------------------------------------------------------

# La dernière sauvegarde velero dont l'instant de fin tombe DANS la fenêtre PITR de barman. Hors
# fenêtre, les deux moitiés ne peuvent PAS être alignées : le PVC est figé à un instant que la base
# ne sait pas atteindre. Voir doc/forgejo-pra.md §1.
pick_backup() {
  local win first last bk
  # ⚠️ `serverName` SE LIT SUR LE CLUSTER, IL NE SE DÉDUIT PAS DE SON NOM — même correctif que
  # `forgejo-pra-prepare-script.sh`, et les deux DOIVENT rester d'accord : ils choisissent la même
  # sauvegarde, et une divergence ferait dire « prêt » à l'un pendant que l'autre refuse de partir.
  # Depuis que la reprise se fait sous le nom d'origine, ce sont les générations qui portent le
  # serverName (`forgejo-db`, `-v3`, `-v4`…) : le déduire fait lire la fenêtre d'une génération
  # MORTE et retenir un couple obsolète.
  local srv cl_json
  cl_json="$(kubectl -n "$SRC_NS" get clusters.postgresql.cnpg.io "$SRC_CLUSTER" -o json 2>/dev/null || echo '{}')"
  srv="$(jq -r --arg p "barman-cloud.cloudnative-pg.io" --arg c "$SRC_CLUSTER" '
      ([ .spec.plugins[]? | select(.name == $p) ] | first | .parameters.serverName) // $c' <<<"$cl_json")"
  win="$(kubectl -n "$SRC_NS" get objectstores.barmancloud.cnpg.io "$SRC_STORE" \
        -o jsonpath="{.status.serverRecoveryWindow.$srv}" 2>/dev/null || true)"
  [[ -n "$win" ]] || die "Aucune fenêtre de récupération pour le serverName « $srv » sur l'ObjectStore
       « $SRC_STORE » : le bucket barman ne contient aucune sauvegarde de base exploitable.
       Diagnostic : script/cnpg-barman-plugin-script.sh list"
  first="$(jq -r '.firstRecoverabilityPoint // ""' <<<"$win")"
  last="$(jq -r '.lastSuccessfulBackupTime // ""' <<<"$win")"

  bk="$(kubectl -n "$VELERO_NS" get backups.velero.io -o json \
        | jq -r --arg ns "$SRC_NS" --arg a "$first" --arg b "$last" '
            [ .items[]
              | select(.status.phase == "Completed")
              | select((.spec.includedNamespaces // []) | index($ns))
              | select(.status.completionTimestamp >= $a and .status.completionTimestamp <= $b) ]
            | sort_by(.status.completionTimestamp) | last | .metadata.name // ""')"

  if [[ -z "$bk" ]]; then
    die "Aucune sauvegarde velero de « $SRC_NS » ne tombe dans la fenêtre PITR de barman
       ($first → $last). Les deux moitiés ne peuvent pas être alignées.
       C'est le cas normal tant que la chaîne barman est plus jeune que la dernière sauvegarde
       velero, et tant qu'aucun WAL n'a été archivé après elle — une base au repos n'en archive
       aucun.

       C'est une CONDITION de l'exercice, et elle a son propre script :
         script/forgejo-pra-prepare-script.sh check    # état, ne crée rien
         script/forgejo-pra-prepare-script.sh run      # crée les deux sauvegardes, dans l ordre"
  fi
  printf '%s' "$bk"
}

# --- up -----------------------------------------------------------------------------------------

cmd_up() {
  local backup=""
  while (( $# )); do
    case "$1" in
      -h|--help) usage 0 ;;
      -*)        die "Option inconnue : $1.
       La fabrication du recouvrement n'est PAS une option de ce script : c'est une CONDITION de
       l'exercice, et elle a le sien — script/forgejo-pra-prepare-script.sh run" ;;
      *)         [[ -z "$backup" ]] || die "Une seule sauvegarde à la fois (reçu « $backup » puis « $1 »)."
                 backup="$1"; shift ;;
    esac
  done

  kubectl get ns "$NS" >/dev/null 2>&1 \
    && die "Le namespace « $NS » existe déjà. Une seule préprod à la fois — sans quoi on finit par
       lire la mauvaise. La détruire d'abord : script/forgejo-pra-script.sh down"

  # --- Pré-requis. Lus sur la PRODUCTION, en lecture seule.
  log "Pré-requis"
  kubectl -n "$SRC_NS" get cluster "$SRC_CLUSTER" >/dev/null 2>&1 \
    || die "Cluster « $SRC_NS/$SRC_CLUSTER » introuvable."
  kubectl -n "$SRC_NS" get secret "$SRC_GCS_SECRET" >/dev/null 2>&1 \
    || die "Secret « $SRC_GCS_SECRET » absent de « $SRC_NS ».
       Il n'est PAS dans les sauvegardes velero antérieures au 2026-09-08 après-midi, et le
       SealedSecret de Git est chiffré pour le couple (nom, namespace) : il ne se déchiffre pas
       ailleurs. Sans lui, la préprod ne peut pas lire le bucket barman."
  [[ -x "$CNPG_SCRIPT" ]]   || die "$CNPG_SCRIPT introuvable ou non exécutable."
  [[ -x "$VELERO_SCRIPT" ]] || die "$VELERO_SCRIPT introuvable ou non exécutable."

  # `pick_backup` retient la dernière sauvegarde velero DANS la fenêtre PITR. S'il n'y en a
  # aucune, il REFUSE et renvoie vers le script de préparation : fabriquer le recouvrement ici
  # ferait de l'exercice le juge de sa propre condition d'exécution.
  backup="${backup:-$(pick_backup)}"
  kubectl -n "$VELERO_NS" get backups.velero.io "$backup" >/dev/null 2>&1 \
    || die "Sauvegarde velero « $backup » introuvable. Lister : script/velero-script.sh list"

  local completed vols
  completed="$(kubectl -n "$VELERO_NS" get backups.velero.io "$backup" \
                -o jsonpath='{.status.completionTimestamp}')"
  vols="$(kubectl -n "$VELERO_NS" get podvolumebackups -l "velero.io/backup-name=$backup" \
          -o json 2>/dev/null | jq '.items | length')"
  ok "sauvegarde velero : $backup (fin $completed, $vols volume(s))"
  ok "fenêtre barman     : $(kubectl -n "$SRC_NS" get objectstores.barmancloud.cnpg.io "$SRC_STORE" \
        -o jsonpath="{.status.serverRecoveryWindow.$SRC_CLUSTER}" | jq -r '"\(.firstRecoverabilityPoint) → \(.lastSuccessfulBackupTime)"')"
  [[ "${vols:-0}" -gt 0 ]] \
    || warn "Cette sauvegarde ne porte AUCUN volume : le PVC sera restauré VIDE. Objets
    sauvegardés, données absentes — c'est exactement le mode d'échec que cet exercice cherche."

  # --- 1. Namespace jetable, étiqueté pour qu'on sache d'où il vient.
  log "1/7 Namespace « $NS »"
  kubectl create namespace "$NS" >/dev/null
  kubectl label namespace "$NS" --overwrite \
    app.kubernetes.io/part-of=homelab-gitops \
    homelab.wittner.tech/drill=forgejo-pra >/dev/null

  # --- 2. Credential GCS et destination barman. L'ObjectStore est NAMESPACÉ et le plugin n'en lit
  # que dans le namespace du Cluster : il ne se mutualise pas, il se recopie.
  log "2/7 Credential GCS et ObjectStore"
  local sec
  for sec in "${SRC_SEALED_SECRETS[@]}"; do
    kubectl -n "$SRC_NS" get secret "$sec" >/dev/null 2>&1 \
      || die "Secret « $sec » absent de « $SRC_NS » : il est exclu des sauvegardes velero et ne
       peut venir que d'ici. Vérifier que sa SealedSecret est Synced :
       kubectl -n $SRC_NS get sealedsecret"
    copy_object secret "$sec"
  done
  copy_object objectstores.barmancloud.cnpg.io "$SRC_STORE"
  ok "${#SRC_SEALED_SECRETS[@]} secrets et $SRC_STORE recopiés dans $NS"

  # --- 3. Restore velero. Le PVC, le Pod qui porte sa donnée, les Secrets matérialisés.
  log "3/7 Restauration velero → $NS"
  local restore
  restore="$(kubectl create -o jsonpath='{.metadata.name}' -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  generateName: pra-forgejo-
  namespace: $VELERO_NS
  labels:
    homelab.wittner.tech/drill: forgejo-pra
spec:
  backupName: $backup
  includedNamespaces: [$SRC_NS]
  namespaceMapping:
    $SRC_NS: $NS
  excludedResources:
    - httproutes.gateway.networking.k8s.io
    - ciliumnetworkpolicies.cilium.io
    - ciliumendpoints.cilium.io
    - clusters.postgresql.cnpg.io
    - sealedsecrets.bitnami.com
    - customresourcedefinitions.apiextensions.k8s.io
    - endpointslices.discovery.k8s.io
    - endpoints
    - leases.coordination.k8s.io
EOF
)"
  printf '%s' "$restore" > "/tmp/.forgejo-pra-restore-$NS" || true
  local deadline=$(( SECONDS + TIMEOUT )) phase
  while :; do
    phase="$(kubectl -n "$VELERO_NS" get restores.velero.io "$restore" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ -t 1 ]] && printf '\r    restore : %-24s' "${phase:-…}" || true
    [[ "|Completed|PartiallyFailed|Failed|FailedValidation|" == *"|$phase|"* ]] && break
    (( SECONDS >= deadline )) && { [[ -t 1 ]] && printf '\n'; die "Restore « $restore » : délai dépassé."; }
    sleep 5
  done
  [[ -t 1 ]] && printf '\n' || true
  [[ "$phase" == "Completed" ]] \
    || die "Restore « $restore » en phase « $phase ».
       kubectl -n $VELERO_NS get restores.velero.io $restore -o yaml"

  local pvr
  pvr="$(kubectl -n "$VELERO_NS" get podvolumerestores -l "velero.io/restore-name=$restore" -o json 2>/dev/null \
        | jq -r '[.items[] | select(.status.phase == "Completed")] | length')"
  ok "restore $restore : Completed, ${pvr:-0} volume(s) réellement repris"
  [[ "${pvr:-0}" -gt 0 ]] \
    || warn "AUCUN volume repris. La donnée kopia est portée par le POD, pas par le PVC : si les
    pods ont été exclus du Restore, le PVC est vide et rien ne le dit."

  # --- 4. ⚠️ Piège n°3. velero efface les ownerReferences : ces objets sont des orphelins
  # permanents. Un PVC `forgejo-db-1` laissé en place est ADOPTÉ par le Cluster de reprise, qui
  # saute alors son bootstrap.recovery — et l'on croit avoir restauré la base.
  log "4/7 Suppression des orphelins CNPG restaurés"
  kubectl -n "$NS" delete pod "$SRC_CLUSTER-1" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pvc "$SRC_CLUSTER-1" --ignore-not-found --wait=true  >/dev/null 2>&1 || true
  kubectl -n "$NS" delete svc "$SRC_CLUSTER-r" "$SRC_CLUSTER-ro" "$SRC_CLUSTER-rw" \
    --ignore-not-found >/dev/null 2>&1 || true
  ok "pod, PVC et Services « $SRC_CLUSTER-* » retirés"

  # --- 5. La base, par bootstrap.recovery. Le manifeste est DÉRIVÉ du Cluster de production par
  # cnpg-barman-plugin-script.sh, jamais retapé, puis re-ciblé sur la préprod.
  #
  # Le nom `forgejo-db` est CONSERVÉ, à dessein : le Deployment restauré cherche `forgejo-db-rw` et
  # le Secret `forgejo-db-app`. Le garder évite de reconfigurer quoi que ce soit — donc d'introduire
  # une divergence entre ce qu'on teste et ce qui tourne en production.
  # ⚠️ Ce qui rend ce choix sûr est `--no-archive` : sans `spec.plugins`, la préprod n'archive
  # RIEN, et ne peut donc pas écrire sous le `serverName` de la production.
  log "5/7 Base par bootstrap.recovery"
  local target_args=()
  if [[ -n "${TARGET_TIME:-}" ]]; then
    target_args=(--target-time "$TARGET_TIME")
    warn "TARGET_TIME=$TARGET_TIME. « recovery_target_time » exige un commit d'horodatage >= la cible.
    Sans écriture depuis la sauvegarde de base, PostgreSQL sort en
    « recovery ended before configured recovery target was reached » et le Cluster ne démarre pas."
  fi
  "$CNPG_SCRIPT" restore "$SRC_CLUSTER" --name "$SRC_CLUSTER-pra" --no-archive "${target_args[@]}" 2>/dev/null \
    | jq --arg ns "$NS" --arg n "$SRC_CLUSTER" '.metadata.namespace = $ns | .metadata.name = $n' \
    | kubectl apply -f - >/dev/null
  wait_for "cluster/$SRC_CLUSTER" '{.status.phase}' 'Cluster in healthy state' 'cluster'
  ok "Cluster $NS/$SRC_CLUSTER : sain"

  # --- 6. ⚠️ Piège n°6. Le pod restauré est reparti tout seul dès l'apparition de la base, AVEC la
  # configuration de production : mailer Brevo armé, webhooks vers `external`, miroirs actifs. Les
  # cinq réglages ci-dessous sont ce qui distingue une copie inerte d'une seconde forge vivante.
  log "6/7 Neutralisations"
  local b64_server b64_mailer b64_webhook b64_mirror b64_cron
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  b64_server="$(b64 "APP_DATA_PATH=/data
DISABLE_SSH=true
DOMAIN=$HOST
ENABLE_PPROF=false
HTTP_PORT=3000
PROTOCOL=http
ROOT_URL=https://$HOST/
SSH_DOMAIN=$HOST
SSH_LISTEN_PORT=2222
SSH_PORT=22
START_SSH_SERVER=false")"
  b64_mailer="$(b64 'ENABLED=false')"
  b64_webhook="$(b64 'ALLOWED_HOST_LIST=loopback')"
  b64_mirror="$(b64 'ENABLED=false
ENABLE_PUSH_MIRROR=false')"
  b64_cron="$(b64 'ENABLED=false')"
  kubectl -n "$NS" patch secret forgejo-inline-config --type=merge -p "$(jq -n \
    --arg server "$b64_server" --arg mailer "$b64_mailer" --arg webhook "$b64_webhook" \
    --arg mirror "$b64_mirror" --arg cron "$b64_cron" \
    '{data:{server:$server, mailer:$mailer, webhook:$webhook, mirror:$mirror, cron:$cron}}')" >/dev/null
  ok "ROOT_URL → https://$HOST/ · mailer, miroirs et cron coupés · webhooks en loopback"

  # --- 7. Exposition LAN et filtrage réseau.
  log "7/7 Exposition LAN et filtrage réseau"
  kubectl apply -f - >/dev/null <<EOF
# Contrepartie infrastructurelle des neutralisations : celles-ci refusent la fonctionnalité,
# celui-ci refuse le paquet. Une copie de la forge ne joint NI le LAN, NI Internet, NI le reste
# du cluster — seulement le DNS et sa propre base.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: forgejo-pra
  namespace: $NS
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: forgejo
  ingress:
    - fromEntities: [ingress, host, remote-node]
      toPorts:
        - ports: [{ port: "3000", protocol: TCP }]
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: UDP }]
          rules:
            dns: [{ matchPattern: "*" }]
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: $NS
            cnpg.io/cluster: $SRC_CLUSTER
      toPorts:
        - ports: [{ port: "5432", protocol: TCP }]
---
# ⚠️ Listener « https-internal » (*.lan.wittner.tech), JAMAIS « https-public » : le hostname public
# est celui de la production, et deux routes sur le même hostname se partagent le trafic.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: forgejo-pra
  namespace: $NS
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: shared-gw
      namespace: gateway
      sectionName: https-internal
  hostnames: [$HOST]
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - group: ""
          kind: Service
          name: forgejo-http
          port: 3000
          weight: 1
EOF
  ok "HTTPRoute $HOST → forgejo-http:3000 · CiliumNetworkPolicy posée"

  # Le redémarrage est ce qui APPLIQUE les neutralisations : app.ini est composé par
  # l'init-container `init-app-ini` au démarrage, jamais relu à chaud.
  kubectl -n "$NS" rollout restart deploy/forgejo >/dev/null
  kubectl -n "$NS" rollout status deploy/forgejo --timeout="${TIMEOUT}s" >/dev/null \
    || die "Le Deployment forgejo n'est pas devenu disponible."
  ok "Deployment redémarré avec la configuration de préprod"

  echo
  log "Préprod montée. Le test, c'est la commande suivante :"
  echo "  script/forgejo-pra-script.sh verify"
  echo "  script/forgejo-pra-script.sh down      # ← fait partie de la procédure"
}

# --- verify -------------------------------------------------------------------------------------

cmd_verify() {
  kubectl get ns "$NS" >/dev/null 2>&1 || die "Namespace « $NS » absent. Monter d'abord : up"
  local pod
  pod="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}')"
  [[ -n "$pod" ]] || die "Aucun pod forgejo en Running dans « $NS »."

  log "A. La donnée du PVC est revenue"
  local disk_repos
  disk_repos="$(kubectl -n "$NS" exec "$pod" -c forgejo -- \
    sh -c 'ls -d /data/git/gitea-repositories/*/*.git 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r')"
  [[ "${disk_repos:-0}" -gt 0 ]] \
    && ok "$disk_repos dépôt(s) sur le disque" \
    || ko "aucun dépôt sur le disque — PVC restauré VIDE (la donnée kopia est portée par le pod)"

  # ⚠️ Les quatre secrets cryptographiques. Générés au premier démarrage et écrits SUR LE VOLUME,
  # ils sont ce qui rend le PVC irremplaçable : sans eux, sessions, jetons d'API et objets LFS déjà
  # en base ne sont plus déchiffrables. Ils doivent être là, et identiques à la production.
  local nsec
  nsec="$(kubectl -n "$NS" exec "$pod" -c forgejo -- \
    sh -c 'grep -cE "^(SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET|LFS_JWT_SECRET) =" /data/gitea/conf/app.ini' 2>/dev/null | tr -d ' \r')"
  [[ "${nsec:-0}" -ge 4 ]] \
    && ok "les 4 secrets cryptographiques sont dans app.ini" \
    || ko "seulement ${nsec:-0}/4 secrets dans app.ini — sessions et LFS seraient perdus"

  log "B. Les dépôts sont intègres"
  local fsck
  fsck="$(kubectl -n "$NS" exec "$pod" -c forgejo -- sh -c '
    rc=0
    for r in /data/git/gitea-repositories/*/*.git; do
      [ -d "$r" ] || continue
      if ! git -C "$r" fsck --no-progress --no-dangling >/dev/null 2>&1; then
        echo "FSCK-KO $r"; rc=1
      fi
    done
    exit $rc' 2>&1)" && ok "git fsck : tous les dépôts sont intègres" \
                     || ko "git fsck en échec : ${fsck:-erreur d exécution}"

  local commits
  commits="$(kubectl -n "$NS" exec "$pod" -c forgejo -- sh -c '
    t=0
    for r in /data/git/gitea-repositories/*/*.git; do
      [ -d "$r" ] || continue
      n=$(git -C "$r" rev-list --all --count 2>/dev/null || echo 0)
      t=$((t + n))
    done
    echo $t' 2>/dev/null | tr -d ' \r')"
  [[ "${commits:-0}" -gt 0 ]] \
    && ok "$commits commit(s) lisibles au total" \
    || ko "aucun commit lisible — dépôts présents mais vides"

  log "C. La base est revenue, et elle est d'accord avec le disque"
  local counts db_repos
  counts="$(kubectl -n "$NS" exec "$SRC_CLUSTER-1" -c postgres -- \
    psql -U postgres -d app -At -F' ' -c \
    'select (select count(*) from "user"), (select count(*) from repository), (select count(*) from issue);' 2>/dev/null | tr -d '\r')"
  if [[ -n "$counts" ]]; then
    ok "base : $(awk '{print "comptes="$1" dépôts="$2" issues="$3}' <<<"$counts")"
    db_repos="$(awk '{print $2}' <<<"$counts")"
    # LE contrôle qui distingue une restauration alignée d'une restauration bancale : le disque et
    # la base doivent décrire le MÊME ensemble de dépôts. Un écart = les deux moitiés viennent
    # d'instants différents (cf. doc/forgejo-pra.md §1).
    if [[ "${db_repos:-0}" == "${disk_repos:-0}" ]]; then
      ok "cohérence disque/base : $disk_repos dépôt(s) des deux côtés"
    else
      ko "INCOHÉRENCE : $disk_repos dépôt(s) sur le disque, $db_repos en base — les deux moitiés
       ne viennent pas du même instant"
    fi
  else
    ko "base injoignable ou vide"
  fi

  log "D. Forgejo se déclare cohérent"
  local doctor
  if doctor="$(kubectl -n "$NS" exec "$pod" -c forgejo -- \
      gitea doctor check --run check-db-consistency,check-db-version,storages 2>&1)"; then
    if grep -qiE '\[E\]|error' <<<"$doctor"; then
      ko "forgejo doctor signale des anomalies :"; sed 's/^/       /' <<<"$doctor" | tail -8 >&2
    else
      ok "forgejo doctor : aucune anomalie (db-consistency, db-version, storages)"
    fi
  else
    ko "forgejo doctor n'a pas pu s'exécuter :"; sed 's/^/       /' <<<"$doctor" | tail -6 >&2
  fi

  log "E. La copie est muette"
  local ini
  ini="$(kubectl -n "$NS" exec "$pod" -c forgejo -- cat /data/gitea/conf/app.ini 2>/dev/null)"
  # ⚠️ Lecture SECTION PAR SECTION. Un `grep "^ENABLED = false"` matcherait indifféremment
  # [mailer], [mirror] et [cron] : les trois se valideraient mutuellement et une neutralisation
  # oubliée passerait au vert.
  ini_get() { awk -v s="[$1]" -v k="$2" '
    $0 == s { in_s = 1; next }
    /^\[/   { in_s = 0 }
    in_s && $1 == k { print $3; exit }' <<<"$ini"; }
  check_ini() {
    local got; got="$(ini_get "$2" "$3")"
    [[ "$got" == "$4" ]] && ok "$1" || ko "$1 — [$2] $3 = « ${got:-absent} », attendu « $4 »"
  }
  check_ini "mailer coupé"                  mailer  ENABLED            false
  check_ini "miroirs coupés"                mirror  ENABLED            false
  check_ini "push-mirror coupé"             mirror  ENABLE_PUSH_MIRROR false
  check_ini "cron coupé"                    cron    ENABLED            false
  check_ini "webhooks confinés en loopback" webhook ALLOWED_HOST_LIST  loopback
  [[ "$(ini_get server ROOT_URL)" == "https://$HOST/" ]] \
    && ok "ROOT_URL pointe la préprod" \
    || ko "ROOT_URL ne pointe PAS la préprod — la copie émet des liens vers la production"
  # ⚠️ Ce contrôle ne peut pas être « ok » : le mot de passe du relais SMTP est injecté par
  # `additionalConfigFromEnvs` et atterrit en clair dans app.ini, même mailer coupé.
  grep -qE '^PASSWD = ' <<<"$ini" \
    && note "le mot de passe SMTP est en clair dans l'app.ini de la préprod (mailer coupé, mais le
       secret est là) — raison de plus pour que « down » ne soit pas optionnel"

  log "F. Elle répond"
  local code
  code="$(curl -sk --max-time 10 --resolve "$HOST:443:$GW_IP" \
          -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] \
    && ok "HTTP $code en direct sur le Gateway ($GW_IP)" \
    || ko "HTTP $code en direct sur le Gateway ($GW_IP)"

  # Informatif, et JAMAIS bloquant : un hostname *.lan doit être déclaré dans le routeur Traefik de
  # $PROXY_IP, qui vit hors du dépôt. Un 404 ici avec un 200 ci-dessus est la signature exacte de
  # cette déclaration manquante — pas d'un problème de restauration.
  code="$(curl -sk --max-time 10 --resolve "$HOST:443:$PROXY_IP" \
          -o /dev/null -w '%{http_code}' "https://$HOST/" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ok "HTTP 200 via le reverse proxy LAN ($PROXY_IP)"
  else
    note "HTTP $code via le reverse proxy LAN ($PROXY_IP) : « $HOST » n'y est pas déclaré.
       Hors dépôt, non bloquant pour l'exercice — mais c'est le même geste qui manquerait à une
       reprise réelle sur un nouveau hostname."
  fi

  echo
  if (( FAILED == 0 )); then
    log "Tous les contrôles passent. La sauvegarde est restaurable, et prouvée telle."
  else
    warn "$FAILED contrôle(s) en échec."
    return 2
  fi
}

# --- status / down --------------------------------------------------------------------------------

cmd_status() {
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    log "Aucune préprod. Monter : script/forgejo-pra-script.sh up"
    return 0
  fi
  log "Préprod « $NS »"
  kubectl -n "$NS" get pods,pvc,httproute 2>/dev/null | sed 's/^/    /'
  local gi
  gi="$(kubectl -n "$NS" get pvc -o json 2>/dev/null \
    | jq -r '[.items[].spec.resources.requests.storage | sub("Gi$";"") | tonumber] | add // 0')"
  echo
  warn "${gi:-0} Gi de groupe de volumes IMMOBILISÉS : la StorageClass est en thinProvision « no »,
    le LV est réservé en entier dès la création, utilisé ou non."
  warn "Démonter : script/forgejo-pra-script.sh down"
}

cmd_down() {
  kubectl get ns "$NS" >/dev/null 2>&1 || { log "Aucune préprod à détruire."; return 0; }

  # ⚠️ Le label est la SEULE chose qui distingue une préprod jetable d un namespace vivant. Le
  # vérifier plutôt que se fier au nom protège aussi de `PREPROD_NAMESPACE=argocd` et de tout
  # namespace qui porterait par hasard le nom attendu.
  local drill
  drill="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.homelab\.wittner\.tech/drill}' 2>/dev/null || true)"
  [[ "$drill" == "forgejo-pra" ]] \
    || die "Le namespace « $NS » ne porte pas le label homelab.wittner.tech/drill=forgejo-pra :
       il n a PAS été créé par cet exercice. Refus de le supprimer.
       Si c est bien une préprod à jeter, la supprimer à la main en connaissance de cause."

  log "Destruction de la préprod « $NS »"
  kubectl -n "$NS" get pvc -o custom-columns=NOM:.metadata.name,TAILLE:.spec.resources.requests.storage \
    --no-headers 2>/dev/null | sed 's/^/    PVC /'
  warn "La StorageClass est en reclaimPolicy « Delete » : la suppression du namespace DÉTRUIT les
    LV. C'est voulu ici — ce sont des données de drill — et c'est la même mécanique qui rend
    « Prune=false,Delete=false » load-bearing sur le PVC de production."
  confirm "$NS"

  kubectl delete ns "$NS" --wait=false >/dev/null
  # Les Restore de l'exercice sont étiquetés : on ne balaie que les siens, jamais ceux d'une
  # restauration réelle en cours.
  kubectl -n "$VELERO_NS" delete restores.velero.io \
    -l homelab.wittner.tech/drill=forgejo-pra --ignore-not-found >/dev/null 2>&1 || true
  rm -f "/tmp/.forgejo-pra-restore-$NS" 2>/dev/null || true
  log "Supprimé. La production n'a jamais été touchée."
}

# --- drill ----------------------------------------------------------------------------------------

cmd_drill() {
  local rc=0
  cmd_up "$@"
  echo
  cmd_verify || rc=$?
  echo
  # `down` s'exécute MÊME en cas d'échec : un exercice qui laisse sa préprod derrière lui parce
  # qu'un contrôle a échoué immobilise 110 Gi jusqu'à ce que quelqu'un s'en aperçoive.
  YES=1 cmd_down
  return "$rc"
}

# --- Aiguillage ------------------------------------------------------------------------------------

require_bins kubectl jq curl base64 awk

# ⚠️ GARDE-FOU RACINE, et il ferme un chemin qui menait à la destruction de la production.
# Sans lui, `PREPROD_NAMESPACE=forgejo` retourne l exercice contre la prod : l étape 4 supprime
# `pvc/forgejo-db-1` — le volume de la base, avec `reclaimPolicy: Delete` — et `down` supprime le
# namespace entier. Le pire était le message : `up` refusait bien de partir, mais en disant « le
# namespace existe déjà, la détruire d abord : down ». Il DIRIGEAIT vers la suppression.
[[ "$NS" != "$SRC_NS" ]] || die "PREPROD_NAMESPACE ne peut pas valoir « $SRC_NS ».
       Ce script écrirait alors dans la PRODUCTION : suppression du PVC de la base, neutralisation
       de la configuration, coupure réseau. La reprise EN PLACE est une autre procédure, qui
       suspend l auto-sync et ne fait rien de tout cela — doc/forgejo-pra.md §8."

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  status) shift; cmd_status "$@" ;;
  down)   shift; cmd_down "$@" ;;
  drill)  shift; cmd_drill "$@" ;;
  -h|--help|help) usage 0 ;;
  '')             usage 1 ;;
  *)      die "Commande inconnue : « $1 ». Voir : $(basename "$0") --help" ;;
esac
