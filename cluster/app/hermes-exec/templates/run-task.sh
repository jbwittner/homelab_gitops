#!/bin/sh
# Lance un environnement d'exécution jetable à partir de task-job.yaml.
#
#   ./run-task.sh <task-id> '<commande sh>'
#
# Variables d'environnement (toutes optionnelles) :
#   TASK_IMAGE     image de l'exécuteur          (défaut: busybox:1.37.0)
#   TASK_TTL       rétention après fin, en s     (défaut: 600)
#   TASK_DEADLINE  durée de vie maximale, en s   (défaut: 1800)
#   DRY_RUN=1      affiche le manifeste au lieu de le créer
#
# Exemples :
#   ./run-task.sh build-42 'echo hello > /work/out.txt; cat /work/out.txt'
#   TASK_IMAGE=python:3.13-slim ./run-task.sh calc 'python -c "print(6*7)"'
#   DRY_RUN=1 ./run-task.sh inspect 'id'
#
# ⚠️ Les exécuteurs n'ont AUCUNE sortie réseau (cf. ../README.md §Points d'extension). Une
# commande qui télécharge quoi que ce soit échouera — c'est voulu. Ce dont la tâche a besoin
# doit être dans son image.
#
# ⚠️ La commande tourne en uid 65532 avec la racine en lecture seule. Seuls /work et /tmp sont
# écrivables.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 <task-id> '<commande sh>'" >&2; exit 2; }

TASK_ID=$1
TASK_CMD=$2
TASK_IMAGE=${TASK_IMAGE:-busybox:1.37.0}
TASK_TTL=${TASK_TTL:-600}
TASK_DEADLINE=${TASK_DEADLINE:-1800}

# DNS-1123 : le task-id sert de suffixe au nom du Job ET de valeur de label. Un caractère
# invalide fait échouer la création avec un message sur le label, pas sur l'argument.
echo "$TASK_ID" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' \
  || { echo "task-id invalide (DNS-1123 attendu : a-z 0-9 -) : $TASK_ID" >&2; exit 2; }

TPL=$(dirname "$0")/task-job.yaml

# Substitution des paramètres, puis remplacement du bloc `args:` par la commande demandée.
# Le corps est réindenté à 14 espaces, la profondeur du scalaire bloc sous `args: - |`.
# awk plutôt que sed : le bloc est multi-ligne et de longueur variable.
# Retire l'en-tête de documentation du template : il contient les mêmes ${...} et se ferait
# substituer aussi, produisant un commentaire absurde dans le manifeste rendu.
sed -n '/^apiVersion: batch\/v1$/,$p' "$TPL" \
| sed -e "s|\${TASK_ID}|$TASK_ID|g" \
    -e "s|\${TASK_IMAGE}|$TASK_IMAGE|g" \
    -e "s|\${TASK_TTL}|$TASK_TTL|g" \
    -e "s|\${TASK_DEADLINE}|$TASK_DEADLINE|g" \
| TASK_CMD="$TASK_CMD" awk '
    /^          args:$/ {
      print "          args:"
      print "            - |"
      # ENVIRON et non -v : awk interprete les echappements dans -v et REFUSE une
      # valeur contenant un saut de ligne ("newline in string"), ce qui exclut toute
      # commande multi-ligne.
      n = split(ENVIRON["TASK_CMD"], lines, "\n")
      for (i = 1; i <= n; i++) print "              " lines[i]
      skip = 1; next
    }
    # Saute l\''ancien bloc jusqu\''à la clé suivante de même niveau.
    skip && /^          [a-zA-Z]/ { skip = 0 }
    !skip
  ' \
| { [ "${DRY_RUN:-}" = "1" ] && cat || kubectl create -f -; }
