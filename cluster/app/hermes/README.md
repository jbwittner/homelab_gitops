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
- `manifests/hermes-env.sealed.yaml` — `SealedSecret` : secrets runtime, dont `FORGEJO_TOKEN`
  (cf. §Câblage des secrets). Sa révision entre dans le hash de bootstrap.
- `manifests/config/hermes.env` — variables d'environnement **non secrètes** du conteneur
  (`KEY=value`), assemblées en ConfigMap `hermes-vars` et injectées par `envFrom`
- `manifests/config/git-sync.sh` — boucle du sidecar `git-sync` : une passe de commit + push par
  jour (cf. §Versionnement de `$HERMES_HOME`). Seul fichier du ConfigMap de bootstrap.
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi sur `/opt/data`, un
  sidecar `git-sync`. **Aucun initContainer** : rien n'écrit dans le PVC (cf. §Versionnement).
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
- **Le PVC est la seule source de vérité de l'état d'Hermes, et rien ici ne le reconstruit.** Le
  versionnement (§Versionnement de `$HERMES_HOME`) donne une **copie** de la part durable
  (`config.yaml`, skills, `workspace/`, notes, mémoires) dans `homelab_hermes`, mais **aucun
  automatisme ne la rejoue** : un PVC neuf démarre VIDE et se repeuple à la main. Le reste
  — `auth.json`, `.env`, sessions, `kanban.db`, caches, `home/` — n'a même pas de copie : ce sont
  des secrets ou de l'état runtime, le seul filet est Velero
  ([velero](../../infra/velero/README.md), sauvegarde quotidienne du namespace `hermes`).
  **Le dépôt git n'est pas un backup** : il ne porte que ce que l'allow-list laisse passer, et il
  ne se restaure pas tout seul.
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
  < cluster/app/hermes/manifests/hermes-env.secret.yaml \
  > cluster/app/hermes/manifests/hermes-env.sealed.yaml

# 3. Jeter le clair, puis committer le seul fichier scellé
rm cluster/app/hermes/manifests/hermes-env.secret.yaml
```

Le `SealedSecret` est chiffré pour le couple (`hermes-env`, `hermes`) : le renommer ou le déplacer
de namespace exige de le resceller.

`FORGEJO_TOKEN` (jeton de `hermes_agent`) sert deux choses : le sidecar `git-sync`
(§Versionnement de `$HERMES_HOME`), qui le reçoit par un `secretKeyRef` ciblé ; et **Hermes
lui-même**, pour cloner des dépôts Forgejo depuis son terminal — là il arrive par l'`envFrom`
global, donc dans l'environnement d'un agent qui exécute du code décidé par un LLM.
Le rayon d'action de ce jeton est celui des droits de `hermes_agent` sur la forge : les restreindre
est le seul garde-fou.

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

### Versionnement de `$HERMES_HOME`

`$HERMES_HOME` vaut `/opt/data`, c'est-à-dire le PVC. Sa part durable est poussée dans
[`jbwittner/homelab_hermes`](https://forgejo.wittner.tech/jbwittner/homelab_hermes) (dépôt
**privé**). Objectif : historique lisible, diff d'un skill ou d'une mémoire, copie hors cluster des
artefacts durables. **Ce n'est pas un backup**, cf. §Contraintes.

**Une seule pièce automatique, et elle ne fait que pousser** : le sidecar `git-sync`
(`config/git-sync.sh`), une passe `add` / `commit` / `push` par jour à **04:30 UTC** — après la
fenêtre Velero de 03:00. Il ne crée pas le dépôt, ne pose pas le remote, n'écrit pas le
`.gitignore`, et ne restaure **rien**.

> [!CAUTION]
> Ce composant n'écrit jamais dans le PVC pour le compte de git, et c'est une décision, pas un
> manque. Une version antérieure avait un initContainer `seed-git` qui restaurait depuis
> `origin/main` quand `HEAD` ne résolvait pas. Le 2026-09-25, `.git` a été détruit sous un
> `/opt/data` bien vivant : le script en a conclu « PVC neuf » et a fait un `reset --hard`. Les
> dégâts se sont limités à `README.md` parce qu'`origin` ne contenait alors qu'un README. Avec un
> dépôt peuplé, le même enchaînement écrase `config.yaml`, `SOUL.md` et tout `skills/`. **L'init et
> la restauration sont donc manuelles, et le resteront.**

Le jeton est `FORGEJO_TOKEN`, déjà dans `hermes-env` — rien à resceller. Le sidecar ne le reçoit que
par un `secretKeyRef` ciblé (pas l'`envFrom` global) et le passe par `GIT_ASKPASS` : il n'est
**jamais** écrit dans `.git/config`, que l'agent peut lire.

#### Ce qui part

Décidé par `/opt/data/.gitignore`, qui vit dans le PVC et est lui-même suivi par le dépôt. Le
sidecar ajoute une **seconde barrière indépendante** : si l'index contient un chemin matchant
`.env*`, `auth.json`, `.secrets/`, `*.key` ou `*.pem`, il refuse la passe entière et le log le dit.
Raison : le `.gitignore` vit *dans* le dépôt qu'il protège, donc à portée de l'agent.

Contenu de référence de l'allow-list — deny-all puis autorisations explicites, et un bloc de deny
dur qu'aucune règle ajoutée plus tard ne contourne :

```gitignore
# /opt/data is Hermes' runtime home. Ignore everything by default.
/*

# Repository documentation and collaboration rules
!/.gitignore
!/README.md
!/.hermes.md

# Existing durable, top-level documents
!/*.md

# Durable work products
!/workspace/
!/workspace/**
!/affinage/
!/affinage/**
!/affinage-live-nFl9v3/
!/affinage-live-nFl9v3/**

# Skills (including custom skills). Runtime caches remain ignored by default.
!/skills/
!/skills/**
/skills/.bundled_manifest
/skills/.curator_ledger.jsonl
/skills/.curator_state
/skills/.usage.json
**/__pycache__/
*.py[cod]

# Explicitly chosen configuration documents (never credentials)
!/config.yaml

# Curated durable memory only — not session history or runtime state
!/memories/
!/memories/USER.md

# Never force-add these, even if a future rule changes
.env
.secrets/
auth.json
sessions/
logs/
cache/
gateway/
state/
pending_messages/
*.db
*.db-*
*.db-wal
*.db-shm
*.lock
*.pid
*.sock
lazy-packages/
audio_cache/
image_cache/
lost+found/
```

#### Premier boot sur un PVC neuf : commenter les sondes

À faire **avant** l'init, sinon elle est interrompue en plein milieu.

Sur un volume vierge, la gateway ne monte pas jusqu'à 8642 tant que `config.yaml` n'a pas été
corrigé à la main (voir l'étape « modèle et fournisseur » plus bas). Or la `startupProbe` est sur
8642 avec `failureThreshold: 60` : au bout de 10 minutes, kubelet détruit le conteneur — au milieu
de la manipulation, et en boucle.

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
> Sondes commentées, `2/2 Running` ne veut **plus rien dire** : kubelet ne teste plus rien et le pod
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

À faire à la main après tout PVC neuf. **Aucune de ces commandes n'est rejouée par le cluster** :
il n'y a plus d'initContainer, le PVC n'est écrit que par Hermes lui-même et par le sidecar.

D'abord le profil shell, qui n'a rien à voir avec git mais se perd au même moment :

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

Puis le dépôt :

```bash
# 1. Dépôt, remote, identité. Depuis le conteneur hermes (root, safe.directory obligatoire :
#    /opt/data appartient à l'uid 10000).
kubectl -n hermes exec -it hermes-0 -c hermes -- sh -c '
  cd /opt/data
  git config --global --add safe.directory /opt/data
  git init -b main
  git remote add origin https://forgejo.wittner.tech/jbwittner/homelab_hermes.git
  git config user.name  "hermes_agent"
  git config user.email "hermes_agent@wittner.tech"
'

# 2. Poser le .gitignore (bloc ci-dessus) en /opt/data/.gitignore, puis :
kubectl -n hermes exec hermes-0 -c hermes -- chown 10000:10000 /opt/data/.gitignore

# 3. Premier push : par le sidecar, qui a déjà GIT_ASKPASS câblé — aucun jeton à manipuler.
kubectl -n hermes exec hermes-0 -c git-sync -- sh /bootstrap/git-sync.sh --once
```

Pour **restaurer** un PVC neuf depuis le dépôt (étape 1 puis, à la place de l'étape 3) :

```bash
kubectl -n hermes exec hermes-0 -c git-sync -- sh -c '
  export GIT_ASKPASS=/tmp/git-askpass.sh GIT_TERMINAL_PROMPT=0
  G="git -c safe.directory=/opt/data -C /opt/data"
  $G fetch --depth=1 origin main && $G reset --hard FETCH_HEAD'
```

> [!WARNING]
> `reset --hard` écrase les fichiers suivis par le contenu d'`origin`. Ne le lancer que sur un
> `/opt/data` dont on sait qu'il est vierge. Sur un PVC peuplé, utiliser `reset --mixed` et
> arbitrer fichier par fichier.

#### Exploitation

```bash
# Forcer une passe sans attendre 04:30
kubectl -n hermes exec hermes-0 -c git-sync -- sh /bootstrap/git-sync.sh --once

kubectl -n hermes logs hermes-0 -c git-sync

# Ce qui est réellement suivi (doit être vide)
kubectl -n hermes exec hermes-0 -c hermes -- \
  git -c safe.directory=/opt/data -C /opt/data ls-files \
  | grep -E '\.env|auth\.json|\.secrets|\.key$|\.pem$'
```

**Push rejeté.** Le sidecar ne fait **jamais** de `--force` ni de `pull --rebase` : un rejet signale
une divergence réelle (push manuel depuis le pod, écriture directe sur la forge). Les commits locaux
sont conservés et la passe suivante retente ; l'arbitrage est manuel, depuis le pod.

**`.git` absent.** Le sidecar log `ERREUR: /opt/data/.git absent` et ne fait rien d'autre : l'init
ci-dessus n'a jamais été fait, ou le dépôt a été détruit. Dans les deux cas c'est une décision
humaine, pas un cas à automatiser.

> [!WARNING]
> Le trafic vers Forgejo sort du cluster par le tunnel Cloudflare (plafond 100 Mo par requête sur
> le plan gratuit). L'arbre suivi pèse quelques Mio : large marge, mais ne jamais ouvrir
> l'allow-list à `cache/`, `lazy-packages/` ou `image_cache/`.

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
`data-hermes-0`. Les artefacts durables ont une copie dans `homelab_hermes`, mais la restauration
est une opération manuelle (§Versionnement de `$HERMES_HOME`, sous-section « Init, une fois par
PVC »). Restent PERDUS, faute de toute copie : `auth.json`, `.env`, les sessions, `kanban.db`, les
caches et `home/`. Pour les récupérer réellement, c'est une restauration Velero, pas cette
procédure.

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

Le PVC recréé est **vide**. Pour y remettre les artefacts durables : §Versionnement de
`$HERMES_HOME`, « Init, une fois par PVC ». Le device code du provider LLM est à refaire
(`auth.json`, cf. §Contraintes). `hermes-env` n'est pas concerné : le `SealedSecret` reste valide,
rien n'est à resceller.
