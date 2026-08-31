# hermes

## Rôle

[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) en mode **gateway**,
c'est-à-dire le seul mode d'Hermes qui soit un service long. Un `StatefulSet` mono-replica porte
trois choses dans le même conteneur, supervisées par s6-overlay :

- la **passerelle messagerie** (Telegram par défaut) — aucun port entrant ;
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

- `hermes.app.yaml` — Application (archétype (c), path → `manifests/`). Livré en
  **`.noapp.yaml`** : le glob de `app.bootstrap.yaml` ne le ramasse pas tant qu'il n'est pas
  renommé (cf. §Activation).
- `manifests/namespace.yaml` — ns `hermes` (`sync-wave: -1`), **sans** label PodSecurity
  restrictif
- `manifests/serviceaccount.yaml` — SA `hermes` : identité kube de l'agent, dont les droits
  vivent dans [hermes-exec](../hermes-exec/manifests/rbac-hermes.yaml)
- `manifests/config/exec/hermes-exec-run` — lanceur de tâches jetables, semé dans le PATH de
  l'agent par l'initContainer
- `manifests/hermes-env.sealed.yaml` — `SealedSecret` : `API_SERVER_KEY` et identifiants du
  dashboard (cf. §Câblage des secrets). Également listé dans le `configMapGenerator`, pour la
  seule raison expliquée en §Contraintes
- `manifests/config/config.yaml` — le `config.yaml` d'Hermes (modèle, backend terminal, plugins,
  dashboard), assemblé en ConfigMap par le `configMapGenerator` du `kustomization.yaml`
- `manifests/config/hermes.env` — variables d'environnement **non secrètes** du conteneur
  (`KEY=value`), assemblées en ConfigMap `hermes-vars` et injectées par `envFrom`
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi sur `/opt/data`,
  initContainer de semis du `config.yaml`
- `manifests/service.yaml` — ClusterIP, ports `api` (8642) et `dashboard` (9119)
- `manifests/hermes-httproute.yaml` — `hermes.lan.wittner.tech` → dashboard,
  `hermes-api.lan.wittner.tech` → API
- `manifests/kustomization.yaml` — assemblage. **Aucune `CiliumNetworkPolicy`** : ce composant
  est l'instance à sortie libre, cf. §Le jumeau contraint.

## Contraintes

> [!CAUTION]
> **L'agent exécute du code arbitraire décidé par un LLM, dans le pod.** `terminal.backend` est
> `local` : ni Docker ni SSH ne sont joignables depuis un pod, l'agent shell donc dans son propre
> conteneur.
>
> **Depuis le câblage de [hermes-exec](../hermes-exec/README.md), l'agent porte une identité kube.**
> L'affirmation « aucun RBAC associé » qui figurait ici n'est plus vraie. Ce qui la remplace :
> `automountServiceAccountToken: false` reste posé, mais un token projeté est monté dans le seul
> conteneur `hermes`, et le `Role` associé ne couvre que `jobs` / `pods` / `pods/log` dans le
> namespace `hermes-exec` — sans `exec`, sans `portforward`, sans aucun verbe sur les
> `Role`/`RoleBinding`. Le raisonnement de sûreté n'est donc plus « aucun accès à l'API » mais
> « un accès dont la portée est entièrement contenue ». Ce qui est refusé, et pourquoi, est
> documenté dans [`rbac-hermes.yaml`](../hermes-exec/manifests/rbac-hermes.yaml).
>
> Le garde-fou restant est que cette instance a un accès sortant libre. Le rayon d'action de
> l'agent est donc le pod *et tout ce que le réseau lui laisse joindre*. C'est délibéré et c'est
> le sujet de l'expérience (§Le jumeau contraint) — mais ça reste la raison pour laquelle son
> dashboard et son API ne sortent pas du listener `https-internal`.

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
  flux device code lancé à la main. Aucune clé d'API à sceller — `OPENAI_API_KEY` ne concerne
  que le provider `openai-api`, et n'a rien à voir avec `API_SERVER_KEY`. Contrepartie : c'est
  le seul état du composant que Git ne reconstruit pas. Perdre le PVC impose de refaire le
  device code.
- **`API_SERVER_KEY` : 16 caractères minimum**, pas 8 comme l'annonce la doc amont. En dessous,
  le hook de démarrage refuse de lancer `api_server`.
- **Le modèle se déclare sous `model.default`, jamais `model.name`.** `load_config()` normalise
  les deux, mais un chemin du runtime lit la config brute (`read_raw_config()`) où l'alias n'est
  pas résolu : la session démarre alors avec un modèle vide et chaque tour échoue en « Codex
  Responses request 'model' must be a non-empty string ». Symptôme trompeur — le corriger dans
  l'interface répare le pod courant, puis la panne revient au déploiement suivant, quand
  l'initContainer restaure le fichier de Git.
- **`_config_version` doit figurer dans le fichier.** Le script de migration du conteneur
  (`scripts/docker_config_migrate.py:70`) lit une version absente comme `0` et refuse tout ce qui
  est sous le plancher 12, là où le chemin CLI épargne explicitement les fichiers sans clé de
  version. Sans le stamp, chaque boot journalise « This config predates version 12 » et la
  migration ne tourne pas.
- **`config.yaml` est recopié depuis le ConfigMap à chaque démarrage.** Un `hermes config set`
  fait à la main dans le pod est écrasé au redémarrage suivant — c'est le but.
- **Le ConfigMap est généré avec un suffixe de hash**, et c'est load-bearing : Hermes ne relit
  pas son `config.yaml` à chaud, et l'initContainer ne le recopie qu'au démarrage du pod. Sans
  le hash, un ConfigMap mis à jour resterait sans effet jusqu'à un `rollout restart` manuel,
  sans qu'aucun signal ne l'indique (ArgoCD `Synced`, aucun log). Avec, éditer
  `config/config.yaml` renomme le ConfigMap, donc le `volumes:` du StatefulSet, donc le pod
  template : le rollout part tout seul. Ne pas poser `generatorOptions.disableNameSuffixHash`.
- **`hermes-env.sealed.yaml` est listé dans le `configMapGenerator` alors que ce n'est pas de la
  configuration.** C'est le même mécanisme étendu au secret : le Secret `hermes-env` est produit
  par le contrôleur sealed-secrets, hors de portée de kustomize, et un `envFrom` dont le Secret
  change ne redémarre rien. Le faire entrer dans le hash rend le rollout automatique au
  rescellement. Le fichier n'est monté que sur `/config`, l'initContainer ne recopie que
  `config.yaml`, et son contenu est chiffré et déjà dans Git — le retirer de cette liste rendrait
  silencieusement les rotations de secret sans effet jusqu'au prochain redémarrage.
- **Le PVC est RWO** : le pod sortant doit mourir avant que le nouveau monte le volume. Les
  rollouts ne sont pas sans coupure.
- **L'identifiant de modèle du ConfigMap (`gpt-5.1`) est à confirmer** contre le compte OpenAI
  réellement utilisé. Un id invalide ne bloque pas le démarrage du pod : il fait échouer le
  premier tour d'agent.

## Opérations

### Câblage des secrets

Canal **sealed-secrets** (cf. [sealed-secrets](../../infra/sealed-secrets/README.md)). Le template
en clair `manifests/hermes-env.secret.yaml` est gitignoré (`*.secret.yaml`) ; le remplir, sceller,
supprimer le clair, puis décommenter la ligne correspondante du `kustomization.yaml` :

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

# 3. Jeter le clair, décommenter hermes-env.sealed.yaml dans kustomization.yaml, committer
rm cluster/app/hermes/manifests/hermes-env.secret.yaml
```

Le `SealedSecret` est chiffré pour le couple (`hermes-env`, `hermes`) : le renommer ou le déplacer
de namespace exige de le resceller.

### Activation

Le composant est livré désactivé. Pour qu'ArgoCD le ramasse :

```bash
git mv cluster/app/hermes/hermes.noapp.yaml cluster/app/hermes/hermes.app.yaml
```

Ne le faire qu'une fois `hermes-env.sealed.yaml` en place, sinon le pod reste en
`CreateContainerConfigError` (le `envFrom` pointe un Secret absent).

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

### Lancer des tâches jetables

L'agent dispose de `hermes-exec-run` dans son PATH (semé par l'initContainer depuis le ConfigMap,
cf. [hermes-exec](../hermes-exec/README.md)) :

```bash
hermes-exec-run <task-id> '<commande sh>' [--image busybox|python] [--ttl N] [--deadline N] [--keep]
hermes-exec-run --list
```

Le script construit le Job à partir d'un gabarit durci et **n'expose pas** le manifeste à
l'appelant. C'est délibéré : plusieurs champs échouent en silence s'ils sont mal posés — au
premier rang le label `hermes.wittner.tech/role: task-runner`, qui est le sélecteur des
`CiliumNetworkPolicy`. Cilium tourne en enforcement `default` : un pod de tâche sans ce label
n'est sélectionné par aucune policy et obtient une **sortie réseau complète**, sans erreur ni
log. Laisser un LLM écrire ce manifeste reviendrait à faire dépendre l'isolation réseau de sa
prochaine complétion.

L'image est prise dans une liste blanche (`IMAGES` dans le script) : le pull est fait par le
kubelet, hors de portée des NetworkPolicy. En ajouter une = éditer le fichier, committer,
attendre le rollout.

Vérifier depuis le pod que l'identité est bien celle attendue :

```bash
kubectl -n hermes exec sts/hermes -c hermes -- hermes-exec-run --list
```

### Activer Discord

Le plugin de l'image fait foi sur la doc générique (`plugins/platforms/discord/plugin.yaml`) :
celle-ci annonce un `DISCORD_CHANNEL_ID` qui n'existe pas.

| Variable | Où | Rôle |
| --- | --- | --- |
| `DISCORD_BOT_TOKEN` | SealedSecret | requis — [portail développeur](https://discord.com/developers/applications) |
| `DISCORD_HOME_CHANNEL` | SealedSecret | ID du salon de livraison des cron et notifications |
| `DISCORD_HOME_CHANNEL_NAME` | SealedSecret | nom d'affichage de ce salon |
| `DISCORD_ALLOWED_USERS` | `manifests/config/hermes.env` | IDs autorisés, séparés par des virgules |

Les trois premières sont **commentées** dans le template en clair, et doivent le rester tant que
le vrai token n'est pas en main : un token invalide fait sortir la gateway au démarrage (conflit
non rejouable), ce qui emporte aussi le serveur d'API et laisse le pod `NotReady`.

`DISCORD_ALLOWED_USERS` est hors du Secret — ce sont des identifiants publics, et l'allow-list se
modifie ainsi sans repasser par kubeseal. Une valeur fausse y est sans danger : le plugin refuse
alors tout le monde. **Ne pas lui substituer `DISCORD_ALLOW_ALL_USERS`**, que la doc amont réserve
au développement.

Pour une autre plateforme (`TELEGRAM_BOT_TOKEN`, `EMAIL_IMAP_*`/`EMAIL_SMTP_*`, …) : mêmes règles.
Rien à ouvrir côté réseau ici — mais si la même plateforme est activée sur
[hermes-close](../hermes-close/README.md), ses hosts doivent y être ajoutés à `hermes-egress`,
sinon la gateway y sortira en boucle au démarrage.

### Passer le dashboard sur OIDC

L'auth basic est le minimum viable pour un accès LAN. Pour brancher
[authentik](../authentik/README.md) une fois celui-ci actif, remplacer les trois variables
`HERMES_DASHBOARD_BASIC_AUTH_*` par `HERMES_DASHBOARD_OIDC_ISSUER` +
`HERMES_DASHBOARD_OIDC_CLIENT_ID` (le fournisseur `dashboard_auth/self_hosted` s'active à leur
seule présence), et resceller.

### Le jumeau contraint

[hermes-close](../hermes-close/README.md) est une **copie conforme** de ce composant, à une
différence près : il porte une `CiliumNetworkPolicy` d'egress en défaut-refus, qui ne laisse
passer que le fournisseur LLM et Discord. Ce composant-ci, lui, n'a **aucune** policy — sortie
libre.

Le montage sert à mesurer ce qu'un agent perd quand on lui coupe internet. Il ne vaut que si une
seule variable change :

```bash
diff -r cluster/app/hermes/manifests cluster/app/hermes-close/manifests
```

> [!WARNING]
> **L'invariant est rompu depuis le câblage de hermes-exec.** Ce composant porte désormais un
> `ServiceAccount`, un token projeté, le lanceur `config/exec/hermes-exec-run` et une ligne de
> `PATH` en plus dans `config/profile` — `hermes-close` n'a rien de tout ça. La comparaison ne
> mesure donc plus une seule variable : ce côté-ci peut lancer des tâches, l'autre non.
> Décision assumée, cf. [hermes-exec](../hermes-exec/README.md) §Points d'extension. Pour la
> rétablir : câbler l'accès des deux côtés (il faudra alors une règle vers
> `kubernetes.default.svc` dans la `CiliumNetworkPolicy` de `hermes-close`, sinon son accès
> tombe en timeout), ou décommissionner le jumeau.

Hors cet écart, ce diff ne doit contenir que le namespace, les hostnames et ce qui en découle
(`public_url`, `API_SERVER_CORS_ORIGINS`), plus le fichier de policy présent d'un seul côté. Tout
le reste — modèle, ressources, toolsets, version d'image — doit rester identique. Modifier ce
composant sans reporter le changement de l'autre côté invalide la comparaison sans que rien ne le
signale.

Le test qui vérifie que la variable est bien la variable :

```bash
kubectl -n hermes       exec sts/hermes -- curl -sS -m5 https://example.com -o /dev/null -w '%{http_code}\n'   # 200
kubectl -n hermes-close exec sts/hermes -- curl -sS -m5 https://example.com -o /dev/null -w '%{http_code}\n'   # échec
```

Ce qui n'a **pas** été dupliqué : le `SealedSecret` (chiffré pour le couple nom+namespace, à
resceller là-bas), le token Discord (une seconde application est nécessaire, sinon les deux bots
répondent au même message) et l'auth OAuth du provider LLM (elle vit sur le PVC, deux flux device
code à lancer).

### Sauvegarde

Tout l'état est dans le PVC `data-hermes-0` : sessions, mémoires, skills, cron, `.env` semé. Il
n'est reconstructible depuis Git que pour sa partie configuration — les mémoires et sessions, non.
À couvrir par [velero](../../infra/velero/README.md) si l'on veut les garder.
