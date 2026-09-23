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
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi sur `/opt/data`, un
  initContainer de semis du profil shell
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
- **Le PVC est la seule source de vérité de l'état d'Hermes**, et rien dans ce composant ne le
  reconstruit : `config.yaml`, les skills, le workspace, les règles et la mémoire durable n'ont
  pas de copie déclarative. Un PVC neuf démarre VIDE et se repeuple à la main. GitOps ne porte
  ici que le déploiement, jamais le contenu de `/opt/data`.
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

`FORGEJO_TOKEN` (jeton de `hermes_agent`) n'est utilisé par aucune mécanique de ce composant : il
est là pour qu'**Hermes lui-même** clone des dépôts Forgejo depuis son terminal. Comme tout le
reste du Secret, il arrive dans le conteneur par l'`envFrom` global — donc dans l'environnement de
l'agent, qui exécute du code décidé par un LLM. Le rayon d'action de ce jeton est celui des droits
de `hermes_agent` sur la forge : les restreindre est le seul garde-fou.

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

Un seul état peut être remis à neuf, et il n'en revient rien : le **PVC** `data-hermes-0`. Aucune
copie n'existe dans ce composant, la remise à zéro est donc une PERTE — `config.yaml`, les skills,
le workspace, les règles, la mémoire durable, `auth.json`, les sessions et les caches partent
ensemble. Hermes redémarre vierge, dans l'état du premier déploiement.

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

Le device code du provider LLM est à refaire (`auth.json`, cf. §Contraintes). `hermes-env` n'est
pas concerné : le `SealedSecret` reste valide, rien n'est à resceller.
