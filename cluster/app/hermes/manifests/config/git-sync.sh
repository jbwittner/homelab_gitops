#!/bin/sh
# Boucle du sidecar `git-sync` : une passe de commit + push par jour des artefacts durables de
# $HERMES_HOME vers https://forgejo.wittner.tech/jbwittner/homelab_hermes.
#
# Semé depuis Git par le ConfigMap `hermes-bootstrap` (cf. kustomization.yaml), monté en
# /bootstrap/git-sync.sh. Modifier ce fichier déclenche un rollout du StatefulSet.
#
# Ce script ne fait QUE pousser. Il ne crée pas le dépôt, ne pose pas le remote, n'écrit pas le
# .gitignore et ne restaure RIEN : l'init de /opt/data est une opération manuelle, faite une fois
# (README §Versionnement). Un `reset --hard` automatique au démarrage a déjà écrasé un fichier
# d'un PVC vivant le 2026-09-25 — ce composant ne réécrit plus jamais le PVC.
#
# CE N'EST PAS UN BACKUP. Velero sauvegarde déjà le PVC entier (kopia → GCS, 03:00 UTC, TTL 30 j).
# Ce dépôt ne porte que ce que le .gitignore laisse passer : notes, skills, workspace, config.yaml,
# mémoires. Sa valeur est l'historique lisible et la restauration sélective, pas la reprise.
#
# ⚠️ CE SCRIPT NE DOIT JAMAIS SORTIR EN ERREUR. Le pod n'est `Ready` que si TOUS ses conteneurs le
# sont : un sidecar en CrashLoopBackOff rendrait hermes-0 `NotReady` et masquerait la santé réelle
# de la gateway. D'où l'absence de `set -e` — chaque échec se log et la boucle continue.
#
# Usage : sh /bootstrap/git-sync.sh           # boucle (mode normal du sidecar)
#         sh /bootstrap/git-sync.sh --once    # une seule passe, puis sortie (diagnostic)

set -u

REPO="${HERMES_HOME:-/opt/data}"
BRANCH="${GIT_SYNC_BRANCH:-main}"
SYNC_HOUR="${GIT_SYNC_HOUR:-4}"
SYNC_MINUTE="${GIT_SYNC_MINUTE:-30}"

# Seconde barrière, DERRIÈRE le .gitignore et indépendante de lui : le .gitignore vit dans le dépôt
# qu'il protège, l'agent peut donc le modifier entre deux rollouts. Ces chemins-là ne partent pas,
# quoi qu'il arrive au .gitignore.
FORBIDDEN='(^|/)(\.env($|\.)|auth\.json$|\.secrets/|[^/]*\.key$|[^/]*\.pem$)'

log() { echo "[git-sync] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# `-C` plutôt qu'un `cd`, et `safe.directory` parce que le dépôt appartient à l'uid 10000 : sans lui
# git refuse d'opérer avec « detected dubious ownership ».
git_() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

# Le jeton passe par GIT_ASKPASS et jamais par l'URL du remote ni par la ligne de commande : il ne
# se retrouve donc ni dans .git/config (qui vit dans le PVC, lisible par l'agent), ni dans
# /proc/*/cmdline, ni dans les logs d'erreur de git.
setup_credentials() {
  umask 077
  cat > /tmp/git-askpass.sh <<'EOF'
#!/bin/sh
case "$1" in
  Username*) printf '%s\n' "${GIT_SYNC_USER:-hermes_agent}" ;;
  Password*) printf '%s\n' "${FORGEJO_TOKEN:-}" ;;
esac
EOF
  chmod 0700 /tmp/git-askpass.sh
  export GIT_ASKPASS=/tmp/git-askpass.sh
  # Sans ça, un jeton invalide fait attendre git sur un prompt au lieu d'échouer.
  export GIT_TERMINAL_PROMPT=0
}

sync_once() {
  if [ ! -d "$REPO/.git" ]; then
    log "ERREUR: $REPO/.git absent — l'init manuel n'a jamais été fait (README §Versionnement)"
    return 1
  fi

  # L'agent lance ses propres commandes git dans CE dépôt depuis son outil terminal. Un index.lock
  # concurrent n'est pas une anomalie, juste une collision : on laisse passer et on retente.
  if [ -f "$REPO/.git/index.lock" ]; then
    log "index.lock présent (opération git concurrente de l'agent), attente 60 s"
    sleep 60
    if [ -f "$REPO/.git/index.lock" ]; then
      log "ERREUR: index.lock toujours présent, passe abandonnée"
      return 1
    fi
  fi

  # README.md est exclu du staging : c'est la présentation du dépôt, écrite à la main, et Hermes
  # travaille dans ce même répertoire. Le .gitignore ne suffirait pas — il n'a aucun effet sur un
  # fichier déjà suivi, et README.md l'est depuis le commit initial. L'exclusion couvre aussi la
  # suppression : si l'agent efface le fichier, la suppression n'est pas enregistrée.
  if ! git_ add -A -- . ':(exclude)README.md'; then
    log "ERREUR: git add a échoué"
    git_ reset -q >/dev/null 2>&1
    return 1
  fi

  staged=$(git_ diff --cached --name-only)
  if [ -z "$staged" ]; then
    # On ne sort PAS ici : un push a pu échouer la veille et laisser des commits locaux en
    # attente. La passe se poursuit jusqu'à l'étape de push, qui est un no-op si tout est à jour.
    log "rien de nouveau à commiter"
  else
    leaked=$(printf '%s\n' "$staged" | grep -E "$FORBIDDEN")
    if [ -n "$leaked" ]; then
      log "REFUS: chemins interdits dans l'index, rien n'est commité ni poussé :"
      printf '%s\n' "$leaked" | sed 's/^/[git-sync]   /'
      log "REFUS: vérifier le .gitignore de $REPO contre config/gitignore dans homelab_gitops"
      git_ reset -q
      return 1
    fi

    if ! git_ commit -q -m "chore: sync durable artifacts ($(date -u +%Y-%m-%dT%H:%MZ))"; then
      log "ERREUR: commit refusé"
      return 1
    fi
    log "commit $(git_ rev-parse --short HEAD) — $(printf '%s\n' "$staged" | wc -l | tr -d ' ') fichiers"
  fi

  # Dépôt sans aucun commit (PVC neuf + origin vide) : rien à pousser, et `HEAD:$BRANCH` échouerait
  # sur une référence non née.
  if ! git_ rev-parse --verify HEAD >/dev/null 2>&1; then
    log "aucun commit dans le dépôt, rien à pousser"
    return 0
  fi

  # Jamais de --force ni de pull --rebase : il n'y a qu'un seul écrivain légitime. Un rejet signale
  # une divergence réelle (push manuel depuis le pod, écriture directe sur la forge) et se traite à
  # la main. Les commits locaux restent, la passe suivante retentera le push.
  if git_ push -q origin "HEAD:$BRANCH"; then
    log "push OK vers origin/$BRANCH"
  else
    log "ERREUR: push rejeté ou forge injoignable — commits locaux conservés, nouvelle tentative demain"
    return 1
  fi
}

setup_credentials

if [ "${1:-}" = "--once" ]; then
  sync_once
  exit $?
fi

log "démarrage — une passe par jour à ${SYNC_HOUR}h${SYNC_MINUTE} UTC (après la fenêtre Velero de 03:00)"
while true; do
  # Pas de `date -d` : busybox ne parse pas les dates arbitraires de façon fiable. On calcule le
  # délai en arithmétique pure. Les `${x#0}` retirent le zéro de tête, que $(( )) lirait en octal.
  h=$(date -u +%H); h=${h#0}; h=${h:-0}
  m=$(date -u +%M); m=${m#0}; m=${m:-0}
  s=$(date -u +%S); s=${s#0}; s=${s:-0}
  elapsed=$(( h * 3600 + m * 60 + s ))
  target=$(( SYNC_HOUR * 3600 + SYNC_MINUTE * 60 ))
  delay=$(( target - elapsed ))
  [ "$delay" -le 0 ] && delay=$(( delay + 86400 ))
  log "prochaine passe dans ${delay}s"
  sleep "$delay"
  sync_once || log "passe en échec, la boucle continue"
done
