#!/usr/bin/env bash
#
# Gestion des sauvegardes openbao : lister, déclencher, récupérer, VÉRIFIER, restaurer.
#
# POURQUOI CE SCRIPT EXISTE. Le contenu du coffre est la seule chose du homelab absente de Git.
# Sa sauvegarde a quatre modes d'échec, tous silencieux :
#
#   1. UN OBJET DANS LE BUCKET NE PROUVE RIEN. Ni que l'archive est complète, ni que la barrière
#      de chiffrement est ouvrable, ni que la configuration posée par le repo Terraform y est. Le
#      CronJob passe au vert dès que s3cmd a rendu 0. `verify` est la seule commande qui répond
#      vraiment — elle remonte le snapshot dans un OpenBao jetable et le restaure pour de bon.
#   2. LE CONTRÔLE DÉCISIF NE DEMANDE AUCUNE CLÉ, et c'est contre-intuitif. Après un
#      `snapshot restore`, l'instance jetable adopte la CONFIGURATION DE SEAL du coffre source :
#      ses `1 part / seuil 1` deviennent les `5 / 3` de la prod. Si ça se produit, le keyring du
#      snapshot a été ouvert et vérifié, donc `state.bin` est intègre. `verify` compare
#      automatiquement avec la prod. Les parts de descellement ne servent qu'à `--unseal`, qui
#      va plus loin : lire le contenu.
#   3. LES PIÈGES DE L'IMAGE COÛTENT CHACUN UN ALLER-RETOUR. Config montée dans `/openbao/config`
#      = ignorée en silence ; `/openbao/data` n'existe pas ; `disable_mlock` n'existe plus en
#      2.6.x ; le restore réussi affiche quand même `Error properly closing policy file`. Tout est
#      encapsulé ici, et documenté dans doc/openbao-restore-local.md.
#   4. LE CONTRAT ESO NE SE DEVINE PAS. `--unseal` ne relit pas une liste de chemins écrite à la
#      main : il la DÉRIVE des `ExternalSecret` du cluster et du `ClusterSecretStore`. Une liste
#      retapée diverge — celle du README d'openbao a déjà divergé sur trois entrées.
#
# CE N'EST PAS UNE VIOLATION DE LA RÈGLE GITOPS. Un snapshot, un Job manuel et un restore sont des
# ÉVÉNEMENTS, pas des états désirés. Leur place est une commande, au même titre que
# `bao operator unseal`.
#
# Usage, depuis n'importe où :
#   cluster/infra/openbao/openbao-script.sh status
#   cluster/infra/openbao/openbao-script.sh list [motif]
#   cluster/infra/openbao/openbao-script.sh snapshot
#   cluster/infra/openbao/openbao-script.sh fetch <réf> [-o fichier]
#   cluster/infra/openbao/openbao-script.sh check <réf>
#   cluster/infra/openbao/openbao-script.sh verify <réf> [--unseal] [--keep]
#   cluster/infra/openbao/openbao-script.sh up <réf> [--unseal] [--replace]
#   cluster/infra/openbao/openbao-script.sh unseal
#   cluster/infra/openbao/openbao-script.sh bao <args…>
#   cluster/infra/openbao/openbao-script.sh stop
#   cluster/infra/openbao/openbao-script.sh restore <réf> [--no-pre-snapshot]
#
# <réf> = un nom d'objet du bucket, le mot-clé `latest` ou `oldest`, ou un chemin de fichier local.
#
# Variables d'environnement :
#   OPENBAO_NAMESPACE  namespace openbao (défaut `openbao`)
#   OPENBAO_WORKDIR    répertoire de travail, créé en 0700 (défaut ~/.cache/openbao-drill)
#   OPENBAO_IMAGE      image de l'instance jetable (défaut : celle du StatefulSet de prod)
#   TIMEOUT            plafond d'attente en secondes (défaut 900)
#   DRY_RUN=1          affiche ce qui serait fait, n'envoie rien
#   NO_WAIT=1          crée l'objet et rend la main sans suivre son déroulement
#   YES=1              passe les confirmations interactives (snapshot, restore)
#
# Codes de sortie : 0 = succès, 1 = échec ou pré-requis manquant, 2 = succès avec réserve
#                   (vérification partielle, comparaison impossible), 3 = délai dépassé.

set -euo pipefail

NAMESPACE="${OPENBAO_NAMESPACE:-openbao}"
TIMEOUT="${TIMEOUT:-900}"
WORKDIR="${OPENBAO_WORKDIR:-$HOME/.cache/openbao-drill}"

# Instance jetable. Noms fixes et explicites : `stop` doit pouvoir nettoyer après un Ctrl-C, y
# compris dans un autre terminal que celui qui a lancé `verify`.
DRILL_NAME="openbao-drill"
DRILL_VOLUME="openbao-drill-data"
# Port publié sur la BOUCLE LOCALE uniquement : une fois descellée, l'instance sert tous les
# secrets du homelab en clair.
DRILL_PORT="${DRILL_PORT:-127.0.0.1:8210}"
# `/openbao/file` et pas `/openbao/data` : le second n'existe pas dans l'image, et le créer par un
# volume le fait naître root alors que le processus tourne en uid 100.
DRILL_RAFT_PATH="/openbao/file"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/helm-values.yaml"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m ok \033[0m %s\n' "$*"; }
ko()   { printf '\033[31m KO \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  local code="${1:-1}"
  cat >&2 <<'EOF'
Gestion des sauvegardes openbao. Le coffre est la seule chose du homelab absente de Git : ici
« sauvegarde vérifiée » veut dire RESTAURÉE, pas « présente dans le bucket ».

  openbao-script.sh status
      État du coffre de prod, du CronJob, et âge de la dernière sauvegarde.

  openbao-script.sh list [motif]
      Snapshots du bucket (âge, taille) et Jobs de sauvegarde récents.

  openbao-script.sh snapshot
      Sauvegarde manuelle : Job dérivé du CronJob, même périmètre et même destination.

  openbao-script.sh fetch <réf> [-o fichier]
      Télécharge un snapshot dans le répertoire de travail (0700). C'est un SECRET.

  openbao-script.sh check <réf>
      Contrôle structurel hors ligne : archive, empreintes SHA256, méta raft. Aucun conteneur.

  openbao-script.sh verify <réf> [--unseal] [--keep]
      LE test réel. Remonte un OpenBao jetable en Docker et y restaure le snapshot, puis
      DÉTRUIT tout. Sans option : vérifie que l'instance adopte la config de seal de la
      prod (5/3). NE DEMANDE AUCUNE CLÉ. C'est le contrôle à automatiser.
          --unseal  va jusqu'au bout : descellement avec les parts de PROD (saisie masquée),
                    puis contrôle du contenu — chemins KV dérivés des ExternalSecret du
                    cluster, mounts d'auth, policies. Demande aussi le token root.
          --keep    laisse l'instance en vie à la fin (comme `up`).

  openbao-script.sh up <réf> [--unseal] [--replace]
      Même montage que `verify`, mais l'instance SURVIT à la commande. Pour fouiller un
      coffre d'hier sans toucher la prod. Conteneur au nom FIXE, UNE SEULE à la fois :
      remonter un autre snapshot exige `stop` (ou --replace).

  openbao-script.sh unseal
      Descelle après coup l'instance montée par `up` (saisie masquée).

  openbao-script.sh bao <args…>
      Passe-plat vers l'instance locale, jamais vers la prod.
      Ex. : openbao-script.sh bao kv get -mount=kv homelab/argocd

  openbao-script.sh stop
      Détruit l'instance locale et son volume. Après un `up`, un `--keep` ou un Ctrl-C.

  openbao-script.sh restore <réf> [--no-pre-snapshot]
      ⚠ RESTAURE LA PROD. Écrase l'intégralité du raft d'openbao-0. Prend d'abord un
      snapshot de sécurité de l'état courant, sauf --no-pre-snapshot.

Variables : OPENBAO_NAMESPACE (openbao) · OPENBAO_WORKDIR (~/.cache/openbao-drill)
            OPENBAO_IMAGE · TIMEOUT (900) · DRY_RUN=1 · NO_WAIT=1 · YES=1
Codes de sortie : 0 succès · 1 erreur · 2 succès avec réserve · 3 délai dépassé
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

# Confirmation par frappe exacte : un « y/n » se tape sans lire.
confirm() {
  local expected="$1" answer
  if [[ -n "${YES:-}" ]]; then
    log "YES=1 : confirmation passée."
    return 0
  fi
  [[ -t 0 ]] || die "Confirmation requise mais l'entrée standard n'est pas un terminal.
       Relancer avec YES=1 en connaissance de cause."
  printf 'Taper « %s » pour confirmer (autre chose annule) : ' "$expected"
  read -r answer
  [[ "$answer" == "$expected" ]] || die "Annulé — rien n'a été fait."
}

# `date` n'a pas la même interface sur macOS (BSD) et sur Linux (GNU) : les deux formes sont
# tentées, l'échec des deux vaut 0 (l'appelant affiche alors « - » plutôt que de planter).
epoch_of() {
  local ts="${1:-}"
  [[ -n "$ts" ]] || { echo 0; return; }
  date -u -d "$ts" +%s 2>/dev/null \
    || TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || echo 0
}

human_age() {
  local secs="${1:-0}"
  (( secs <= 0 )) && { printf '-'; return; }
  if   (( secs < 3600  )); then printf 'il y a %d min' $(( secs / 60 ))
  elif (( secs < 86400 )); then printf 'il y a %d h'   $(( secs / 3600 ))
  else                          printf 'il y a %d j'   $(( secs / 86400 )); fi
}

sha256_check() {
  # macOS fournit `shasum`, la plupart des Linux `sha256sum`. Même sémantique pour `-c`.
  if command -v sha256sum >/dev/null; then sha256sum -c "$@"
  else shasum -a 256 -c "$@"; fi
}

# Le bucket et l'horaire sont DÉRIVÉS de helm-values.yaml, jamais retapés : c'est ce fichier qui
# fait foi pour le CronJob, une constante ici divergerait au premier changement de bucket.
bucket_uri() {
  local uri
  [[ -f "$VALUES_FILE" ]] || die "helm-values.yaml introuvable ($VALUES_FILE) — lancer le script depuis le repo."
  uri="$(sed -n 's/^[[:space:]]*s3Uri:[[:space:]]*"\{0,1\}\([^"#[:space:]]*\).*/\1/p' "$VALUES_FILE" | head -1)"
  [[ -n "$uri" ]] || die "Clé 's3Uri' absente de $VALUES_FILE : impossible de savoir où sont les sauvegardes."
  # Le chart parle S3 (interopérabilité GCS), gsutil parle gs://. Même bucket.
  printf 'gs://%s' "${uri#s3://}"
}

cron_schedule() {
  sed -n 's/^[[:space:]]*schedule:[[:space:]]*"\{0,1\}\([^"#]*\)"\{0,1\}.*/\1/p' "$VALUES_FILE" | head -1
}

cluster_reachable() {
  kubectl -n "$NAMESPACE" get sts openbao >/dev/null 2>&1
}

# Même piège que côté instance jetable : `bao status` sort en 2 quand le coffre est SCELLÉ, ce qui
# est justement l'état qu'on cherche à détecter. Le JSON est capturé sans pipe.
prod_status_json() {
  kubectl -n "$NAMESPACE" exec openbao-0 -- bao status -format=json 2>/dev/null || true
}

# --- Résolution d'une référence de snapshot ----------------------------------------------------

# Liste brute du bucket : « <taille> <horodatage> <nom> », du plus ancien au plus récent.
bucket_objects() {
  local uri; uri="$(bucket_uri)"
  gsutil ls -l "$uri/" 2>/dev/null \
    | awk '$3 ~ /\.snapshot$/ { n = $3; sub(/^.*\//, "", n); print $1 "\t" $2 "\t" n }' \
    | sort -k2
}

# Rend le CHEMIN LOCAL du snapshot désigné. Un fichier existant est pris tel quel ; sinon la
# référence est cherchée dans le bucket et téléchargée si besoin.
#   `latest` = le plus récent, `oldest` = le plus ancien encore en rétention.
# `oldest` est le bon choix pour un contrôle périodique : il répond à « jusqu'où puis-je
# remonter », là où le plus récent ne teste que la nuit dernière.
resolve_ref() {
  local ref="$1" name
  if [[ -f "$ref" ]]; then
    printf '%s' "$ref"
    return 0
  fi
  case "$ref" in
    latest) name="$(bucket_objects | tail -1 | cut -f3)" ;;
    oldest) name="$(bucket_objects | head -1 | cut -f3)" ;;
    *)      name="$ref" ;;
  esac
  [[ -n "$name" ]] || die "Aucun snapshot dans $(bucket_uri) — la sauvegarde n'a jamais tourné ?"
  fetch_object "$name"
}

fetch_object() {
  local name="$1" dest
  mkdir -p "$WORKDIR"
  chmod 700 "$WORKDIR"
  dest="$WORKDIR/$name"
  if [[ -f "$dest" ]]; then
    printf '%s' "$dest"
    return 0
  fi
  gsutil cp "$(bucket_uri)/$name" "$dest" >/dev/null 2>&1 \
    || die "Téléchargement impossible : $(bucket_uri)/$name
       Lister les objets disponibles : $(basename "$0") list"
  chmod 600 "$dest"
  printf '%s' "$dest"
}

# --- status -----------------------------------------------------------------------------------

cmd_status() {
  local st sealed n t last_ts last_name age

  log "Coffre de prod ($NAMESPACE/openbao-0)"
  if ! cluster_reachable; then
    warn "Cluster injoignable — section ignorée."
  elif st="$(prod_status_json)" && [[ -n "$st" ]]; then
    sealed="$(jq -r '.sealed' <<<"$st")"
    n="$(jq -r '.n' <<<"$st")"; t="$(jq -r '.t' <<<"$st")"
    printf '    scellé        : %s\n' "$sealed"
    printf '    parts / seuil : %s / %s   ← ce que `verify` doit retrouver dans le snapshot\n' "$n" "$t"
    printf '    version       : %s   raft index : %s\n' \
      "$(jq -r '.version' <<<"$st")" "$(jq -r '.raft_applied_index // "-"' <<<"$st")"
    [[ "$sealed" == "false" ]] || warn "Coffre SCELLÉ : aucun secret ne se rafraîchit. Desceller (README, Opérations)."
  else
    # `bao status` sort en 2 quand le coffre est scellé : l'exec échoue alors sans que ce soit
    # une panne du cluster.
    warn "Statut illisible — coffre scellé ou pod indisponible : kubectl -n $NAMESPACE get pods"
  fi

  echo
  log "Sauvegarde automatique"
  if cluster_reachable; then
    kubectl -n "$NAMESPACE" get cronjob openbao-snapshot \
      -o custom-columns=NOM:.metadata.name,CRON:.spec.schedule,SUSPENDU:.spec.suspend,DERNIERE:.status.lastScheduleTime \
      2>/dev/null || warn "CronJob 'openbao-snapshot' absent : la sauvegarde ne tourne PAS."
  fi
  printf '    déclarée dans helm-values.yaml : %s → %s\n' "$(cron_schedule)" "$(bucket_uri)"

  echo
  read -r _ last_ts last_name < <(bucket_objects | tail -1 | tr '\t' ' ') || true
  if [[ -z "${last_name:-}" ]]; then
    ko "Aucun snapshot dans le bucket."
    exit 1
  fi
  age=$(( $(date -u +%s) - $(epoch_of "$last_ts") ))
  printf '    dernier snapshot : %s (%s)\n' "$last_name" "$(human_age "$age")"
  # Deux fois l'intervalle nominal : une exécution ratée est un incident, pas un retard.
  if (( age > 172800 )); then
    ko "Plus de 48 h sans sauvegarde — le CronJob ne tourne plus."
    exit 1
  elif (( age > 90000 )); then
    warn "Plus de 25 h sans sauvegarde : une exécution a été manquée."
  else
    ok "Sauvegarde à jour."
  fi
  echo "    Vérifier qu'elle est RESTAURABLE (aucune clé requise) : $(basename "$0") verify latest"

  # Une instance locale descellée contient tous les secrets du homelab en clair. Elle doit se voir
  # ici, sinon elle s'oublie — c'est le seul état de cette procédure qui traîne dans le temps.
  if command -v docker >/dev/null && drill_exists; then
    echo
    log "Instance locale"
    if drill_running; then
      printf '    conteneur     : %s (en cours, http://%s)\n' "$DRILL_NAME" "$DRILL_PORT"
      if drill_sealed; then
        printf '    état          : scellée — parts/seuil %s\n' "$(drill_seal_config)"
      else
        warn "DESCELLÉE : tous les secrets du homelab y sont lisibles en clair."
      fi
    else
      printf '    conteneur     : %s (arrêté)\n' "$DRILL_NAME"
    fi
    echo "    la détruire   : $(basename "$0") stop"
  fi
}

# --- list -------------------------------------------------------------------------------------

cmd_list() {
  local pattern="${1:-}" now
  now="$(date -u +%s)"

  log "Snapshots dans $(bucket_uri)${pattern:+ (motif « $pattern »)}"
  {
    printf 'NOM\tCREE\tAGE\tTAILLE\n'
    while IFS=$'\t' read -r size ts name; do
      [[ -z "$pattern" || "$name" == *"$pattern"* ]] || continue
      printf '%s\t%s\t%s\t%s Kio\n' "$name" "$ts" \
        "$(human_age $(( now - $(epoch_of "$ts") )))" "$(( size / 1024 ))"
    done < <(bucket_objects | sort -k2 -r)
  } | column -t -s $'\t'

  # Un snapshot ne devient une sauvegarde que le jour où on l'a restauré une fois.
  echo "    Aucun de ces fichiers n'est une sauvegarde tant qu'il n'a pas été restauré :"
  echo "      $(basename "$0") verify oldest"

  if cluster_reachable; then
    echo
    log "Jobs de sauvegarde"
    # Sélecteur `component=snapshot-agent` : c'est le label que le chart pose sur le jobTemplate,
    # donc aussi celui que porte un Job manuel créé par `--from=cronjob/…`.
    {
      printf 'NOM\tETAT\tDEBUT\tDUREE\n'
      kubectl -n "$NAMESPACE" get jobs -l component=snapshot-agent -o json 2>/dev/null | jq -r '
        .items
        | sort_by(.status.startTime) | reverse | .[:10] | .[]
        | ([.status.conditions[]? | select(.status == "True") | .type]) as $c
        | [ .metadata.name,
            # `SuccessCriteriaMet` est posée AVANT `Complete` et les deux restent vraies : prendre
            # la première venue afficherait un état intermédiaire sur un Job terminé.
            (if   ($c | index("Failed"))   then "Failed"
             elif ($c | index("Complete")) then "Complete"
             else ($c | first // "EnCours") end),
            (.status.startTime // "-"),
            (if .status.completionTime and .status.startTime
             then "\(((.status.completionTime | fromdateiso8601) - (.status.startTime | fromdateiso8601)))s"
             else "-" end) ]
        | @tsv'
    } | column -t -s $'\t'
    # Un Job vert ne prouve que l'appel s3cmd : c'est le tableau du bucket, au-dessus, qui dit si
    # l'objet est arrivé.
  fi
}

# --- snapshot ---------------------------------------------------------------------------------

cmd_snapshot() {
  cluster_reachable || die "Cluster injoignable : impossible de déclencher une sauvegarde."

  kubectl -n "$NAMESPACE" get cronjob openbao-snapshot >/dev/null 2>&1 \
    || die "CronJob 'openbao-snapshot' absent du namespace '$NAMESPACE'.
       Vérifier que snapshotAgent.enabled est bien à true dans helm-values.yaml."

  # Un coffre scellé n'a pas de nœud actif : `raft snapshot save` échouerait, et le Job
  # remonterait une erreur d'authentification peu parlante. Autant le dire tout de suite.
  local st
  st="$(prod_status_json)"
  [[ -z "$st" || "$(jq -r '.sealed' <<<"$st")" != "true" ]] \
    || die "Le coffre est SCELLÉ : aucune sauvegarde n'est possible. Desceller d'abord (README, Opérations)."

  local job="openbao-snapshot-manual-$(date -u +%Y%m%d-%H%M%S)"

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : commande qui serait lancée (rien n'est envoyé au cluster)"
    echo "  kubectl -n $NAMESPACE create job --from=cronjob/openbao-snapshot $job"
    exit 0
  fi

  # Job DÉRIVÉ du CronJob (`--from`) et non retapé : même image, même Secret de credentials, même
  # bucket, même rétention. Une spec écrite à la main ici pourrait pousser ailleurs sans qu'on le
  # voie — et une sauvegarde qui atterrit dans le mauvais bucket est une sauvegarde perdue.
  log "Sauvegarde manuelle dérivée du CronJob 'openbao-snapshot'"
  kubectl -n "$NAMESPACE" create job --from=cronjob/openbao-snapshot "$job" >/dev/null
  log "Job créé : $job"

  if [[ -n "${NO_WAIT:-}" ]]; then
    log "NO_WAIT : suivi laissé à l'appelant."
    echo "  kubectl -n $NAMESPACE logs job/$job"
    exit 0
  fi

  log "Suivi (Ctrl-C interrompt l'affichage, PAS le Job)…"
  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
    warn "Le Job n'a pas abouti dans le délai imparti. Logs :"
    kubectl -n "$NAMESPACE" logs "job/$job" 2>&1 | tail -20 >&2
    exit 3
  fi

  kubectl -n "$NAMESPACE" logs "job/$job" 2>&1 | tail -5

  # Le Job vert ne prouve que l'appel s3cmd. On va relire le bucket pour vérifier que l'objet
  # existe VRAIMENT et qu'il est récent — c'est le premier des quatre modes d'échec silencieux.
  local ts name age
  read -r _ ts name < <(bucket_objects | tail -1 | tr '\t' ' ') || true
  age=$(( $(date -u +%s) - $(epoch_of "${ts:-}") ))
  if [[ -n "${name:-}" ]] && (( age < 900 )); then
    ok "Objet déposé dans le bucket : $name ($(human_age "$age"))"
    echo "    Reste à prouver qu'il est restaurable : $(basename "$0") verify $name"
  else
    ko "Job terminé mais AUCUN objet récent dans $(bucket_uri) — l'upload n'a rien écrit."
    exit 2
  fi
}

# --- fetch ------------------------------------------------------------------------------------

cmd_fetch() {
  local ref="" out=""
  while (( $# )); do
    case "$1" in
      -o|--output) out="${2:-}"; [[ -n "$out" ]] || usage; shift 2 ;;
      -h|--help)   usage 0 ;;
      -*)          die "Option inconnue : $1" ;;
      *)           [[ -z "$ref" ]] || die "Un seul snapshot à la fois."; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || usage

  local path; path="$(resolve_ref "$ref")"
  if [[ -n "$out" ]]; then
    cp "$path" "$out"; chmod 600 "$out"; path="$out"
  fi
  log "Snapshot local : $path"
  warn "C'est un SECRET : tout le coffre, chiffré. Ne pas le laisser traîner, ne JAMAIS le poser
    dans le repo — le .gitignore filtre *.secret.yaml, pas *.snapshot."
}

# --- check ------------------------------------------------------------------------------------

# Contrôle hors ligne. Ne prouve pas que le coffre est restaurable (voir `verify`), mais écarte en
# deux secondes l'upload tronqué et l'archive corrompue.
cmd_check() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || usage
  require_bins tar jq

  local path; path="$(resolve_ref "$ref")"
  log "Contrôle structurel de $(basename "$path")"

  local size; size="$(wc -c <"$path" | tr -d ' ')"
  printf '    taille        : %s octets\n' "$size"
  (( size > 4096 )) || { ko "Archive trop petite pour contenir un coffre : upload tronqué."; exit 1; }

  tar tzf "$path" >/dev/null 2>&1 || { ko "Archive illisible (gzip/tar) : snapshot corrompu."; exit 1; }
  ok "Archive lisible."

  # Quatre entrées attendues. `SHA256SUMS.sealed` est l'empreinte scellée, vérifiée par OpenBao
  # lui-même au restore — on ne peut que constater sa présence ici.
  local entries missing=0 f
  entries="$(tar tzf "$path")"
  for f in meta.json state.bin SHA256SUMS SHA256SUMS.sealed; do
    if grep -qx "$f" <<<"$entries"; then ok "présent : $f"; else ko "MANQUANT : $f"; missing=1; fi
  done
  (( missing == 0 )) || { ko "Archive incomplète."; exit 1; }

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  tar xzf "$path" -C "$tmp"
  if ( cd "$tmp" && sha256_check SHA256SUMS >/dev/null 2>&1 ); then
    ok "Empreintes SHA256 conformes (meta.json, state.bin)."
  else
    ko "Empreinte SHA256 NON conforme : contenu altéré."
    exit 1
  fi

  log "Méta raft"
  jq -r '
    "    version raft  : \(.Version)",
    "    index / term  : \(.Index) / \(.Term)",
    "    taille état   : \(.Size) octets",
    "    pairs         : \([.Configuration.Servers[]? | .ID] | join(", "))"' "$tmp/meta.json"

  echo
  echo "    Contrôle structurel seulement. Ce qu'il ne dit PAS : si la barrière de chiffrement"
  echo "    est ouvrable. Pour ça : $(basename "$0") verify $(basename "$path")"
}

# --- Instance jetable -------------------------------------------------------------------------

drill_running() { docker inspect -f '{{.State.Running}}' "$DRILL_NAME" 2>/dev/null | grep -qx true; }
drill_exists()  { docker inspect "$DRILL_NAME" >/dev/null 2>&1; }

# Enveloppe `bao` dans l'instance jetable. $1.. = arguments de bao. Le token courant est passé par
# l'environnement (DRILL_TOKEN) et jamais en argument : la ligne de commande est lisible par tout
# processus de la machine, et l'historique du shell la conserve.
bao_drill() {
  docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${DRILL_TOKEN:-}" \
    "$DRILL_NAME" bao "$@"
}

drill_stop() {
  docker rm -f "$DRILL_NAME" >/dev/null 2>&1 || true
  docker volume rm "$DRILL_VOLUME" >/dev/null 2>&1 || true
}

drill_start() {
  local image="$1" snapdir="$2" cfg="$WORKDIR/drill-config.hcl"

  # UNE SEULE INSTANCE À LA FOIS, et le nom est fixe : c'est ce qui permet à `stop` de nettoyer
  # sans rien avoir à retenir, et ce qui évite qu'un `up` distrait écrase une instance déjà
  # descellée — celle où l'on est peut-être en train de chercher quelque chose. L'écrasement reste
  # possible, mais il faut le demander.
  if drill_exists; then
    [[ -n "${DRILL_REPLACE:-}" ]] || die "Une instance locale « $DRILL_NAME » existe déjà — une seule à la fois.
       L'inspecter : $(basename "$0") status
       La détruire : $(basename "$0") stop
       L'écraser   : rappeler la même commande avec --replace"
    warn "--replace : l'instance existante et son volume sont détruits."
  fi
  # Inconditionnel : rattrape aussi un volume resté seul après un `docker rm` fait à la main.
  drill_stop
  mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"

  # Trois pièges encapsulés ici, chacun documenté en tête de fichier :
  #   - `disable_mlock` ABSENT : le champ n'existe plus en 2.6.x (« unknown or unsupported field »).
  #   - `path` = /openbao/file : /openbao/data n'existe pas dans l'image.
  #   - le fichier est monté hors de /openbao/config, sans quoi l'entrypoint le déclare en double
  #     et l'ignore.
  cat >"$cfg" <<EOF
# UI servie sur le port du listener. Sans cette ligne, /ui rend 404 — et l'UI est justement ce
# qu'on veut après un \`up\` : parcourir un coffre d'hier au clic plutôt qu'en \`bao kv get\`.
# Aucun risque d'exposition : DRILL_PORT publie sur 127.0.0.1 uniquement.
ui = true

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

listener "tcp" {
  address     = "[::]:8200"
  tls_disable = 1
}

storage "raft" {
  path    = "$DRILL_RAFT_PATH"
  node_id = "restore-test"
}
EOF

  docker volume create "$DRILL_VOLUME" >/dev/null
  docker run -d --name "$DRILL_NAME" -p "$DRILL_PORT:8200" \
    -v "$cfg:/etc/openbao/config.hcl:ro" \
    -v "$snapdir:/snap:ro" \
    -v "$DRILL_VOLUME:$DRILL_RAFT_PATH" \
    "$image" server -config=/etc/openbao/config.hcl >/dev/null \
    || die "Le conteneur n'a pas démarré. Docker tourne-t-il ?"

  drill_wait_ready
}

# `bao status` sort en 0 (descellé), 2 (SCELLÉ) et 1 (injoignable) — et un coffre qui vient d'être
# restauré est scellé par construction. Sous `set -euo pipefail`, brancher un `| jq` directement
# sur cette commande fait donc échouer le script AU MOMENT PRÉCIS où le test réussit. Le JSON est
# capturé à part, et l'absence de réponse rend « ?/? » plutôt que d'interrompre.
drill_status_json() {
  docker exec "$DRILL_NAME" env BAO_ADDR=http://127.0.0.1:8200 bao status -format=json 2>/dev/null || true
}

drill_seal_config() {
  local json; json="$(drill_status_json)"
  [[ -n "$json" ]] || { printf '?/?'; return 0; }
  jq -r '"\(.n)/\(.t)"' <<<"$json" 2>/dev/null || printf '?/?'
}

drill_sealed() {
  local json; json="$(drill_status_json)"
  [[ -n "$json" ]] || return 0
  [[ "$(jq -r '.sealed' <<<"$json" 2>/dev/null)" == "true" ]]
}

# Attend que l'API réponde. `bao status` sort en 0 (descellé), 2 (scellé) ou 1 (injoignable) :
# c'est le 1 qui signifie « pas encore prêt », pas les autres.
drill_wait_ready() {
  local deadline=$(( SECONDS + 60 )) rc
  while :; do
    rc=0; docker exec "$DRILL_NAME" env BAO_ADDR=http://127.0.0.1:8200 bao status >/dev/null 2>&1 || rc=$?
    (( rc != 1 )) && return 0
    if (( SECONDS >= deadline )); then
      docker logs "$DRILL_NAME" 2>&1 | tail -20 >&2
      die "L'instance jetable ne répond pas après 60 s."
    fi
    sleep 2
  done
}

# INDISPENSABLE APRÈS UN RESTORE, et c'est le piège le moins documenté de toute la procédure : le
# processus garde EN MÉMOIRE la configuration de seal avec laquelle il a démarré. Après un
# `snapshot restore` réussi, `bao status` continue donc d'annoncer les 1/1 de l'instance jetable
# alors que le stockage porte déjà les 5/3 du coffre source — on croit le restore inopérant alors
# qu'il a parfaitement fonctionné (les logs, eux, disent « restored user snapshot »). Seul un
# redémarrage du processus fait relire la valeur au stockage. C'est aussi ce que fait la vraie
# procédure de reprise, où le pod redémarre avant d'être descellé.
drill_restart() {
  docker restart "$DRILL_NAME" >/dev/null
  drill_wait_ready
}

# --- Montage local d'un snapshot (socle de `verify` et de `up`) --------------------------------

# Image et configuration de seal ATTENDUE, prises sur la prod. Renseigne les globales DRILL_IMAGE,
# DRILL_EXPECT et DRILL_PROD_OK. Sans cluster joignable, le montage reste possible mais plus rien
# ne permet de CONCLURE : l'appelant sort alors en 2 plutôt que d'annoncer une vérification.
# Garde-fou d'instance unique, appelé AVANT tout travail : sans lui, un second `up` télécharge un
# snapshot (donc pose un secret sur le disque) et démarre un conteneur avant de découvrir qu'il
# doit renoncer.
drill_guard_single() {
  drill_exists || return 0
  [[ -n "${DRILL_REPLACE:-}" ]] && return 0
  die "Une instance locale « $DRILL_NAME » existe déjà — une seule à la fois.
       L'inspecter : $(basename "$0") status
       La détruire : $(basename "$0") stop
       L'écraser   : rappeler la même commande avec --replace"
}

DRILL_IMAGE=""; DRILL_EXPECT=""; DRILL_PROD_OK=0
drill_reference() {
  local st=""
  DRILL_IMAGE=""; DRILL_EXPECT=""; DRILL_PROD_OK=0
  if cluster_reachable; then
    st="$(prod_status_json)"
    DRILL_IMAGE="$(kubectl -n "$NAMESPACE" get sts openbao -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [[ -n "$st" ]] && DRILL_EXPECT="$(jq -r '"\(.n)/\(.t)"' <<<"$st" 2>/dev/null || true)"
    [[ -n "$DRILL_EXPECT" && "$DRILL_EXPECT" != "null/null" ]] && DRILL_PROD_OK=1
  fi
  DRILL_IMAGE="${OPENBAO_IMAGE:-${DRILL_IMAGE:-quay.io/openbao/openbao:2.6.1}}"
  (( DRILL_PROD_OK )) || warn "Configuration de seal de la prod illisible : la comparaison sera indicative."
}

# Monte le snapshot dans l'instance locale et rend le verdict de barrière. Renseigne DRILL_BEFORE
# et DRILL_AFTER. Sort en échec si le snapshot n'a pas été chargé : tout ce qui suit (descellement,
# lecture) n'aurait alors aucun sens.
DRILL_BEFORE=""; DRILL_AFTER=""
drill_mount_snapshot() {
  local path="$1"
  local snapdir; snapdir="$(cd -- "$(dirname -- "$path")" && pwd)"
  local snapfile; snapfile="$(basename "$path")"

  log "Instance locale ($DRILL_IMAGE) — la prod n'est pas touchée"
  drill_start "$DRILL_IMAGE" "$snapdir"

  # --- Init jetable. On ne restaure pas dans un coffre non initialisé. Ces clés meurent au
  # restore : une seule part suffit, et elle n'est jamais écrite sur disque.
  local init
  init="$(bao_drill operator init -key-shares=1 -key-threshold=1 -format=json)"
  bao_drill operator unseal "$(jq -r '.unseal_keys_b64[0]' <<<"$init")" >/dev/null
  DRILL_TOKEN="$(jq -r '.root_token' <<<"$init")"
  DRILL_BEFORE="$(drill_seal_config)"
  log "Instance initialisée avec des clés jetables — parts/seuil : $DRILL_BEFORE"

  # --- Restore. `-force` est OBLIGATOIRE : la config de seal du snapshot diffère forcément de
  # celle qu'on vient de créer. Le message « Error properly closing policy file » est cosmétique
  # et sort même quand tout s'est bien passé — d'où la vérification par le status, jamais par la
  # sortie de la commande.
  # Accolades obligatoires : bash 5.x accepte les octets multi-octets dans un nom de variable, et
  # « $snapfile… » se lit alors comme une variable nommée « snapfile… », donc vide.
  log "Restauration de ${snapfile}…"
  # Sortie CAPTURÉE, pas branchée sur un pipe : le code de retour de `bao` doit rester lisible, et
  # un `| grep` le remplacerait par celui de grep. Seule la ligne cosmétique est filtrée à
  # l'affichage — et uniquement elle, pour qu'une VRAIE erreur reste visible.
  local out rc=0
  out="$(bao_drill operator raft snapshot restore -force "/snap/$snapfile" 2>&1)" || rc=$?
  grep -v 'Error properly closing policy file' <<<"$out" | grep -v '^$' || true
  (( rc == 0 )) || { ko "Le restore a échoué (code $rc)."; exit 1; }

  # Voir drill_restart : sans ce redémarrage, la mesure suivante lit une valeur périmée.
  log "Redémarrage de l'instance (obligatoire pour relire la configuration de seal restaurée)…"
  drill_restart
  DRILL_AFTER="$(drill_seal_config)"

  echo
  log "Résultat"
  printf '    parts/seuil avant restore : %s (instance jetable)\n' "$DRILL_BEFORE"
  printf '    parts/seuil après restore : %s\n' "$DRILL_AFTER"
  (( DRILL_PROD_OK )) && printf '    parts/seuil de la prod    : %s\n' "$DRILL_EXPECT"

  if [[ "$DRILL_AFTER" == "$DRILL_BEFORE" ]]; then
    ko "La configuration de seal n'a pas changé : le restore n'a RIEN fait."
    ko "Le snapshot n'a pas été chargé — sauvegarde inexploitable."
    exit 1
  fi

  if (( DRILL_PROD_OK )); then
    if [[ "$DRILL_AFTER" == "$DRILL_EXPECT" ]]; then
      ok "L'instance a adopté la configuration de seal de la prod : le keyring du snapshot a été"
      ok "ouvert et vérifié. state.bin est intègre et le coffre est restaurable."
    else
      ko "Configuration de seal inattendue ($DRILL_AFTER au lieu de $DRILL_EXPECT)."
      ko "Le snapshot vient d'un autre coffre, ou les clés de la prod ont été régénérées depuis."
      exit 1
    fi
  else
    ok "Le keyring du snapshot a été chargé (parts/seuil modifiés)."
    warn "Comparaison avec la prod impossible : contrôle partiel."
  fi
}

# Descellement interactif de l'instance locale, avec les parts du coffre SOURCE. Saisie masquée et
# jamais en argument : un `bao operator unseal <part>` sur la ligne de commande finit dans
# l'historique du shell et dans la table des processus.
drill_unseal_interactive() {
  local threshold="$1" i part
  [[ -t 0 ]] || die "Descellement interactif impossible : l'entrée standard n'est pas un terminal."

  log "Descellement — $threshold parts attendues (saisie masquée, rien n'est écrit sur disque)"
  for (( i = 1; i <= threshold; i++ )); do
    printf '    part %d/%s : ' "$i" "$threshold"
    read -r -s part; echo
    [[ -n "$part" ]] || die "Part vide — abandon."
    bao_drill operator unseal "$part" >/dev/null 2>&1 \
      || die "Part refusée. Si c'est la bonne, la sauvegarde et tes clés ne correspondent plus :
       le contenu du snapshot est alors DÉFINITIVEMENT illisible — c'est un incident."
  done
  unset part

  if drill_sealed; then
    ko "Toujours scellé après $threshold parts."
    exit 1
  fi
  ok "Coffre DESCELLÉ."
}

# Demande le token root du coffre RESTAURÉ (celui de la prod, pas celui de l'instance jetable :
# le restore a remplacé la barrière, donc aussi les identités).
drill_ask_token() {
  [[ -t 0 ]] || die "Token requis mais l'entrée standard n'est pas un terminal."
  printf '    token root du coffre restauré : '
  read -r -s DRILL_TOKEN; echo
  [[ -n "$DRILL_TOKEN" ]] || die "Token vide — abandon."
  bao_drill token lookup >/dev/null 2>&1 || die "Token refusé par le coffre restauré."
  ok "Token accepté."
}

# Rappel d'usage d'une instance laissée en vie. Toujours affiché au même endroit : c'est le seul
# moment où l'on sait si elle est scellée ou non.
drill_hints() {
  local self; self="$(basename "$0")"
  echo
  log "Instance locale « $DRILL_NAME » LAISSÉE EN VIE"
  printf '    API           : http://%s\n' "$DRILL_PORT"
  printf '    UI            : http://%s/ui\n' "$DRILL_PORT"
  if drill_sealed; then
    printf '    état          : SCELLÉE — %s parts nécessaires\n' "${DRILL_AFTER#*/}"
    echo   "    desceller     : $self unseal"
  else
    printf '    état          : descellée\n'
  fi
  echo   "    interroger    : $self bao kv list -mount=kv homelab"
  echo   "    détruire      : $self stop"
  warn "Une fois descellée, elle sert TOUS les secrets du homelab en clair. Ne pas l'oublier."
}

# --- verify -----------------------------------------------------------------------------------

cmd_verify() {
  local ref="" do_unseal=0 keep=0
  while (( $# )); do
    case "$1" in
      --unseal)  do_unseal=1; shift ;;
      --keep)    keep=1; shift ;;
      --replace) DRILL_REPLACE=1; shift ;;
      -h|--help) usage 0 ;;
      -*)        die "Option inconnue : $1" ;;
      *)         [[ -z "$ref" ]] || die "Un seul snapshot à la fois."; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || usage
  require_bins docker tar jq
  drill_guard_single

  local path; path="$(resolve_ref "$ref")"
  drill_reference

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : ce qui serait fait (rien n'est lancé)"
    printf '  snapshot : %s\n  image    : %s\n  attendu  : %s\n' "$path" "$DRILL_IMAGE" "${DRILL_EXPECT:-?}"
    exit 0
  fi

  # `verify` est un TEST : il ne laisse rien derrière lui, sauf demande explicite. C'est la
  # différence de contrat avec `up`, qui lui garde l'instance.
  (( keep )) || trap drill_stop EXIT

  drill_mount_snapshot "$path"

  if (( ! do_unseal )); then
    echo
    echo "    Test sans clé terminé. Pour aller jusqu'au contenu (parts + token root) :"
    echo "      $(basename "$0") verify $ref --unseal"
    echo "    Pour garder une instance locale interrogeable :"
    echo "      $(basename "$0") up $ref --unseal"
    (( keep )) && drill_hints
    (( DRILL_PROD_OK )) || exit 2
    return 0
  fi

  echo
  drill_unseal_interactive "${DRILL_AFTER#*/}"
  drill_ask_token
  verify_contents
  (( keep )) && drill_hints
  return 0
}

# --- up ---------------------------------------------------------------------------------------

# Même socle que `verify`, contrat inverse : l'instance SURVIT à la commande. Sert à fouiller un
# coffre d'hier — comparer une valeur, récupérer un secret perdu, vérifier ce qui a changé — sans
# jamais toucher à la prod. Nom de conteneur FIXE et instance unique : `stop` sait quoi détruire,
# et on ne se retrouve pas avec trois coffres locaux dont on ne sait plus lequel contient quoi.
cmd_up() {
  local ref="" do_unseal=0
  while (( $# )); do
    case "$1" in
      --unseal)  do_unseal=1; shift ;;
      --replace) DRILL_REPLACE=1; shift ;;
      -h|--help) usage 0 ;;
      -*)        die "Option inconnue : $1" ;;
      *)         [[ -z "$ref" ]] || die "Un seul snapshot à la fois."; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || usage
  require_bins docker tar jq
  drill_guard_single

  local path; path="$(resolve_ref "$ref")"
  drill_reference

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : ce qui serait fait (rien n'est lancé)"
    printf '  snapshot  : %s\n  image     : %s\n  conteneur : %s sur %s\n' \
      "$path" "$DRILL_IMAGE" "$DRILL_NAME" "$DRILL_PORT"
    exit 0
  fi

  # Pas de `trap drill_stop` ici, c'est tout l'intérêt. En contrepartie, une interruption au
  # milieu laisse un conteneur à moitié monté : `stop` le rattrape, et le garde-fou d'instance
  # unique force à passer par lui.
  drill_mount_snapshot "$path"

  if (( do_unseal )); then
    echo
    drill_unseal_interactive "${DRILL_AFTER#*/}"
    drill_ask_token
  fi

  drill_hints
}

# --- unseal -----------------------------------------------------------------------------------

# Desceller APRÈS COUP une instance montée par `up`. Existe parce qu'un `up` sans `--unseal` est le
# bon réflexe (on monte d'abord, on décide ensuite si on sort les parts du coffre physique).
cmd_unseal() {
  require_bins docker jq
  drill_running || die "Aucune instance locale en cours. La monter : $(basename "$0") up latest"

  if ! drill_sealed; then
    log "L'instance locale est déjà descellée."
    return 0
  fi
  DRILL_AFTER="$(drill_seal_config)"
  drill_unseal_interactive "${DRILL_AFTER#*/}"
  drill_hints
}

# --- bao --------------------------------------------------------------------------------------

# Passe-plat vers l'instance locale : `openbao-script.sh bao kv get -mount=kv homelab/argocd`.
# Évite de retaper `docker exec -e BAO_ADDR=… openbao-drill bao …` à chaque fois, et surtout évite
# de le retaper DE TRAVERS vers le coffre de prod.
cmd_bao() {
  require_bins docker
  (( $# )) || die "Rien à exécuter. Exemple : $(basename "$0") bao kv list -mount=kv homelab"
  drill_running || die "Aucune instance locale en cours. La monter : $(basename "$0") up latest"

  if drill_sealed; then
    warn "Instance SCELLÉE : la plupart des commandes vont échouer. Desceller : $(basename "$0") unseal"
  fi
  # -ti seulement si l'on est sur un terminal, sinon `docker exec` refuse.
  local tty=(); [[ -t 0 && -t 1 ]] && tty=(-ti)
  # Le token n'est PAS conservé entre deux appels : chaque invocation le redemande si nécessaire.
  # C'est volontaire — un token root de prod ne se stocke pas dans un fichier de session.
  docker exec "${tty[@]}" -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${BAO_TOKEN:-}" \
    "$DRILL_NAME" bao "$@"
}

# Contrôle du contenu. La liste des chemins n'est PAS écrite ici : elle est dérivée des
# `ExternalSecret` du cluster et du `ClusterSecretStore` qui les sert. Une liste retapée diverge —
# celle du README d'openbao a divergé sur trois entrées, et un contrôle qui lit les mauvais
# chemins échoue en annonçant un faux problème.
verify_contents() {
  local fails=0

  echo
  log "Moteurs et mounts d'auth"
  bao_drill secrets list -format=json 2>/dev/null | jq -r 'to_entries[] | "    \(.key)\t\(.value.type)"' | column -t -s $'\t'
  bao_drill auth    list -format=json 2>/dev/null | jq -r 'to_entries[] | "    \(.key)\t\(.value.type)"' | column -t -s $'\t'

  if ! cluster_reachable; then
    warn "Cluster injoignable : le contrat ESO ne peut pas être dérivé, contrôle du contenu limité."
    return 0
  fi

  # --- Contrat dérivé du ClusterSecretStore (mount KV, mount d'auth, role) …
  local store mount authmount role
  store="$(kubectl get clustersecretstore openbao -o json 2>/dev/null || echo '{}')"
  mount="$(jq -r '.spec.provider.vault.path // "kv"' <<<"$store")"
  authmount="$(jq -r '.spec.provider.vault.auth.kubernetes.mountPath // ""' <<<"$store")"
  role="$(jq -r '.spec.provider.vault.auth.kubernetes.role // ""' <<<"$store")"

  echo
  log "Contrat attendu par external-secrets (dérivé du cluster, pas du README)"
  if [[ -n "$authmount" && -n "$role" ]]; then
    if bao_drill read "auth/$authmount/role/$role" >/dev/null 2>&1; then
      ok "role $role sur le mount $authmount"
    else
      ko "role $role ABSENT du mount $authmount — les ExternalSecret repartiraient en permission denied"
      fails=$(( fails + 1 ))
    fi
  else
    warn "ClusterSecretStore 'openbao' illisible : mount d'auth non vérifié."
  fi

  # … et les chemins KV, dérivés des ExternalSecret eux-mêmes, avec la CLÉ attendue dans chacun.
  local pairs
  pairs="$(kubectl get externalsecrets -A -o json 2>/dev/null | jq -r '
    [ .items[]
      | select(.spec.secretStoreRef.name == "openbao")
      | .spec.data[]?
      | "\(.remoteRef.key)\t\(.remoteRef.property // "")" ]
    | unique | .[]')"

  if [[ -z "$pairs" ]]; then
    warn "Aucun ExternalSecret ne pointe sur le store 'openbao' : contenu KV non vérifié."
    return 0
  fi

  echo
  log "Chemins KV servis aux applications (mount « $mount »)"
  local key prop data
  while IFS=$'\t' read -r key prop; do
    [[ -n "$key" ]] || continue
    if ! data="$(bao_drill kv get -mount="$mount" -format=json "$key" 2>/dev/null)"; then
      ko "$key — ABSENT du coffre restauré"
      fails=$(( fails + 1 )); continue
    fi
    if [[ -z "$prop" ]]; then
      ok "$key ($(jq -r '.data.data | keys | length' <<<"$data") clés)"
    elif jq -e --arg p "$prop" '.data.data | has($p)' <<<"$data" >/dev/null; then
      ok "$key → $prop"
    else
      ko "$key — la clé « $prop » manque (présentes : $(jq -r '.data.data | keys | join(", ")' <<<"$data"))"
      fails=$(( fails + 1 ))
    fi
  done <<<"$pairs"

  echo
  if (( fails == 0 )); then
    ok "Sauvegarde VÉRIFIÉE de bout en bout : archive, barrière, parts, contenu et contrat ESO."
  else
    ko "$fails contrôle(s) en échec — la sauvegarde est restaurable mais INCOMPLÈTE."
    exit 2
  fi
}

# --- stop -------------------------------------------------------------------------------------

cmd_stop() {
  require_bins docker
  if drill_exists; then
    # Pas de confirmation : détruire cette instance est l'opération SÛRE. Ce qu'elle contient est
    # une copie d'un snapshot qui, lui, est toujours dans le bucket — remontable en une commande.
    drill_stop
    log "Instance locale « $DRILL_NAME » détruite (conteneur + volume)."
  else
    log "Aucune instance locale en cours."
  fi
  # Le volume survit au conteneur et contient l'état restauré : le rappeler même quand il n'y a
  # rien à faire, parce que c'est exactement l'oubli qui laisse traîner tous les secrets.
  if [[ -d "$WORKDIR" ]]; then
    warn "Snapshots téléchargés encore présents dans $WORKDIR — ce sont des secrets :"
    warn "    rm -rf $WORKDIR"
  fi
}

# --- restore ----------------------------------------------------------------------------------

cmd_restore() {
  local ref="" pre=1
  while (( $# )); do
    case "$1" in
      --no-pre-snapshot) pre=0; shift ;;
      -h|--help)         usage 0 ;;
      -*)                die "Option inconnue : $1" ;;
      *)                 [[ -z "$ref" ]] || die "Un seul snapshot à la fois."; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || usage
  cluster_reachable || die "Cluster injoignable."

  local path; path="$(resolve_ref "$ref")"
  local snapfile; snapfile="$(basename "$path")"

  # Restaurer une archive qu'on n'a pas contrôlée, c'est écraser un coffre vivant par un fichier
  # dont on ne sait rien. Le contrôle structurel est bon marché : il est imposé.
  # Sous-shell plutôt que « $0 check » : le script peut être appelé par un chemin relatif depuis
  # n'importe où, et les `exit` de cmd_check ne doivent pas emporter la restauration.
  log "Contrôle préalable de l'archive"
  ( cmd_check "$path" ) >/dev/null \
    || die "L'archive n'a pas passé le contrôle structurel — restauration refusée.
       Détail : $(basename "$0") check $path"
  ok "Archive saine."

  if [[ -n "${DRY_RUN:-}" ]]; then
    log "DRY_RUN : commandes qui seraient lancées (rien n'est envoyé au cluster)"
    echo "  kubectl -n $NAMESPACE cp $path openbao-0:/tmp/$snapfile"
    echo "  <token sur stdin> | kubectl -n $NAMESPACE exec -i openbao-0 -- sh -c 'BAO_TOKEN=\$(cat); export BAO_TOKEN;"
    echo "      bao operator raft snapshot restore -force /tmp/$snapfile'"
    echo "  kubectl -n $NAMESPACE exec openbao-0 -- rm -f /tmp/$snapfile"
    exit 0
  fi

  echo
  warn "RESTAURATION DE LA PRODUCTION"
  warn "    L'intégralité du raft d'openbao-0 va être ÉCRASÉE par $snapfile."
  warn "    Tout secret écrit depuis ce snapshot sera perdu."
  warn "    Le coffre se rescellera : prévoir les parts de descellement AVANT de continuer."
  echo

  # Filet : l'état courant part au bucket avant d'être écrasé. C'est la seule protection contre un
  # mauvais choix de snapshot, et elle ne coûte que quelques secondes.
  if (( pre )); then
    log "Snapshot de sécurité de l'état COURANT avant écrasement"
    ( YES=1 cmd_snapshot ) || die "Le snapshot de sécurité a échoué — restauration annulée.
       Forcer sans filet : --no-pre-snapshot (en connaissance de cause)."
  else
    warn "--no-pre-snapshot : l'état courant ne sera PAS sauvegardé avant écrasement."
  fi

  confirm "$snapfile"

  # Le restore est une écriture privilégiée : il faut un token. Saisie masquée, jamais en argument.
  local token
  if [[ -n "${BAO_TOKEN:-}" ]]; then
    token="$BAO_TOKEN"
  else
    [[ -t 0 ]] || die "Token requis : renseigner BAO_TOKEN ou lancer depuis un terminal."
    printf '    token root de prod : '
    read -r -s token; echo
  fi
  [[ -n "$token" ]] || die "Token vide — abandon."

  kubectl -n "$NAMESPACE" cp "$path" "openbao-0:/tmp/$snapfile"

  # Le token passe par l'ENTRÉE STANDARD, pas par `env BAO_TOKEN=…` : un argument de commande est
  # lisible dans la table des processus du pod par tout ce qui tourne à côté.
  local out rc=0
  out="$(printf '%s' "$token" | kubectl -n "$NAMESPACE" exec -i openbao-0 -- \
    sh -c 'BAO_TOKEN=$(cat); export BAO_TOKEN; bao operator raft snapshot restore -force "$1"' \
    _ "/tmp/$snapfile" 2>&1)" || rc=$?
  grep -v 'Error properly closing policy file' <<<"$out" | grep -v '^$' || true
  kubectl -n "$NAMESPACE" exec openbao-0 -- rm -f "/tmp/$snapfile" >/dev/null 2>&1 || true
  (( rc == 0 )) || die "La restauration a échoué (code $rc) — le coffre peut être dans un état intermédiaire.
       Logs : kubectl -n $NAMESPACE logs openbao-0"

  sleep 3
  log "État du coffre après restauration"
  kubectl -n "$NAMESPACE" exec openbao-0 -- bao status 2>&1 | head -8 || true

  echo
  warn "Le coffre est SCELLÉ : il faut le desceller avec les parts correspondant à CE snapshot."
  echo "  kubectl -n $NAMESPACE exec -ti openbao-0 -- bao operator unseal   # à répéter"
  echo "Puis vérifier que les ExternalSecret repartent :"
  echo "  kubectl get externalsecrets -A"
}

# --- Aiguillage -------------------------------------------------------------------------------

require_bins kubectl jq gsutil

case "${1:-}" in
  status)   shift; cmd_status "$@" ;;
  list)     shift; cmd_list "$@" ;;
  snapshot) shift; cmd_snapshot "$@" ;;
  fetch)    shift; cmd_fetch "$@" ;;
  check)    shift; cmd_check "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  up)       shift; cmd_up "$@" ;;
  unseal)   shift; cmd_unseal "$@" ;;
  bao)      shift; cmd_bao "$@" ;;
  stop)     shift; cmd_stop "$@" ;;
  restore)  shift; cmd_restore "$@" ;;
  -h|--help|help) usage 0 ;;
  '')             usage 1 ;;
  *)        die "Commande inconnue : « $1 ». Voir : $(basename "$0") --help" ;;
esac
