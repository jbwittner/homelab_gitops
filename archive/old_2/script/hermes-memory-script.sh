#!/usr/bin/env bash
#
# Inspection de la base mémoire d'Hermes (provider `holographic`) : `list`, `show`, `search`,
# `entities`, `stats`, `schema`, `sql`, `dump`.
#
# Le script est STRICTEMENT EN LECTURE. Aucune sous-commande n'écrit dans la base — l'état de la
# mémoire de l'agent se modifie par l'agent (`fact_store`, `fact_feedback`), pas depuis ici.
#
# POURQUOI CE SCRIPT EXISTE. Cinq pièges, dont le premier casse la gateway pour de bon.
#
#   1. `kubectl exec` ENTRE EN ROOT, et ouvrir la base en écriture depuis root crée
#      `memory_store.db-wal` / `-shm` appartenant à root. Hermes tourne sur l'uid 10000 : à la
#      première écriture suivante, la gateway se prend un `unable to open database file` sur SA
#      PROPRE base. Le script fait donc deux choses avant d'ouvrir — `os.setuid(10000)` et
#      `mode=ro` dans l'URI. La seconde seule ne suffit pas : SQLite a besoin d'écrire dans le
#      `-shm` d'une base en WAL, même pour lire.
#   2. `immutable=1` DONNERAIT UNE BASE VIDE. C'est la tentation naturelle pour « lire sans rien
#      toucher », mais il fait ignorer le WAL — et l'essentiel des données y vit tant qu'aucun
#      checkpoint n'est passé (4 Ko de `.db` pour 140 Ko de `-wal`, mesuré le 2026-09-25). On
#      lirait une base d'hier sans la moindre erreur. Jamais.
#   3. IL N'Y A PAS DE BINAIRE `sqlite3` DANS L'IMAGE. Tout passe par `python3 -` et le module
#      `sqlite3` de la stdlib (3.53.4). Rien à installer dans le pod, rien à `pip`.
#   4. `facts_fts` EST UNE TABLE CONTENTLESS (`content=facts`, `content_rowid=fact_id`) : un
#      `SELECT content FROM facts_fts` renvoie des colonnes VIDES, sans erreur. La recherche doit
#      toujours rejoindre `facts` par `rowid = fact_id`.
#   5. `facts.hrr_vector` est un BLOB de vecteur, pas du texte. Il n'est jamais imprimé : un
#      `SELECT *` naïf déverse des kilo-octets binaires dans le terminal. Le script n'en montre
#      que la taille.
#   6. IL Y A UNE BASE PAR PROFIL — en théorie. Chaque profil Hermes a son propre `$HERMES_HOME`
#      (`/opt/data/profiles/<nom>`) et donc, `db_path` non renseigné, sa propre base. Viser une
#      seule base en dur donnerait une lecture muette sur tous les autres profils. Le script
#      RÉSOUT donc le chemin comme le plugin le fait, profil par profil (`profiles`, `--profile`),
#      au lieu de le supposer.
#
#      ⚠️ Et la résolution réserve une surprise : le `db_path` écrit dans le `config.yaml` racine
#      vaut `~/./memory_store.db`. Le `~` est le HOME du compte hermes (`/opt/data`), PAS le
#      `$HERMES_HOME` du profil — et un profil sans `db_path` propre HÉRITE de cette valeur. Tous
#      les profils retombent alors sur LA MÊME base. C'est ce que `profiles` affiche, plutôt que
#      de laisser croire à une séparation qui n'a pas lieu.
#
# L'interpréteur utilisé dans le pod est celui du venv d'Hermes : la stdlib `sqlite3` suffirait,
# mais la résolution des profils a besoin de `yaml`, absent de `/usr/bin/python3`.
#
# Le `dump` passe par `Connection.backup()` et non par un `cp` : la copie est prise sous verrou,
# donc cohérente, WAL inclus. Un `kubectl cp` du `.db` seul, sur une base vivante, produit un
# fichier tronqué — c'est exactement le piège n°2 vu depuis l'autre bout.
#
# Documentation du composant : k8s/app/hermes/README.md, section Mémoire.

set -euo pipefail

NS="${HERMES_NS:-hermes}"
POD="${HERMES_POD:-hermes-0}"
CTR="${HERMES_CTR:-hermes}"
PY_BIN="${HERMES_PY:-/opt/hermes/.venv/bin/python}"
UID_HERMES="${HERMES_UID:-10000}"
# Vides par défaut : la cible est RÉSOLUE dans le pod, pas supposée ici.
PROFILE="${HERMES_PROFILE:-}"
DB="${HERMES_DB:-}"

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m/!\\\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Inspection (lecture seule) de la base mémoire d'Hermes — provider holographic.

  hermes-memory-script.sh list [N]           N derniers faits (défaut 20)
  hermes-memory-script.sh show <fact_id>     un fait complet, ses entités, son vecteur
  hermes-memory-script.sh search <requête>   recherche FTS5 (syntaxe MATCH de SQLite)
  hermes-memory-script.sh entities           entités et nombre de faits rattachés
  hermes-memory-script.sh stats              comptes, confiance, tailles de fichiers
  hermes-memory-script.sh schema             schéma complet (sqlite_master)
  hermes-memory-script.sh sql <SELECT ...>   requête libre, lecture seule
  hermes-memory-script.sh dump [fichier]     copie cohérente en local (défaut ./memory_store.db)
  hermes-memory-script.sh profiles           les profils, leur provider, LEUR base

Choix de la cible (défaut : le profil `default`, soit $HERMES_HOME) :

  -p, --profile <nom>   viser la base de ce profil, résolue comme le plugin la résout
      --db <chemin>     viser un fichier précis, sans passer par la configuration

Variables d'environnement : HERMES_NS, HERMES_POD, HERMES_CTR, HERMES_UID, HERMES_PY,
HERMES_PROFILE (équivaut à --profile), HERMES_DB (équivaut à --db).

Exemples :
  hermes-memory-script.sh profiles
  hermes-memory-script.sh -p jb list
  hermes-memory-script.sh search 'kubernetes OR argocd'
  hermes-memory-script.sh search 'tags:homelab'
  hermes-memory-script.sh sql "SELECT category, count(*) FROM facts GROUP BY 1"
USAGE
}

require_bins() {
  command -v kubectl >/dev/null || die "kubectl introuvable."
}

require_pod() {
  kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 \
    || die "pod $POD absent du namespace $NS."
  local phase
  phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')
  [ "$phase" = "Running" ] || die "pod $POD en phase $phase, pas Running."
}

# Exécute le programme Python embarqué dans le conteneur. Les arguments partent par argv —
# jamais par interpolation dans le source, qui casserait sur la première apostrophe d'une
# recherche et laisserait passer n'importe quel SQL.
run_py() {
  kubectl -n "$NS" exec -i "$POD" -c "$CTR" -- \
    "$PY_BIN" - "$UID_HERMES" "$PROFILE" "$DB" "$@" <<'PYEOF'
import os, sys, sqlite3, textwrap, glob, pwd

uid = int(sys.argv[1])
want_profile, db_override = sys.argv[2] or None, sys.argv[3] or None
sub, args = sys.argv[4], sys.argv[5:]

# Piège n°1 : descendre sur l'uid d'Hermes AVANT d'ouvrir quoi que ce soit.
if os.getuid() == 0:
    os.setgid(uid)
    os.setuid(uid)

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"

try:
    import yaml
except ImportError:
    yaml = None

HERMES_HOME = os.environ.get("HERMES_HOME", "/opt/data")
# Piège n°6 : le `~` d'un db_path est le HOME DU COMPTE hermes, pas celui de `kubectl exec`
# (root, /root) ni le $HERMES_HOME du profil. C'est cette valeur-là que voit la gateway.
ACCOUNT_HOME = pwd.getpwuid(uid).pw_dir


def _load(path):
    if yaml is None or not os.path.exists(path):
        return {}
    try:
        with open(path) as fh:
            return yaml.safe_load(fh) or {}
    except Exception:
        return {}


ROOT_CFG = _load(os.path.join(HERMES_HOME, "config.yaml"))


def _get(cfg, *path):
    cur = cfg
    for key in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def _expand(raw, home):
    raw = raw.replace("${HERMES_HOME}", home).replace("$HERMES_HOME", home)
    if raw.startswith("~"):
        raw = ACCOUNT_HOME + raw[1:]
    return os.path.normpath(raw)


def profiles():
    """Les profils et LEUR base, résolus comme le plugin les résout : valeur propre si elle
    existe, sinon héritage du config.yaml racine, sinon $HERMES_HOME/memory_store.db."""
    homes = [("default", HERMES_HOME, ROOT_CFG)]
    for d in sorted(glob.glob(os.path.join(HERMES_HOME, "profiles", "*"))):
        if os.path.isdir(d):
            homes.append((os.path.basename(d), d, _load(os.path.join(d, "config.yaml"))))
    rows = []
    for name, home, cfg in homes:
        own = _get(cfg, "plugins", "hermes-memory-store", "db_path")
        raw = own or _get(ROOT_CFG, "plugins", "hermes-memory-store", "db_path")
        rows.append({
            "name": name,
            "home": home,
            "provider": _get(cfg, "memory", "provider") or _get(ROOT_CFG, "memory", "provider"),
            "db": _expand(raw, home) if raw else os.path.join(home, "memory_store.db"),
            "raw": raw,
            "inherited": own is None and raw is not None,
        })
    return rows


def resolve_db():
    if db_override:
        return db_override
    rows = profiles()
    name = want_profile or "default"
    for r in rows:
        if r["name"] == name:
            return r["db"]
    print(f"profil inconnu : {name}", file=sys.stderr)
    print("profils trouvés : " + ", ".join(r["name"] for r in rows), file=sys.stderr)
    sys.exit(2)


def cmd_profiles():
    rows = profiles()
    if yaml is None:
        print(f"{DIM}yaml indisponible dans cet interpréteur : chemins par défaut seulement, "
              f"les db_path configurés ne sont pas lus.{RESET}")
    shared = {}
    for r in rows:
        shared.setdefault(r["db"], []).append(r["name"])
    print(f"{BOLD}{'PROFIL':<14} {'PROVIDER':<14} {'FAITS':>6}  BASE{RESET}")
    for r in rows:
        if os.path.exists(r["db"]):
            try:
                cx = sqlite3.connect(f"file:{r['db']}?mode=ro", uri=True)
                n = str(cx.execute("SELECT count(*) FROM facts").fetchone()[0])
                cx.close()
            except sqlite3.Error:
                n = "?"
            size = f"{os.path.getsize(r['db']):,} o"
        else:
            n, size = "—", "absente"
        print(f"{r['name']:<14} {str(r['provider'] or '—'):<14} {n:>6}  {r['db']}  {DIM}{size}{RESET}")
        if r["inherited"]:
            print(f"{'':<14} {DIM}db_path hérité de la racine : {r['raw']}{RESET}")
    collisions = {db: names for db, names in shared.items() if len(names) > 1}
    for db, names in collisions.items():
        print(f"\n/!\\ {BOLD}{len(names)} profils partagent la même base{RESET} — "
              f"{', '.join(names)}\n    {db}")
        print(f"    {DIM}un db_path en `~` ne dépend pas du profil : le retirer du config.yaml "
              f"racine rendrait à chaque profil sa propre base ($HERMES_HOME/memory_store.db).{RESET}")


if sub == "profiles":
    cmd_profiles()
    sys.exit(0)

db = resolve_db()
if not os.path.exists(db):
    print(f"base absente : {db}", file=sys.stderr)
    print("normal tant qu'aucun fait n'a été stocké — le fichier naît à la première écriture.",
          file=sys.stderr)
    print("`profiles` montre les bases de tous les profils.", file=sys.stderr)
    sys.exit(2)

# Piège n°2 : mode=ro, et surtout PAS immutable=1.
try:
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
except sqlite3.OperationalError as e:
    print(f"ouverture impossible : {e}", file=sys.stderr)
    sys.exit(1)
c.row_factory = sqlite3.Row


def trunc(s, n):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def bar(score):
    """Confiance en dix crans — 0.5 est le défaut du provider, pas un avis."""
    full = max(0, min(10, round((score or 0) * 10)))
    return "█" * full + "·" * (10 - full)


def cmd_list():
    n = int(args[0]) if args else 20
    rows = c.execute(
        "SELECT fact_id, category, tags, trust_score, retrieval_count, helpful_count,"
        "       content, updated_at"
        "  FROM facts ORDER BY fact_id DESC LIMIT ?", (n,)).fetchall()
    if not rows:
        print("aucun fait stocké.")
        return
    print(f"{BOLD}{'ID':>5}  {'CONFIANCE':<12} {'LU':>3} {'+':>3}  {'CATÉGORIE':<12} CONTENU{RESET}")
    for r in rows:
        print(f"{r['fact_id']:>5}  {bar(r['trust_score'])} {r['trust_score']:.2f} "
              f"{r['retrieval_count']:>3} {r['helpful_count']:>3}  "
              f"{trunc(r['category'], 12):<12} {trunc(r['content'], 70)}")
        if r["tags"]:
            print(f"{'':>5}  {DIM}tags: {trunc(r['tags'], 90)}{RESET}")


def cmd_show():
    if not args:
        print("show attend un fact_id.", file=sys.stderr); sys.exit(64)
    r = c.execute("SELECT * FROM facts WHERE fact_id = ?", (args[0],)).fetchone()
    if r is None:
        print(f"aucun fait d'id {args[0]}.", file=sys.stderr); sys.exit(2)
    print(f"{BOLD}fait #{r['fact_id']}{RESET}")
    for line in textwrap.wrap(r["content"], 96):
        print(f"  {line}")
    print()
    print(f"  catégorie   {r['category']}")
    print(f"  tags        {r['tags'] or DIM + '(aucun)' + RESET}")
    print(f"  confiance   {bar(r['trust_score'])} {r['trust_score']:.3f}")
    print(f"  lectures    {r['retrieval_count']}   dont utiles {r['helpful_count']}")
    print(f"  créé        {r['created_at']}")
    print(f"  modifié     {r['updated_at']}")
    # Piège n°5 : un BLOB de vecteur ne s'imprime pas, on en dit la taille.
    v = r["hrr_vector"]
    print(f"  vecteur HRR {len(v)} octets" if v else f"  vecteur HRR {DIM}absent{RESET}")
    ents = c.execute(
        "SELECT e.name, e.entity_type FROM fact_entities fe"
        "  JOIN entities e USING (entity_id) WHERE fe.fact_id = ? ORDER BY e.name",
        (r["fact_id"],)).fetchall()
    if ents:
        print("  entités     " + ", ".join(f"{e['name']} ({e['entity_type']})" for e in ents))


def cmd_search():
    if not args:
        print("search attend une requête.", file=sys.stderr); sys.exit(64)
    q = " ".join(args)
    # Piège n°4 : facts_fts est contentless, le contenu se relit dans facts par rowid.
    try:
        rows = c.execute(
            "SELECT f.fact_id, f.category, f.tags, f.trust_score, f.content, m.rank"
            "  FROM facts_fts m JOIN facts f ON f.fact_id = m.rowid"
            " WHERE facts_fts MATCH ? ORDER BY m.rank LIMIT 50", (q,)).fetchall()
    except sqlite3.OperationalError as e:
        print(f"requête FTS5 invalide : {e}", file=sys.stderr)
        print("syntaxe : mots, \"phrase exacte\", AND / OR / NOT, préfixe*, colonne:terme.",
              file=sys.stderr)
        sys.exit(64)
    if not rows:
        print(f"aucun fait ne correspond à : {q}")
        return
    print(f"{len(rows)} résultat(s) pour : {BOLD}{q}{RESET}\n")
    for r in rows:
        print(f"{r['fact_id']:>5}  {bar(r['trust_score'])} {r['trust_score']:.2f}  "
              f"{trunc(r['content'], 80)}")
        if r["tags"]:
            print(f"{'':>5}  {DIM}tags: {trunc(r['tags'], 90)}{RESET}")


def cmd_entities():
    rows = c.execute(
        "SELECT e.entity_id, e.name, e.entity_type, e.aliases, count(fe.fact_id) AS n"
        "  FROM entities e LEFT JOIN fact_entities fe USING (entity_id)"
        " GROUP BY e.entity_id ORDER BY n DESC, e.name").fetchall()
    if not rows:
        print("aucune entité.")
        print(f"{DIM}normal : l'extraction d'entités n'a lieu que si l'agent appelle "
              f"fact_store avec des entités, ou si auto_extract est activé.{RESET}")
        return
    print(f"{BOLD}{'ID':>5}  {'FAITS':>5}  {'TYPE':<14} NOM{RESET}")
    for r in rows:
        print(f"{r['entity_id']:>5}  {r['n']:>5}  {trunc(r['entity_type'], 14):<14} {r['name']}"
              + (f"  {DIM}alias: {r['aliases']}{RESET}" if r["aliases"] else ""))


def cmd_stats():
    n_facts = c.execute("SELECT count(*) FROM facts").fetchone()[0]
    print(f"{BOLD}Contenu{RESET}")
    print(f"  faits            {n_facts}")
    print(f"  entités          {c.execute('SELECT count(*) FROM entities').fetchone()[0]}")
    print(f"  liens fait↔entité {c.execute('SELECT count(*) FROM fact_entities').fetchone()[0]}")
    print(f"  banques HRR      {c.execute('SELECT count(*) FROM memory_banks').fetchone()[0]}")
    if n_facts:
        mn, av, mx = c.execute(
            "SELECT min(trust_score), avg(trust_score), max(trust_score) FROM facts").fetchone()
        print(f"\n{BOLD}Confiance{RESET}")
        print(f"  min {mn:.2f}   moyenne {av:.2f}   max {mx:.2f}")
        print(f"  {DIM}0.5 = default_trust, jamais noté. +0.05 par retour utile, "
              f"-0.10 par retour inutile.{RESET}")
        for r in c.execute("SELECT category, count(*) n FROM facts GROUP BY 1 ORDER BY n DESC"):
            print(f"  {r['n']:>5}  {r['category']}")
        vec = c.execute("SELECT count(*) FROM facts WHERE hrr_vector IS NOT NULL").fetchone()[0]
        print(f"\n  {vec}/{n_facts} faits portent un vecteur HRR")
        if vec == 0:
            print(f"  {DIM}aucun vecteur : NumPy est optionnel, et sans lui les requêtes "
                  f"algébriques (probe, reason) ne fonctionnent pas.{RESET}")
    print(f"\n{BOLD}Fichiers{RESET}")
    for suffix in ("", "-wal", "-shm"):
        path = db + suffix
        if os.path.exists(path):
            print(f"  {os.path.getsize(path):>12,} o  {path}")
    jm = c.execute("PRAGMA journal_mode").fetchone()[0]
    pc = c.execute("PRAGMA page_count").fetchone()[0]
    ps = c.execute("PRAGMA page_size").fetchone()[0]
    print(f"  journal_mode={jm}  pages={pc}×{ps} o")
    if jm.lower() == "wal":
        print(f"  {DIM}en WAL, le gros des écritures récentes vit dans le -wal tant qu'aucun "
              f"checkpoint n'est passé — un cp du .db seul ne les emporte pas.{RESET}")


def cmd_schema():
    for r in c.execute(
            "SELECT type, name, sql FROM sqlite_master"
            " WHERE sql IS NOT NULL ORDER BY type DESC, name"):
        print(f"{DIM}-- {r['type']} {r['name']}{RESET}")
        print(r["sql"] + ";\n")


def cmd_sql():
    if not args:
        print("sql attend une requête.", file=sys.stderr); sys.exit(64)
    q = " ".join(args).strip().rstrip(";")
    head = q.lstrip("( ").split(None, 1)[0].upper() if q else ""
    if head not in {"SELECT", "WITH", "PRAGMA", "EXPLAIN"}:
        print(f"refusé : seuls SELECT / WITH / PRAGMA / EXPLAIN sont acceptés (reçu {head}).",
              file=sys.stderr)
        print("la base est ouverte en lecture seule de toute façon — ce garde-fou évite "
              "surtout de croire qu'une écriture a eu lieu.", file=sys.stderr)
        sys.exit(64)
    try:
        cur = c.execute(q)
    except sqlite3.Error as e:
        print(f"SQL invalide : {e}", file=sys.stderr); sys.exit(64)
    rows = cur.fetchall()
    if not rows:
        print("(aucune ligne)")
        return
    cols = rows[0].keys()
    widths = [min(60, max(len(str(cl)), max(len(trunc(str(r[cl]), 60)) for r in rows)))
              for cl in cols]
    print(BOLD + "  ".join(str(cl).ljust(w) for cl, w in zip(cols, widths)) + RESET)
    for r in rows:
        print("  ".join(trunc(str(r[cl]), 60).ljust(w) for cl, w in zip(cols, widths)))
    print(f"{DIM}{len(rows)} ligne(s){RESET}")


def cmd_backup():
    """Copie cohérente vers /tmp dans le pod. Le transfert est fait par le script bash."""
    dest = args[0]
    with sqlite3.connect(dest) as out:
        c.backup(out)
    print(dest)


{
    "list": cmd_list, "show": cmd_show, "search": cmd_search, "entities": cmd_entities,
    "stats": cmd_stats, "schema": cmd_schema, "sql": cmd_sql, "backup": cmd_backup,
}[sub]()
PYEOF
}

cmd_dump() {
  local dest="${1:-./memory_store.db}"
  local tmp="/tmp/memory_store.dump.$$.db"
  [ -e "$dest" ] && die "$dest existe déjà — choisir un autre nom, le script n'écrase rien."

  log "copie cohérente dans le pod (Connection.backup, verrou pris, WAL inclus)"
  run_py backup "$tmp" >/dev/null

  log "transfert vers $dest"
  # `kubectl cp` refuse les chemins absolus côté local sur certaines versions : on passe par
  # `exec cat`, qui marche partout et n'a pas besoin de tar dans l'image.
  kubectl -n "$NS" exec "$POD" -c "$CTR" -- cat "$tmp" > "$dest"
  kubectl -n "$NS" exec "$POD" -c "$CTR" -- rm -f "$tmp"

  log "$dest — $(wc -c < "$dest" | tr -d ' ') octets"
  warn "cette copie contient la mémoire de l'agent en clair. Elle n'a rien à faire dans un dépôt."
}

require_bins

# Les options de cible passent AVANT la sous-commande. Elles sont lues ici et non dans le Python
# pour que `--db` court-circuite toute la résolution de profil, y compris quand la configuration
# est illisible.
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile) [ $# -ge 2 ] || die "--profile attend un nom."; PROFILE="$2"; shift 2 ;;
    --db)         [ $# -ge 2 ] || die "--db attend un chemin.";   DB="$2";      shift 2 ;;
    *) break ;;
  esac
done

case "${1:-}" in
  list|show|search|entities|stats|schema|sql|profiles)
    sub="$1"; shift
    require_pod
    run_py "$sub" "$@"
    ;;
  dump)
    shift
    require_pod
    cmd_dump "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    die "sous-commande inconnue : $1 (voir --help)"
    ;;
esac
