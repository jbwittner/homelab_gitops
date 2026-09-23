# hermes

## Rôle

[Hermes Agent](https://hermes-agent.nousresearch.com/) (Nous Research) en mode **gateway**,
c'est-à-dire le seul mode d'Hermes qui soit un service long. Un `StatefulSet` mono-replica porte
trois choses dans le même conteneur, supervisées par s6-overlay :

- la **passerelle messagerie** (**Discord** : `DISCORD_ALLOWED_USERS` dans `manifests/config/hermes.env`, seule plateforme câblée) — aucun port entrant ;
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
- `manifests/hermes-env.sealed.yaml` — `SealedSecret` : secrets runtime, dont
  `FORGEJO_TOKEN` (cf. §Câblage des secrets). Sa révision entre dans le hash de bootstrap.
- `homelab_hermes` — source de vérité du profil Hermes dans `/opt/data` : `config.yaml`, skills,
  workspace, règles et mémoire durable. Le dépôt est cloné au premier boot d'un PVC neuf.
- `manifests/config/hermes.env` — variables d'environnement **non secrètes** du conteneur
  (`KEY=value`), assemblées en ConfigMap `hermes-vars` et injectées par `envFrom`
- `manifests/config/profile` — profil shell semé par l'initContainer, également monté par le
  ConfigMap de bootstrap
- `manifests/sync/` — scripts Git read-only dans des ConfigMaps : bootstrap HTTPS et réplication
  déterministe du worktree Hermes vers Forgejo
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi sur `/opt/data`, deux
  initContainers de bootstrap/profil et un sidecar de synchronisation Git
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
  flux device code lancé à la main. Le bootstrap Git reconstruit le profil déclaratif mais pas
  cette autorisation ; perdre le PVC impose de refaire le device code.
- **`config.yaml` appartient à `homelab_hermes`.** Les réglages modifiables au runtime (modèle,
  plugins, mémoire, compression…) sont commités par le sidecar Git ; GitOps ne les recopie pas
  au redémarrage.
- **Le bootstrap ne clone que sur un PVC neuf.** Si `/opt/data/.git` existe, il est autoritaire et
  aucun redémarrage ne le remplace par Forgejo.
- **Le sidecar récupère `origin/main` avant de pousser.** Il rebase les commits Hermes lorsque
  possible, puis push normalement. En conflit seulement, il annule le rebase et force le main
  local : le worktree Hermes gagne sans qu'une résolution soit confiée à l'IA.
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

### Réplication du profil Hermes

`FORGEJO_TOKEN` autorise le checkout HTTPS de `jbwittner/homelab_hermes`. Il n'est injecté dans
le sidecar `git-sync` et l'initContainer `bootstrap-home` que comme clé individuelle
`secretKeyRef` : ces conteneurs ne reçoivent ni les autres secrets runtime ni un token Kubernetes.

- Sur un PVC neuf, `bootstrap-home` clone `main` dans `/opt/data` avant le démarrage d'Hermes. Si
  `homelab_hermes` ne contient encore aucun commit, il initialise simplement le checkout local ;
  le sidecar poussera le premier commit au cycle suivant, une fois les fichiers Hermes créés.
- Toutes les cinq minutes, le sidecar copie les chemins déclarés depuis le worktree Hermes dans un
  checkout privé `emptyDir`, récupère `origin/main`, rebase les commits locaux et pousse normalement.
  Les hooks, l'index et la configuration Git modifiables par Hermes ne sont jamais utilisés.
- Si le rebase signale un conflit, il est annulé et le main local est force-pushé : le worktree
  Hermes est alors la source de vérité.
- `workspace/` est copié entrée par entrée : une entrée de premier niveau qui porte son propre
  `.git` est **exclue**, et l'exclusion est tracée dans les logs du sidecar
  (`skipping embedded repo workspace/<nom>`). Elle a son propre remote et se reconstruit par un
  clone ; sans exclusion Git l'enregistrerait en gitlink — un SHA nu sans contenu ni URL, que
  Forgejo ne reçoit pas et qu'un PVC neuf reconstruit vide. **Un clone du workspace n'est donc
  pas sauvegardé** : après un reset, il est à refaire à la main. Le filtre ne regarde que le
  premier niveau, là où Hermes clone ; un dépôt enfoui plus profond repasserait en gitlink.
- Le sidecar ne refuse rien sur le contenu : ni whitespace, ni taille, ni `.gitignore` du worktree.
  C'est une sauvegarde de l'état de l'agent, pas une revue. Tout ce qu'Hermes écrit sous les
  chemins déclarés part sur Forgejo, y compris un secret qu'il y déposerait.
- Le bootstrap n'écrase jamais un PVC qui contient déjà `/opt/data/.git`, et le sidecar ne résout
  aucun conflit. Son script et sa cadence viennent des ConfigMaps GitOps montés en lecture seule ;
  Hermes ne peut pas les modifier.

Les logs sont accessibles sans écrire dans le cluster :

```bash
kubectl -n hermes logs sts/hermes -c git-sync -f
```

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
Rien à ouvrir côté réseau ici : ce composant n'a aucune `CiliumNetworkPolicy`, sa sortie
est libre.

### Passer le dashboard sur OIDC

L'auth basic est le minimum viable pour un accès LAN. Pour brancher
[authentik](../../../archive/authentik/README.md) une fois celui-ci actif, remplacer les trois variables
`HERMES_DASHBOARD_BASIC_AUTH_*` par `HERMES_DASHBOARD_OIDC_ISSUER` +
`HERMES_DASHBOARD_OIDC_CLIENT_ID` (le fournisseur `dashboard_auth/self_hosted` s'active à leur
seule présence), et resceller.

### Sauvegarde

Tout l'état vivant est dans le PVC `data-hermes-0`. `homelab_hermes` reconstruit le profil
versionné (`config.yaml`, skills, workspace, règles et mémoire durable) lors d'un nouveau PVC ;
`auth.json`, sessions, bases SQLite et caches restent hors Git.

Le namespace `hermes` est, depuis le 2026-09-23, le **seul périmètre déclaré** de la schedule
[velero](../../infra/velero/README.md) — mais elle ne tourne pas encore : le bucket GCS a été
supprimé et doit être reposé côté Terraform. Rien de ce qui est hors Git n'est donc sauvegardé à
ce jour. ⚠️ Quand elle tournera, il faudra un hook `pre.hook.backup.velero.io/command` lançant
`hermes backup` sur ce podTemplate : sans lui kopia copie `state.db` et ses sidecars `-wal`/`-shm`
à des instants différents, donc en cohérence-CRASH. Préalable non levé : la présence de la
commande `hermes backup` dans l'image épinglée `v2026.9.14` n'a pas été vérifiée.

### Repartir de zéro

Deux états indépendants peuvent être remis à neuf : le **PVC** `data-hermes-0` (ce qu'Hermes vit)
et le dépôt **`homelab_hermes`** (ce qui en est versionné). Les remettre à neuf ensemble ou
séparément ne donne pas le même résultat, d'où trois gestes distincts.

> [!WARNING]
> Le StatefulSet est sous `selfHeal: true`. Un `kubectl scale` est **annulé par ArgoCD en moins de
> trois minutes**, au milieu de la manipulation : la mise à zéro passe obligatoirement par un
> commit de `replicas: 0` dans `statefulset.yaml`. La suppression du PVC, elle, ne peut pas passer
> par Git — il naît de `volumeClaimTemplates`, ArgoCD ne le voit pas et `prune` ne le touche pas.
> C'est la seule écriture impérative de la procédure.

#### A. Hermes neuf, historique conservé

Remet `/opt/data` dans l'état du **dernier commit poussé**. C'est la sortie de secours d'un
worktree corrompu ou d'un cache SQLite en vrac, pas un vrai « clean » : tout ce qui est versionné
revient. Les dépôts qu'Hermes avait clonés dans son workspace, eux, ne reviennent pas — ils sont
exclus de la synchronisation et sont à re-cloner.

```bash
# 1. Le dernier cycle a-t-il poussé ? C'est la seule sauvegarde du profil.
kubectl -n hermes logs sts/hermes -c git-sync --tail=5

# 2. replicas: 0 dans statefulset.yaml → commit → push → attendre la fin du pod
kubectl -n hermes get pod -w

# 3. Irréversible : libère le thin LV. Tout le hors-Git part (auth.json, sessions, caches).
kubectl -n hermes delete pvc data-hermes-0

# 4. replicas: 1 → commit → push. Le StatefulSet recrée le PVC, bootstrap-home clone main.
kubectl -n hermes logs hermes-0 -c bootstrap-home
```

#### B. Historique neuf, Hermes intact

Écrase l'historique de `homelab_hermes` par un commit unique portant l'état courant. Utile après
qu'un fichier volumineux ou un secret y soit entré — le sidecar ne filtre rien.

1. Dans Forgejo : supprimer puis recréer `jbwittner/homelab_hermes`, **sans** README ni
   `.gitignore` initial (un commit de départ ferait diverger le premier push).
2. Jeter le checkout privé du sidecar, qui porte encore l'ancien historique dans son `emptyDir` :

```bash
kubectl -n hermes delete pod hermes-0
```

Au cycle suivant (≤ 5 min), `sync-once.sh` ne trouve plus de `main` distant, réinitialise son
checkout et pousse un commit unique. Le `.git` de `/opt/data` garde des références mortes, sans
effet : le sidecar ne s'en sert jamais, et `bootstrap-home` ne lit que celui d'un PVC neuf.

#### C. Jour 0 complet

L'ordre compte : tant qu'un pod tourne, le sidecar repousse l'état courant dans les cinq minutes
qui suivent la remise à neuf du dépôt.

1. `replicas: 0` dans `statefulset.yaml` → commit → push → attendre la disparition de `hermes-0`.
2. `kubectl -n hermes delete pvc data-hermes-0`.
3. Supprimer et recréer `homelab_hermes` vide dans Forgejo.
4. `replicas: 1` → commit → push.

`bootstrap-home` ne trouve pas de `main` distant, fait un `git init` dans `/opt/data` et rend la
main ; Hermes démarre vierge et le sidecar pousse le premier commit dès qu'il a écrit quelque
chose. C'est exactement l'état du premier déploiement.

```bash
kubectl -n hermes logs hermes-0 -c bootstrap-home   # « Initialized empty Git repository »
kubectl -n hermes logs hermes-0 -c git-sync --tail=20
```

`hermes-env` n'est concerné par aucun des trois : le `SealedSecret` reste valide, `FORGEJO_TOKEN`
est réutilisé tel quel et rien n'est à resceller. Recréer le dépôt Forgejo ne révoque pas le token,
mais vérifier que `hermes_agent` a toujours les droits d'écriture sur le dépôt recréé.
