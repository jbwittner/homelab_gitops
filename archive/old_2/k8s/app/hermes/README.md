# hermes

## Rôle

[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) en mode **gateway**,
c'est-à-dire le seul mode d'Hermes qui soit un service long. Un `StatefulSet` mono-replica porte
trois choses dans le même conteneur, supervisées par s6-overlay :

- la **passerelle messagerie** (**Discord** : `DISCORD_ALLOWED_USERS` dans le SealedSecret, seule plateforme câblée) — aucun port entrant ;
- le **serveur d'API OpenAI-compatible** sur `8642`, protégé par `API_SERVER_KEY` ;
- le **dashboard web** sur `9119`, derrière la gate d'authentification de l'image.

Les deux ports sont publiés sur le listener **`https-internal`** du `shared-gw`
(`*.lan.wittner.tech`) — jamais en public, cf. §Contraintes.

> [!NOTE]
> La page « Quickstart » de la doc amont décrit l'installation **locale** (`install.sh`, `~/.hermes`,
> CLI/TUI) et ne s'applique pas ici. La référence de ce composant est
> [user-guide/docker.md](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/docker.md)
> et le [Dockerfile](https://github.com/NousResearch/hermes-agent/blob/main/Dockerfile) du dépôt amont.

## Fichiers

- `hermes.app.yaml` — Application (archétype (c), path → `manifests/`). **Actif** : le glob
  `{*.app.yaml,*.appset.yaml}` de `app.bootstrap.yaml` le ramasse.
- `manifests/namespace.yaml` — ns `hermes` (`sync-wave: -1`), **sans** label PodSecurity
  restrictif
- `manifests/hermes-env.sealed.yaml` — `SealedSecret` : secrets runtime (cf. §Câblage des
  secrets). Sa révision entre dans le hash du ConfigMap `hermes-bootstrap`, seul déclencheur de
  rollout sur un rescellement.
- `manifests/config/hermes.env` — variables d'environnement **non secrètes** du conteneur
  (`KEY=value`), assemblées en ConfigMap `hermes-vars` et injectées par `envFrom`
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 15 Gi sur `/opt/data`, un
  seul conteneur. **Aucun initContainer** : rien n'écrit dans le PVC pour le compte du cluster
  (cf. §`$HERMES_HOME` : ni versionné, ni semé).
  `startupProbe` sur l'API (8642) et non sur le dashboard, qui bind trop tôt.
- `manifests/service.yaml` — ClusterIP, ports `api` (8642) et `dashboard` (9119)
- `manifests/hermes-httproute.yaml` — `hermes.lan.wittner.tech` → dashboard,
  `hermes-api.lan.wittner.tech` → API
- `manifests/kustomization.yaml` — assemblage. **Aucune `CiliumNetworkPolicy`** : ce composant est
  l'instance à sortie libre (cf. §Contraintes).

> [!NOTE]
> Ce composant a eu un **jumeau contraint** (`hermes-close`), destiné à comparer la même image sous
> politique réseau restrictive. Il a été **supprimé depuis** ; les renvois à un « §Le jumeau
> contraint » qui traînaient dans cette page n'avaient plus de cible.

## Contraintes

> [!CAUTION]
> **L'agent exécute du code arbitraire décidé par un LLM, dans le pod.** `terminal.backend` est
> `local` : ni Docker ni SSH ne sont joignables depuis un pod, l'agent shell donc dans son propre
> conteneur. Deux garde-fous sont load-bearing et ne se retirent pas sans réfléchir :
> `automountServiceAccountToken: false` (sans lui, une injection de prompt vaut un accès à l'API
> kube) et l'absence de tout RBAC associé.
>
> Il n'y en a **pas de troisième** : cette instance a un accès sortant libre. Le rayon d'action de
> l'agent est donc le pod *et tout ce que le réseau lui laisse joindre*. C'est délibéré — mais ça
> reste la raison pour laquelle son dashboard et son API ne sortent pas du listener
> `https-internal`.

- **Le conteneur démarre en root, et c'est voulu.** s6-overlay chown `/opt/data` au premier boot
  puis descend sur l'uid 10000 pour chaque service supervisé. Poser `runAsNonRoot: true` casse le
  modèle : l'image *refuse* `gateway run` en root une fois le drop contourné
  (`HERMES_ALLOW_ROOT_GATEWAY=1` existe, ne pas s'en servir). Le ns reste donc en PodSecurity
  `baseline`.
- **Ne jamais écraser l'`ENTRYPOINT`.** C'est le dispatcher qui lance s6 ; sans lui, plus de
  supervision (le dashboard et le redémarrage auto de la gateway disparaissent) ni de drop de
  privilèges. On ne change que les `args`.
- **Le dashboard échoue au démarrage sans fournisseur d'auth** dès que le bind est non-loopback
  (ici `0.0.0.0`, obligatoire pour que le Service joigne quoi que ce soit).
  `HERMES_DASHBOARD_INSECURE` est un no-op déprécié depuis juin 2026 : il n'y a plus
  d'échappatoire. C'est délibéré côté amont — un dashboard non authentifié a été le point
  d'entrée d'une campagne de persistance qui a fait planter des portes dérobées SSH à des agents
  exposés.
- **Pas d'exposition publique.** Les mêmes scanners ont aussi visé les serveurs d'API exposés.
  D'où `sectionName: https-internal` sur les deux routes.
- **Un token de messagerie invalide fait sortir toute la gateway.** L'échec de connexion à la
  plateforme est traité comme un conflit de démarrage non rejouable : le processus quitte, s6 le
  relance en boucle, et le serveur d'API ne monte jamais. La `startupProbe` étant sur 8642, le
  conteneur finit par être redémarré au bout de 10 minutes — en boucle, sans que rien ne pointe
  vers la messagerie. Pas de messagerie voulue = retirer la variable, pas y laisser un placeholder.
- **L'authentification au fournisseur LLM n'est pas dans Git.** Le provider `openai-codex` est
  en `auth_type: oauth_external` : ses jetons vivent dans `/opt/data/auth.json`, écrits par un
  flux device code lancé à la main.
- **Le PVC est la seule source de vérité de l'état d'Hermes, et rien ici ne le reconstruit.**
  `config.yaml`, skills, `workspace/`, notes, mémoires, `auth.json`, `.env`, sessions,
  `kanban.db` : tout vit dans `/opt/data`, et le **seul** filet est Velero
  ([velero](../../infra/velero/README.md), sauvegarde quotidienne du namespace `hermes`). Un PVC
  neuf démarre VIDE et se repeuple à la main (§`$HERMES_HOME` : ni versionné, ni semé).
- **Le PVC est RWO** : le pod sortant doit mourir avant que le nouveau monte le volume. Les
  rollouts ne sont pas sans coupure.

## Opérations

### Câblage des secrets

Canal **sealed-secrets** (cf. [sealed-secrets](../../infra/sealed-secrets/README.md)). Le template
en clair `manifests/hermes-env.secret.yaml` est gitignoré (`*.secret.yaml`) ; le remplir, sceller,
supprimer le clair. La ligne `hermes-env.sealed.yaml` est **déjà active** dans le
`kustomization.yaml` — il n'y a rien à décommenter :

```bash
# 1. Remplir les valeurs REMPLACER du template
#    API_SERVER_KEY / mot de passe et secret de session du dashboard :
openssl rand -hex 32
#
#    ⚠️ HERMES_DASHBOARD_BASIC_AUTH_SECRET : minimum 16 octets DÉCODÉS. En dessous, le
#    provider d'auth lève à la construction, ne s'enregistre pas, et le dashboard échoue avec
#    « no auth providers are registered » — message qui pointe vers une auth non configurée
#    alors que le vrai problème est une clé trop courte. Laisser la variable absente est plus
#    sûr qu'y mettre une valeur courte (Hermes génère alors une clé par processus).

# 2. Sceller
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < k8s/app/hermes/manifests/hermes-env.secret.yaml \
  > k8s/app/hermes/manifests/hermes-env.sealed.yaml

# 3. Jeter le clair, puis committer le seul fichier scellé
rm k8s/app/hermes/manifests/hermes-env.secret.yaml
```

Le `SealedSecret` est chiffré pour le couple (`hermes-env`, `hermes`) : le renommer ou le déplacer
de namespace exige de le resceller.

⚠️ Tout ce que porte `hermes-env` arrive par l'`envFrom` global, donc dans l'environnement d'un
agent qui exécute du code décidé par un LLM. Un jeton ajouté ici est lisible par l'agent : son
rayon d'action est celui des droits du jeton, et les restreindre est le seul garde-fou.

### État & accès

```bash
kubectl -n hermes get statefulset,pod,pvc
kubectl -n hermes logs sts/hermes -f          # gateway et dashboard sont interleavés
kubectl -n hermes get httproute
```

- Dashboard : <https://hermes.lan.wittner.tech> (login basic, identifiants du SealedSecret)
- API : `https://hermes-api.lan.wittner.tech/v1/...`, en-tête d'autorisation portant
  `API_SERVER_KEY`

Si la connexion au dashboard boucle sur la page de login, c'est le cookie sécurisé : renseigner
`dashboard.trusted_proxies` dans le ConfigMap avec le CIDR des pods (Hermes refuse les entrées non
bornées type `0.0.0.0/0`).

### `$HERMES_HOME` : ni versionné, ni semé

`$HERMES_HOME` vaut `/opt/data`, c'est-à-dire le PVC. **Il n'est plus versionné ni poussé nulle
part depuis le 2026-10-22** : le sidecar qui en poussait chaque jour la part durable a été retiré,
et le dépôt `jbwittner/homelab_hermes` n'est plus alimenté — ce qu'il contient date d'avant cette
coupure. La seule copie hors cluster est **Velero** (§Contraintes). Le `.git` et le `.gitignore`
qui traînent éventuellement dans `/opt/data` sont inertes : plus rien ne les lit.

> [!CAUTION]
> Ce composant n'écrit jamais dans le PVC, et c'est une décision, pas un manque. Une version
> antérieure avait un initContainer qui restaurait depuis un dépôt git quand `HEAD` ne résolvait
> pas. Le 2026-09-25, `.git` a été détruit sous un `/opt/data` bien vivant : le script en a conclu
> « PVC neuf » et a fait un `reset --hard`. Avec un dépôt peuplé, le même enchaînement écrase
> `config.yaml`, `SOUL.md` et tout `skills/`. **L'init et la restauration sont donc manuelles, et
> le resteront.**

#### Premier boot sur un PVC neuf : commenter les sondes

À faire **avant** l'init, sinon elle est interrompue en plein milieu.

Sur un volume vierge, la gateway ne monte pas jusqu'à 8642 tant que `config.yaml` n'a pas été
corrigé à la main (voir l'étape « modèle et fournisseur » plus bas). Or la `startupProbe` est sur
8642 avec `initialDelaySeconds: 60` et `failureThreshold: 60` : au bout de 11 minutes, kubelet
détruit le conteneur — au milieu de la manipulation, et en boucle.

1. commenter les trois sondes dans `manifests/statefulset.yaml` (`startupProbe`, `livenessProbe`,
   `readinessProbe`), commit, push — le pod remonte et reste `Ready` quoi qu'il arrive
2. faire l'init ci-dessous
3. vérifier que les deux ports répondent :

   ```bash
   kubectl -n hermes exec hermes-0 -c hermes -- sh -c \
     'for p in 8642 9119; do printf "%s -> " $p; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:$p/; done'
   # attendu : 8642 -> 404   (serveur d'API vivant, route inconnue)
   #           9119 -> 302   (dashboard vivant, redirection vers la gate d'auth)
   ```

4. décommenter les sondes, commit, push

> [!WARNING]
> Sondes commentées, `1/1 Running` ne veut **plus rien dire** : kubelet ne teste plus rien et le pod
> est déclaré prêt même avec zéro socket en écoute. Pendant cette fenêtre, se fier aux logs, à
> `gateway_state.json` et aux deux `curl` ci-dessus — pas à `kubectl get pod`. Ne pas oublier
> l'étape 4.

#### Modèle et fournisseur : le `config.yaml` livré boucle

Le `config.yaml` que l'image écrit sur un PVC vierge contient :

```yaml
model:
  default: "anthropic/claude-opus-4.6"
  provider: "auto"
  base_url: "https://openrouter.ai/api/v1"
```

Cette combinaison **fige la gateway au démarrage**, en récursion infinie :

1. `_config_model_provider` — `"auto"` n'est ni `custom` ni une clé du registre ; il y a un
   `base_url`, donc il demande s'il est digne de confiance
2. `_config_base_url_trustworthy_for_bare_custom(…, "auto")` — `"auto"` ≠ `custom`, donc il demande
   si `"auto"` résout vers `custom`
3. `_resolves_to_custom("auto")` → `resolve_provider("auto")` → **retour à l'étape 1**

Symptôme : le dernier log est `Previous gateway exited cleanly — skipping session suspension`,
`gateway_state` reste `starting`, 8642 ne bind jamais, et **rien n'apparaît dans les journaux**. Le
diagnostic passe par `kill -USR2` sur le processus gateway, qui vide la pile Python dans
`logs/gateway_faulthandler.log` (`faulthandler` est armé sur ce signal par `run_startup.py`).

Aucune variable d'environnement ne corrige ça : `grep` de `HERMES_MODEL`,
`HERMES_INFERENCE_MODEL`, `HERMES_BASE_URL` et `HERMES_INFERENCE_PROVIDER` dans `gateway/` et
`hermes_cli/gateway.py` ne donne **aucun résultat** — ces variables ne sont lues que par le cron,
`oneshot` et la TUI, et `HERMES_INFERENCE_PROVIDER` est de toute façon toujours derrière
`config_provider or …`. `api_mode` n'a aucune variable du tout. C'est donc `config.yaml`, donc
manuel.

> [!CAUTION]
> `provider: "openrouter"` **reproduit le gel** : cette valeur n'est ni un alias (142 testés) ni une
> clé du registre (79 testées), elle retombe donc exactement sur le chemin de `"auto"`. Valeurs
> sûres : `"custom"` (testé avant le registre) ou une vraie clé — `openai-codex`, `nous`,
> `anthropic`, `xai`, `gemini`, `bedrock`…

Configuration en place ici :

```yaml
model:
  default: gpt-5.6-terra
  provider: openai-codex
  base_url: https://chatgpt.com/backend-api/codex
  api_mode: codex_responses
```

`chatgpt.com/backend-api/codex` est d'ailleurs reconnu nativement (`agent/agent_init.py`,
`hermes_cli/runtime_provider.py`) : `openai-codex` et `codex_responses` en sont déduits même sans
les écrire. Après modification, relancer la gateway sans redémarrer le pod :

```bash
kubectl -n hermes exec hermes-0 -c hermes -- \
  /package/admin/s6/command/s6-svc -r /run/service/gateway-default
```

#### Init, une fois par PVC

À faire à la main après tout PVC neuf. **Cette commande n'est rejouée par rien** : il n'y a pas
d'initContainer, le PVC n'est écrit que par Hermes lui-même. Le profil shell :

```bash
kubectl -n hermes exec -i hermes-0 -c hermes -- sh -s <<'EOF'
install -d -o 10000 -g 10000 -m 0755 /opt/data/home
cat > /opt/data/home/.profile <<'PROFILE'
export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"
PROFILE
chown 10000:10000 /opt/data/home/.profile
chmod 0644        /opt/data/home/.profile
EOF
```

> [!IMPORTANT]
> Sans ce fichier, l'outil terminal de l'agent est **cassé de façon trompeuse**. Il ouvre un shell
> de login ; le `/etc/profile` de l'image *remplace* `PATH` par
> `/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games`, donc `/opt/hermes/bin` disparaît et
> un `hermes` nu répond `command not found` — l'agent en déduit que le binaire n'est pas installé.
> Invisible en `kubectl exec`, qui ne source pas `/etc/profile`. `~/.profile` est lu *après*
> `/etc/profile`, c'est le seul point de reprise sans écraser l'`ENTRYPOINT`.
> ⚠️ Ne jamais créer `~/.bash_profile` ni `~/.bash_login` dans `/opt/data/home` : bash s'arrête au
> premier trouvé et ignorerait `.profile` sans le moindre message.

### Mémoire

Provider **`holographic`** ([doc amont](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers#holographic))
— SQLite local, recherche plein texte FTS5, score de confiance, représentations holographiques
réduites pour les requêtes algébriques. **Aucun service externe, aucune clé d'API** : c'est ce qui
le rend tenable ici, où toute dépendance sortante supplémentaire élargit le rayon d'action de
l'agent. Il expose deux outils : `fact_store` (add/search/probe/related/reason/contradict/update/
remove/list) et `fact_feedback` (notation utile/inutile, `+0.05` / `-0.10` sur le score).
La mémoire intégrée d'Hermes reste active à côté ; un seul provider externe à la fois.

Réglages, dans `config.yaml` sous `plugins.hermes-memory-store` :

| Clé | Valeur ici | Défaut amont |
| --- | --- | --- |
| `db_path` | défaut | `$HERMES_HOME/memory_store.db` |
| `auto_extract` | défaut | `false` |
| `default_trust` | défaut | `0.5` |

**La base reste dans le PVC `data`**, en `/opt/data/memory_store.db`. `db_path` accepte pourtant
n'importe quel chemin absolu, et un volume dédié a bien été monté un temps sur `/opt/memory` —
abandonné : deux volumes RWO collés au même nœud, deux PVC à restaurer et un réglage manuel de
plus, pour isoler quelques dizaines de Mo. Le PVC est passé de 10 à **15 Gi** à la place. Si la
base devait un jour sortir, c'est `db_path` qu'on déplace, pas le montage.

Contrepartie assumée : **la mémoire meurt avec `data`**, comme le reste de l'état runtime.

Où vit quoi :

| Élément | Chemin | Filet |
| --- | --- | --- |
| provider (`memory.provider`) | `/opt/data/config.yaml` | Velero seul |
| base de faits | `/opt/data/memory_store.db` | Velero seul |
| plugin installé | `/opt/data/plugins/` | réinstallable |

Velero est en opt-out (`defaultVolumesToFsBackup: true`) : le volume est déjà dans la sauvegarde
quotidienne du namespace, rien à annoter. C'est une copie fichier d'un SQLite vivant — WAL
compris, donc potentiellement incohérente. Même situation que `kanban.db` et `state.db` : acceptée,
pas résolue.

#### Activation (à la main, une fois par PVC)

`kubectl exec` entre en **root** : tout fichier créé ici appartient à root, et les services
d'Hermes (uid 10000) échoueraient ensuite sur `Permission denied`. Le `chown` final n'est pas
optionnel. `hermes` nu ne résout pas non plus — `/etc/profile` écrase `PATH` (cf. « Init, une fois
par PVC »).

```bash
kubectl -n hermes exec -it hermes-0 -c hermes -- /opt/hermes/bin/hermes memory status
```

> [!NOTE]
> **Rien à installer** : `holographic` est livré avec l'image et apparaît dans les « Installed
> plugins » de `hermes memory status`. Les providers mémoire ont leur propre découverte, séparée
> du catalogue de plugins — ils sont **absents** de `hermes plugins list`, et un
> `hermes plugins install hermes-memory-store` n'a rien à faire ici.

Activer le provider, puis rendre la main à l'uid 10000 :

```bash
kubectl -n hermes exec -i hermes-0 -c hermes -- sh -s <<'EOF'
set -eu
export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"
hermes config set memory.provider holographic
hermes memory status
chown -R 10000:10000 /opt/data/config.yaml /opt/data/plugins 2>/dev/null || true
EOF
kubectl -n hermes delete pod hermes-0      # la gateway relit config.yaml au démarrage
```

**Aucune donnée ne se migre** entre providers : ce qui est dans la mémoire intégrée y reste,
holographic repart d'une base vide.

**Multi-profil : une base par profil en théorie, une seule en pratique.** Chaque profil a son
propre `$HERMES_HOME` (`/opt/data/profiles/<nom>`), donc sa propre base — *si* `db_path` n'est pas
renseigné. Or le `config.yaml` racine en porte un, écrit par Hermes lui-même :

```yaml
plugins:
  hermes-memory-store:
    db_path: ~/./memory_store.db
```

Le `~` est le HOME du **compte** `hermes` (`/opt/data`), pas le `$HERMES_HOME` du profil. Et un
profil sans réglage propre **hérite** de cette valeur — vérifié le 2026-09-25 :
`HERMES_PROFILE=jb hermes config get plugins.hermes-memory-store.db_path` rend la même chaîne, et
`memory.provider` y rend `holographic` sans que le `config.yaml` du profil ne mentionne ni l'un ni
l'autre. Les deux profils (`default`, `jb`) écrivent donc **dans le même fichier**.

Ce n'est pas forcément à corriger — une mémoire commune à tous les profils se défend. Mais ce n'est
pas ce que la structure laisse croire, et le choix doit être explicite :

| Ce qu'on veut | Ce qu'il faut faire |
| --- | --- |
| une mémoire commune (état actuel) | ne rien toucher |
| une base par profil | **retirer** `db_path` du `config.yaml` racine — sans valeur, chaque profil retombe sur son `$HERMES_HOME/memory_store.db` |
| une base par profil, chemins explicites | poser un `db_path` **dans chaque** `profiles/<nom>/config.yaml` |

`./script/hermes-memory-script.sh profiles` affiche la résolution réelle, profil par profil, et
signale les profils qui partagent un fichier.

#### Inspecter la base

[`script/hermes-memory-script.sh`](../../../script/hermes-memory-script.sh) — lecture seule :
`list`, `show`, `search` (FTS5), `entities`, `stats`, `schema`, `sql`, `dump`.

```bash
./script/hermes-memory-script.sh profiles          # quel profil lit quelle base
./script/hermes-memory-script.sh stats
./script/hermes-memory-script.sh list 20
./script/hermes-memory-script.sh search 'kubernetes OR argocd'
./script/hermes-memory-script.sh -p jb list        # la base du profil jb
```

Sans `--profile`, la cible est le profil `default`. Le script **résout** le chemin comme le plugin
le résout (valeur propre, sinon héritage de la racine, sinon `$HERMES_HOME/memory_store.db`) au
lieu de le supposer — c'est ce qui fait apparaître le partage de base décrit plus haut.

> [!IMPORTANT]
> Ne pas ouvrir la base à la main depuis un `kubectl exec` : l'exec entre en **root**, et un
> `-wal` / `-shm` créé par root rend la base inaccessible à la gateway, qui tourne en 10000. Le
> script descend sur l'uid 10000 avant d'ouvrir. Il n'y a d'ailleurs pas de binaire `sqlite3`
> dans l'image — tout passe par le module `sqlite3` de Python.

#### Lire ce que le script affiche

Le modèle est petit — quatre tables utiles, et des tables `facts_fts_*` qui sont la mécanique
interne de FTS5, jamais à lire directement :

| Table | Ce qu'elle porte |
| --- | --- |
| `facts` | **la mémoire**. Une ligne par fait : contenu, catégorie, tags, confiance, compteurs, vecteur |
| `entities` + `fact_entities` | les entités extraites du contenu, et leur rattachement aux faits |
| `facts_fts` | index plein texte FTS5, **contentless** (`content=facts`) — tenu à jour par trois triggers |
| `memory_banks` | une superposition vectorielle par catégorie (`cat:<catégorie>`), pour les requêtes algébriques |

> [!CAUTION]
> **NumPy est absent de l'image, et toute la partie « holographique » est donc inerte.** Vérifié le
> 2026-09-25 : `/opt/hermes/.venv/bin/python -c "import numpy"` répond `ModuleNotFoundError`, et
> `stats` affiche `0/2 faits portent un vecteur HRR`. Les conséquences sont silencieuses — aucune
> erreur nulle part :
>
> - `facts.hrr_vector` n'est **jamais** calculé (`show` dit « vecteur HRR absent ») ;
> - `memory_banks` reste **vide** en permanence ;
> - `search` **redistribue ses poids** : 0.6 FTS + 0.4 Jaccard + 0 HRR, au lieu de 0.4 / 0.3 / 0.3 ;
> - `probe`, `related` et `reason` **retombent sur la recherche FTS** — ils rendent exactement ce
>   que rendrait `search`, sans le dire ;
> - `contradict` renvoie **toujours une liste vide**.
>
> En l'état, le provider est donc *FTS5 + un score de confiance*. C'est utile, mais ce n'est pas ce
> que le nom promet : `probe`, `reason` et `contradict` — l'argument du provider — ne font rien.
> Les activer demande NumPy dans l'image, ce qu'aucun réglage de `config.yaml` ne procure.

**Les colonnes de `list`, et les deux qui mentent.**

| Colonne | Source | Ce qu'elle vaut |
| --- | --- | --- |
| `ID` | `fact_id` | identifiant, à passer à `show` |
| `CONFIANCE` | `trust_score` | barre de dix crans + valeur, bornée `[0, 1]` |
| `LU` | `retrieval_count` | ⚠️ **toujours 0** |
| `+` | `helpful_count` | ⚠️ ne compte que les retours **positifs** |
| `CATÉGORIE` | `category` | `general` par défaut ; c'est elle qui découpe les banques HRR |

⚠️ `retrieval_count` **n'est incrémenté nulle part**. La colonne existe dans le schéma et dans les
`SELECT` du plugin, mais aucun code ne l'écrit — un fait lu cent fois affiche `0`. Ne rien en
déduire sur ce que l'agent consulte.

⚠️ `helpful_count` ne bouge que sur un retour **utile**. Un retour inutile baisse la confiance sans
laisser de trace dans ce compteur : `0.30` avec `+0` ne veut pas dire « jamais noté », ça veut dire
**deux retours inutiles**. La confiance est le seul témoin des votes négatifs.

**La confiance, et le seuil qui fait disparaître un fait.** `0.5` à la création
(`default_trust`), `+0.05` par retour utile, `-0.10` par retour inutile, borné à `[0, 1]`.

> [!WARNING]
> `search` ne retient que les faits dont la confiance atteint **`min_trust` = 0.3**. Un fait tombé
> à `0.20` **disparaît des recherches** — de celles de l'agent comme de celles du script — tout en
> restant en base. **Trois retours inutiles y suffisent** (0.5 → 0.4 → 0.3 → 0.2). C'est la seule
> façon dont un fait devient invisible sans être supprimé, et `list` reste le seul moyen de le
> revoir :
>
> ```bash
> ./script/hermes-memory-script.sh sql \
>   "SELECT fact_id, trust_score, substr(content,1,60) FROM facts WHERE trust_score < 0.3"
> ```

**Comment `search` classe, et ce que le script montre à la place.** Côté plugin : candidats FTS5
(trois fois la limite, confiance ≥ 0.3) → `score = (0.6 × rang FTS + 0.4 × Jaccard) × confiance`,
puis décroissance temporelle `0.5^(âge / demi-vie)` si `temporal_decay_half_life` ≠ 0 — désactivé
par défaut. **Le script, lui, classe par le `rank` FTS5 brut** : il montre ce que contient la base,
pas l'ordre dans lequel l'agent verra les faits. Pour reproduire la pondération par confiance, la
requête est à écrire en `sql`.

Syntaxe de `search` : c'est celle de `MATCH` en FTS5 — mots, `"phrase exacte"`, `AND` / `OR` /
`NOT`, `préfixe*`, et `tags:terme` pour ne chercher que dans les tags.

**Pourquoi `entities` est presque toujours vide.** Les entités ne sont **pas** fournies par
l'agent : elles sont extraites du contenu **par regex**, à chaque ajout et à chaque modification.
Trois motifs, appliqués dans cet ordre :

1. **deux mots capitalisés consécutifs** — `[A-Z][a-z]+( [A-Z][a-z]+)+`, donc « Jean Baptiste »
   oui, « Kubernetes » non ;
2. les termes entre **guillemets** doubles ou simples ;
3. « X **aka** Y » / « X **also known as** Y » — les deux côtés sont retenus.

Dédoublonnage insensible à la casse, résolution par nom exact puis par alias. `entity_type` reste
`unknown` : rien ne le renseigne dans ce plugin.

Conséquence : une phrase française ordinaire, avec une seule majuscule en tête, ne produit
**aucune** entité. Zéro entité n'est donc pas un symptôme — c'est le cas normal tant que les faits
ne nomment pas de personnes ou ne citent pas de termes entre guillemets. Et sans entités, `probe`
et `reason` n'auraient rien à relier même avec NumPy.

**Ce que dit `stats`.** Les tailles de fichiers sont la vraie mesure : un `.db` de 4 Ko avec un
`-wal` de 170 Ko est **normal** en mode WAL, pas un signe de corruption — les écritures récentes
vivent dans le WAL jusqu'au prochain checkpoint. La ligne `banques HRR` restera à 0 tant que NumPy
manque. Pour mémoire, la capacité d'une banque est `SNR = √(dim / n)` avec avertissement sous
`2.0`, soit **plus de 256 faits par catégorie** à `hrr_dim = 1024`.

**Les réglages qui changent tout ce qui précède.** La doc amont n'en documente que trois ; le
plugin en lit sept, sous `plugins.hermes-memory-store` dans `config.yaml` :

| Clé | Défaut | Effet sur la lecture |
| --- | --- | --- |
| `db_path` | `$HERMES_HOME/memory_store.db` | où le script va chercher (`HERMES_DB` de son côté) |
| `auto_extract` | `false` | extraction de faits en fin de session — sinon, seul l'agent écrit |
| `default_trust` | `0.5` | la valeur qui signifie « jamais noté » |
| `min_trust_threshold` | `0.3` | **le seuil de disparition en recherche** |
| `temporal_decay_half_life` | `0` (désactivé) | demi-vie en jours ; activé, un vieux fait recule |
| `hrr_dim` | `1024` | dimension des vecteurs, donc capacité des banques |
| `hrr_weight` | `0.3` | poids du HRR dans le score — **forcé à 0 sans NumPy** |

**Deux propriétés du schéma qui surprennent.** `facts.content` est **`UNIQUE`** : le même texte ne
peut pas être stocké deux fois, un doublon exact échoue au lieu de créer une seconde ligne. Et
`facts_fts` étant contentless, un `SELECT content FROM facts_fts` rend des colonnes **vides sans
erreur** — toute requête `sql` qui touche l'index doit rejoindre `facts` par
`facts_fts.rowid = facts.fact_id`.

### Agrandir le PVC

Deux opérations distinctes, et faire l'une sans l'autre est le piège :

1. **Le `volumeClaimTemplates` en Git** ne vaut que pour un PVC **à créer**. Le modifier ne
   redimensionne **jamais** `data-hermes-0`, qui existe déjà.
2. **Le PVC existant** se redimensionne en éditant l'objet (`allowVolumeExpansion: true` sur la
   SC), **en ligne, sans redémarrage** : lvm-localpv étend le LV puis le système de fichiers sur
   le volume monté.

   Le PVC passe par un état intermédiaire qui donne le change — `Resizing=True`,
   `FileSystemResizePending=True`, `Waiting for user to (re-)start a pod to finish file system
   resize of volume on node`, et `status.capacity` encore à l'ancienne taille. **Ne pas y obéir** :
   la condition se résout seule en une minute ou deux, le pod ne redémarre jamais.

> [!CAUTION]
> Le champ étant dans `volumeClaimTemplates`, **immuable**, le commit fait passer ArgoCD en
> `SyncFailed` (`updates to statefulset spec for fields other than [...] are forbidden`) jusqu'à
> ce que le StatefulSet soit supprimé à la main. `--cascade=orphan` ne touche **ni les pods ni
> les PVC**.

```bash
# 1. l'objet part, le pod et les PVC restent ; ArgoCD (selfHeal) le recrée et adopte le pod
kubectl -n hermes delete statefulset hermes --cascade=orphan
kubectl -n hermes get statefulset hermes -w

# 2. le PVC existant, séparément
kubectl -n hermes patch pvc data-hermes-0 \
  -p '{"spec":{"resources":{"requests":{"storage":"15Gi"}}}}'

# 3. attendre que CAPACITY suive, puis vérifier côté conteneur
kubectl -n hermes get pvc data-hermes-0 -w
kubectl -n hermes exec hermes-0 -c hermes -- df -h /opt/data
```

Fait le 2026-09-25 : 10 → 15 Gi, `df` à `15G`, pod jamais redémarré (99 min d'uptime au travers
de l'opération).

> [!WARNING]
> Si le **pod template** change en même temps (un `volumeMount` ajouté, par exemple), le
> StatefulSet recréé **ne remplace pas le pod tout seul** : il tente un update en place et boucle
> sur
> `Update Pod hermes-0 in StatefulSet hermes failed error: Pod "hermes-0" is invalid: spec:`
> `Forbidden: pod updates may not change fields other than spec.containers[*].image [...]`.
> Le pod adopté garde son ancien `controller-revision-hash` et tourne avec l'ancien spec. Il faut
> le supprimer à la main — et tant qu'il n'est pas remplacé, un PVC ajouté au modèle reste
> `Pending` sur `waiting for first consumer` (la SC est en `WaitForFirstConsumer`) :
>
> ```bash
> kubectl -n hermes delete pod hermes-0
> ```
>
> Vu le 2026-09-25 en tentant d'ajouter un volume dédié à la mémoire. Un changement de **taille
> seule** ne touche pas le pod template et n'a pas ce problème.

> [!NOTE]
> La SC s'appelle `openebs-lvm-thin` mais porte `thinProvision: "no"` : les LV sont **thick**, la
> taille demandée est réservée dans le VG dès la création. Vérifier la place avant d'agrandir :
> `kubectl get lvmnodes -A -o custom-columns='NODE:.metadata.name,FREE:.volumeGroups[*].free'`.

### Activer Discord

Le plugin de l'image fait foi sur la doc générique (`plugins/platforms/discord/plugin.yaml`) :
celle-ci annonce un `DISCORD_CHANNEL_ID` qui n'existe pas.

| Variable | Où | Rôle |
| --- | --- | --- |
| `DISCORD_BOT_TOKEN` | SealedSecret | requis — [portail développeur](https://discord.com/developers/applications) |
| `DISCORD_HOME_CHANNEL` | SealedSecret | ID du salon de livraison des cron et notifications |
| `DISCORD_HOME_CHANNEL_NAME` | SealedSecret | nom d'affichage de ce salon |
| `DISCORD_ALLOWED_USERS` | SealedSecret | IDs autorisés, séparés par des virgules |

Les trois premières sont **commentées** dans le template en clair, et doivent le rester tant que
le vrai token n'est pas en main : un token invalide fait sortir la gateway au démarrage (conflit
non rejouable), ce qui emporte aussi le serveur d'API : la `startupProbe` sur 8642 finit alors par
faire redémarrer le conteneur en boucle.

`DISCORD_ALLOWED_USERS` est **dans le Secret**, bien que ce soient des identifiants publics :
cette allow-list décide qui pilote un agent à exécution de code arbitraire, elle ne se modifie
donc pas par un commit sur un fichier en clair. Contrepartie assumée — la changer impose de
repasser par kubeseal. Une valeur fausse y est sans danger : le plugin refuse alors tout le monde.
**Ne pas lui substituer `DISCORD_ALLOW_ALL_USERS`**, que la doc amont réserve au développement.

Pour une autre plateforme (`TELEGRAM_BOT_TOKEN`, `EMAIL_IMAP_*`/`EMAIL_SMTP_*`, …) : mêmes règles.
Rien à ouvrir côté réseau ici : ce composant n'a aucune `CiliumNetworkPolicy`, sa sortie
est libre.

### Passer le dashboard sur OIDC

L'auth basic est le minimum viable pour un accès LAN. Pour brancher
[authentik](../../../archive/authentik/README.md) une fois celui-ci actif, remplacer les trois variables
`HERMES_DASHBOARD_BASIC_AUTH_*` par `HERMES_DASHBOARD_OIDC_ISSUER` +
`HERMES_DASHBOARD_OIDC_CLIENT_ID` (le fournisseur `dashboard_auth/self_hosted` s'active à leur
seule présence), et resceller.

### Repartir de zéro

Un seul état peut être remis à neuf, et **rien ne revient tout seul** : le **PVC**
`data-hermes-0`. **Tout ce qu'il contient est perdu** — `config.yaml`, skills, mémoires,
`auth.json`, `.env`, sessions, `kanban.db` — faute d'autre copie que Velero. Pour le récupérer,
c'est une restauration Velero, pas cette procédure.

> [!WARNING]
> Le StatefulSet est sous `selfHeal: true`. Un `kubectl scale` est **annulé par ArgoCD en moins de
> trois minutes**, au milieu de la manipulation : la mise à zéro passe obligatoirement par un
> commit de `replicas: 0` dans `statefulset.yaml`. La suppression du PVC, elle, ne peut pas passer
> par Git — il naît de `volumeClaimTemplates`, ArgoCD ne le voit pas et `prune` ne le touche pas.
> C'est la seule écriture impérative de la procédure.

```bash
# 1. replicas: 0 dans statefulset.yaml → commit → push → attendre la fin du pod
kubectl -n hermes get pod -w

# 2. Irréversible : libère le thin LV. Tout part, y compris auth.json.
kubectl -n hermes delete pvc data-hermes-0

# 3. replicas: 1 → commit → push. Le StatefulSet recrée un PVC vide.
kubectl -n hermes logs hermes-0 -f
```

Le PVC recréé est **vide** : refaire §`$HERMES_HOME` : ni versionné, ni semé (sondes, modèle,
« Init, une fois par PVC »). Le device code du provider LLM est à refaire
(`auth.json`, cf. §Contraintes). `hermes-env` n'est pas concerné : le `SealedSecret` reste valide,
rien n'est à resceller.
