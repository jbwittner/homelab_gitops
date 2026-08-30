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
- `manifests/hermes-env.sealed.yaml` — `SealedSecret` : clé OpenAI, `API_SERVER_KEY`, identifiants
  du dashboard, token du bot. **À produire** (cf. §Câblage des secrets)
- `manifests/hermes-config.configmap.yaml` — le `config.yaml` d'Hermes (modèle, backend terminal,
  dashboard)
- `manifests/statefulset.yaml` — 1 replica, PVC `openebs-lvm-thin` 10 Gi sur `/opt/data`,
  initContainer de semis du `config.yaml`
- `manifests/service.yaml` — ClusterIP, ports `api` (8642) et `dashboard` (9119)
- `manifests/hermes-httproute.yaml` — `hermes.lan.wittner.tech` → dashboard,
  `hermes-api.lan.wittner.tech` → API
- `manifests/hermes-egress.ciliumnetworkpolicy.yaml` — egress défaut-refus : DNS + `api.openai.com`
  + `api.telegram.org`, rien d'autre
- `manifests/kustomization.yaml` — assemblage

## Contraintes

> [!CAUTION]
> **L'agent exécute du code arbitraire décidé par un LLM, dans le pod.** `terminal.backend` est
> `local` : ni Docker ni SSH ne sont joignables depuis un pod, l'agent shell donc dans son propre
> conteneur. Deux garde-fous sont load-bearing et ne se retirent pas sans réfléchir :
> `automountServiceAccountToken: false` (sans lui, une injection de prompt vaut un accès à l'API
> kube) et l'absence de tout RBAC associé. Le troisième est la `CiliumNetworkPolicy` d'egress,
> cf. §Egress — c'est la seule du repo, ne pas la prendre pour un reliquat copié d'ailleurs.

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
- **`config.yaml` est recopié depuis le ConfigMap à chaque démarrage.** Un `hermes config set`
  fait à la main dans le pod est écrasé au redémarrage suivant — c'est le but. Corollaire :
  éditer le ConfigMap n'a d'effet qu'après un `rollout restart`, il n'y a pas de rechargement à
  chaud.
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

### Changer de plateforme de messagerie

Le choix se fait par la variable présente dans le Secret : `TELEGRAM_BOT_TOKEN`,
`DISCORD_BOT_TOKEN` (+ `DISCORD_CHANNEL_ID`), `EMAIL_IMAP_*`/`EMAIL_SMTP_*`. Éditer le template en
clair, resceller, committer.

### Passer le dashboard sur OIDC

L'auth basic est le minimum viable pour un accès LAN. Pour brancher
[authentik](../authentik/README.md) une fois celui-ci actif, remplacer les trois variables
`HERMES_DASHBOARD_BASIC_AUTH_*` par `HERMES_DASHBOARD_OIDC_ISSUER` +
`HERMES_DASHBOARD_OIDC_CLIENT_ID` (le fournisseur `dashboard_auth/self_hosted` s'active à leur
seule présence), et resceller.

### Egress

Le pod est en **défaut-refus sortant**. Trois sorties seulement :

| Destination | Port | Pourquoi |
| --- | --- | --- |
| CoreDNS (`kube-system`) | 53 | et uniquement pour résoudre les deux noms ci-dessous |
| `api.openai.com` | 443 | fournisseur LLM |
| `api.telegram.org` | 443 | API Bot + téléchargement de fichiers |

Tout le reste tombe : GitHub, PyPI, npm, MCP distants, le reste du cluster. Les pulls d'image ne
sont pas concernés (c'est le kubelet qui les fait, pas ce pod).

**Ajouter une destination** = deux endroits dans le même fichier, jamais un seul : le `matchName`
sous `rules.dns` **et** le `toFQDNs`. Le proxy DNS de Cilium ne débloque une IP que pour un nom
qu'il a lui-même vu résoudre ; un `toFQDNs` orphelin ne matche rien et le symptôme est un timeout
réseau, pas un refus explicite.

La policy ne déclare **que** de l'egress, ce qui laisse l'ingress non appliqué — c'est ainsi que
le `shared-gw` continue de joindre 8642/9119. Y ajouter un bloc `ingress:` couperait le Gateway.

```bash
kubectl -n hermes get cnp hermes-egress
cilium monitor --type drop -n hermes            # depuis un pod cilium, voir ce qui tombe
kubectl -n hermes exec sts/hermes -- curl -sS -m5 https://api.openai.com/v1/models -o /dev/null -w '%{http_code}\n'
```

### Sauvegarde

Tout l'état est dans le PVC `data-hermes-0` : sessions, mémoires, skills, cron, `.env` semé. Il
n'est reconstructible depuis Git que pour sa partie configuration — les mémoires et sessions, non.
À couvrir par [velero](../../infra/velero/README.md) si l'on veut les garder.
