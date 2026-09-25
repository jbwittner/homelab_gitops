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
- `manifests/config/profile` — profil shell semé par l'initContainer, également monté par le
  ConfigMap de bootstrap
- `manifests/config/gitignore` — allow-list de ce qui part dans `homelab_hermes`, semée en
  `/opt/data/.gitignore` à chaque démarrage (cf. §Versionnement de `$HERMES_HOME`)
- `manifests/config/git-sync.sh` — boucle du sidecar `git-sync` : une passe de commit + push par
  jour
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi sur `/opt/data`, deux
  initContainers (`seed-git` puis `seed-profile`) et un sidecar `git-sync`
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
  relance en boucle, et le serveur d'API ne monte jamais — la `readinessProbe` sur 8642 laisse
  alors le pod `NotReady` sans que rien ne pointe vers la messagerie. Pas de messagerie voulue =
  retirer la variable, pas y laisser un placeholder.
- **L'authentification au fournisseur LLM n'est pas dans Git.** Le provider `openai-codex` est
  en `auth_type: oauth_external` : ses jetons vivent dans `/opt/data/auth.json`, écrits par un
  flux device code lancé à la main.
- **Le PVC reste la source de vérité de l'état d'Hermes.** Depuis la mise en place du
  versionnement (§Versionnement de `$HERMES_HOME`), la part **durable** — `config.yaml`, skills,
  `workspace/`, notes, `memories/USER.md` — a une copie dans `homelab_hermes` et revient toute
  seule sur un PVC neuf. Tout le reste n'en a pas : `auth.json`, `.env`, les sessions, `kanban.db`,
  les caches, `home/` **ne sont pas versionnés et ne le seront pas** — ce sont des secrets ou de
  l'état runtime. Pour ceux-là, le seul filet est Velero
  ([velero](../../infra/velero/README.md), sauvegarde quotidienne du namespace `hermes`).
  **Le dépôt git n'est pas un backup** : il ne porte que ce que l'allow-list laisse passer.
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

`FORGEJO_TOKEN` (jeton de `hermes_agent`) sert deux choses : l'initContainer `seed-git` et le
sidecar `git-sync` (§Versionnement de `$HERMES_HOME`), qui le reçoivent par un `secretKeyRef`
ciblé ; et **Hermes lui-même**, pour cloner des dépôts Forgejo depuis son terminal — là il arrive
par l'`envFrom` global, donc dans l'environnement d'un agent qui exécute du code décidé par un LLM.
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

`$HERMES_HOME` vaut `/opt/data`, c'est-à-dire le PVC. Sa part durable est versionnée dans
[`jbwittner/homelab_hermes`](https://forgejo.wittner.tech/jbwittner/homelab_hermes) (dépôt
**privé**). Objectif : historique lisible, diff d'un skill ou d'une mémoire, restauration
sélective, et repeuplement automatique d'un PVC neuf. **Ce n'est pas un backup** — cf. §Contraintes.

Trois pièces, toutes déclaratives :

| Pièce | Où | Rôle |
| --- | --- | --- |
| `manifests/config/gitignore` | ConfigMap `hermes-bootstrap` | allow-list, recopiée en `/opt/data/.gitignore` à **chaque** démarrage |
| initContainer `seed-git` | `statefulset.yaml` | `git init` + remote + allow-list, et **restauration** depuis `origin/main` sous deux conditions cumulées (cf. ci-dessous) |
| sidecar `git-sync` | `statefulset.yaml` + `config/git-sync.sh` | une passe `add`/`commit`/`push` par jour à **04:30 UTC** (après la fenêtre Velero de 03:00) |

Le jeton est `FORGEJO_TOKEN`, déjà dans `hermes-env` — rien à resceller. Il n'entre dans les deux
conteneurs git que par un `secretKeyRef` ciblé (pas l'`envFrom` global) et passe par `GIT_ASKPASS` :
il n'est **jamais** écrit dans `.git/config`, que l'agent peut lire.

**Ce qui part** est décidé par `config/gitignore` : deny-all `/*`, puis allow-list (`*.md`,
`workspace/`, `affinage/`, `skills/`, `config.yaml`, `memories/USER.md`), puis un bloc de deny dur
qu'aucune règle future ne contourne (`.env`, `auth.json`, `.secrets/`, `sessions/`, `cache/`,
`*.db`, `*.lock`, `lazy-packages/`…). Le sidecar ajoute une **seconde barrière indépendante** :
si l'index contient un chemin matchant `.env*`, `auth.json`, `.secrets/`, `*.key` ou `*.pem`, il
refuse la passe entière et le log le dit. Raison : le `.gitignore` vit *dans* le dépôt qu'il
protège, donc à portée de l'agent.

> [!IMPORTANT]
> L'allow-list se modifie **ici**, dans `manifests/config/gitignore`, jamais dans le pod : elle est
> réécrite à chaque démarrage. Et comme `.gitignore` est aussi **suivi** par `homelab_hermes`, les
> deux copies doivent rester identiques — sinon chaque boot produit un commit de bruit. Après avoir
> modifié l'une, vérifier :
>
> ```bash
> diff <(kubectl -n hermes exec hermes-0 -c hermes -- cat /opt/data/.gitignore) \
>      cluster/app/hermes/manifests/config/gitignore
> ```

`seed-git` ne restaure que si **deux** conditions sont réunies : `/opt/data` n'a aucun commit **et**
le répertoire est vierge (ni `config.yaml`, ni `sessions/`, ni `skills/`, ni `memories/`, ni `.env`,
ni `auth.json`). Sur un PVC vivant il ne fait que reposer le remote et l'allow-list.

> [!CAUTION]
> La seconde condition n'est pas du zèle. Le 2026-09-25, `.git` a été détruit sous un `/opt/data`
> bien vivant : `HEAD` ne résolvait plus, la version d'alors de ce script en a conclu « PVC neuf »
> et a fait un `reset --hard` sur `origin/main`. Les dégâts se sont limités à `README.md` parce
> qu'`origin` ne contenait qu'un README — avec le dépôt peuplé d'aujourd'hui, le même enchaînement
> écraserait `config.yaml`, `SOUL.md` et tout `skills/`. Quand `HEAD` manque mais que le répertoire
> est peuplé, `seed-git` **ne touche à rien** et hurle dans ses logs : c'est un arbitrage manuel.

```bash
# Forcer une passe sans attendre 04:30
kubectl -n hermes exec hermes-0 -c git-sync -- sh /bootstrap/git-sync.sh --once

# Logs du sidecar et du semis
kubectl -n hermes logs hermes-0 -c git-sync
kubectl -n hermes logs hermes-0 -c seed-git

# Ce qui est réellement suivi (doit être vide)
kubectl -n hermes exec hermes-0 -c hermes -- \
  git -c safe.directory=/opt/data -C /opt/data ls-files \
  | grep -E '\.env|auth\.json|\.secrets|\.key$|\.pem$'
```

**Push rejeté.** Le sidecar ne fait **jamais** de `--force` ni de `pull --rebase` : un rejet
signale une divergence réelle (push manuel depuis le pod, écriture directe sur la forge). Les
commits locaux sont conservés et la passe suivante retente ; l'arbitrage est manuel, depuis le pod.

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
non rejouable), ce qui emporte aussi le serveur d'API et laisse le pod `NotReady`.

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

Un seul état peut être remis à neuf : le **PVC** `data-hermes-0`. Ce n'est plus une perte totale —
l'initContainer `seed-git` restaure les artefacts durables depuis `homelab_hermes` (§Versionnement
de `$HERMES_HOME`). Restent PERDUS, faute de copie : `auth.json`, `.env`, les sessions,
`kanban.db`, les caches et `home/`. Pour les récupérer réellement, c'est une restauration Velero,
pas cette procédure.

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

Au redémarrage, `seed-git` refait `git init`, repose le remote et `reset --hard` sur
`origin/main` : skills, `config.yaml` et mémoires reviennent. Le device code du provider LLM est à
refaire (`auth.json`, cf. §Contraintes). `hermes-env` n'est
pas concerné : le `SealedSecret` reste valide, rien n'est à resceller.
