# forgejo — bascule Kubernetes → Docker, et sauvegarde de la cible

> [!CAUTION]
> **Cette procédure n'a JAMAIS été exécutée.** Contrairement à [`forgejo-pra.md`](forgejo-pra.md)
> et à son [exercice](forgejo-pra-exercice.md), dont chaque valeur et chaque message d'erreur sont
> relevés sur un passage réel, tout ce qui suit est **déduit** — de la configuration en service
> (relevée le 2026-09-09 sur le pod), du code amont (`cmd/dump.go`,
> `models/activities/statistic.go`, tag `v15.0.7`) et du chart 17.1.5.
>
> Les commandes sont exactes quant aux chemins, aux noms d'objets et aux tailles. Ce qui n'est pas
> éprouvé, c'est **l'enchaînement**. Le §A.5 existe pour ça : il ne bascule rien tant que la cible
> n'a pas prouvé qu'elle sert la même forge.

## Rôle

Deux choses qui ne se séparent pas :

1. **La bascule** — sortir la forge du cluster et la remonter en Docker sur une autre machine,
   sans perdre ce qui rend une restauration silencieusement fausse (§A).
2. **Le régime de sauvegarde de la cible** — ce qui remplace `velero` + `barman-cloud` une fois
   qu'ils ne sont plus là (§B).

L'ordre n'est pas négociable : **§B est écrit et joué AVANT la bascule du §A.6**. Basculer d'abord
et sauvegarder ensuite, c'est laisser la source de vérité de l'infrastructure entière sans filet
pendant le seul moment où on est sûr d'y toucher.

### Pourquoi cette page existe

Pas pour déplacer la forge. Pour **casser une dépendance circulaire** : si Forgejo devient la
source du GitOps en restant dans le cluster, alors ArgoCD lit un dépôt servi par un composant
qu'ArgoCD déploie. Un cluster à froid n'a plus de source, et l'exercice du 2026-09-09 — PVC, base
et Deployment détruits — aurait emporté la description de toute l'infrastructure avec la forge.

Sortir Forgejo du cluster est la **condition** pour que Forgejo soit la source, pas une préférence
d'hébergement.

### Ce que cette page ne couvre pas

- ~~**L'inversion des 27 `repoURL`** (`git@github.com:jbwittner/homelab_gitops.git` → la forge) et
  le credential ArgoCD associé.~~ ✅ **Fait.** Les `repoURL` de `cluster/` et `archive/` pointent
  `https://forgejo.wittner.tech/jbwittner/homelab_gitops.git`, et le Secret `repo-homelab-gitops`
  porte désormais un jeton Forgejo `read:repository` au lieu d'une deploy key SSH GitHub. Détail :
  [`cluster/infra/argocd/README.md`](../cluster/infra/argocd/README.md) §Accès au dépôt privé, et
  [`runbook-bootstrap.md`](runbook-bootstrap.md) §Source de vérité.
- **Le miroir push vers GitHub.** Recommandé — un miroir *sortant* n'est pas une dépendance, c'est
  une copie hors site gratuite d'un dépôt devenu critique — mais il se configure dans l'interface
  Forgejo, pas ici.
- **Le tunnel Cloudflare et le reverse proxy `192.168.1.50`** : cf. [`reseau.md`](reseau.md). Le
  §A.6 dit *quoi* changer, pas *comment* configurer ces deux-là.

## Ce qu'il faut emporter

Relevé le 2026-09-09 sur l'instance en service.

| Quoi | Où | Taille | Perdu = |
| --- | --- | --- | --- |
| Dépôts Git | `/data/git/gitea-repositories` | 16,5 Mo | la forge |
| Reste de `/data` | LFS, paquets, pièces jointes, avatars, artefacts Actions, index bleve | 9,3 Mo | contenus non-Git, réindexables sauf LFS et paquets |
| **`app.ini`** | `/data/gitea/conf/app.ini` | — | **cf. encadré** |
| Base PostgreSQL | `Cluster` CNPG `forgejo-db`, base `app`, rôle `app` | 17 Mo | métadonnées : issues, PR, comptes, droits |

Total : **43 Mo**. La volumétrie n'est pas le sujet ; l'ordre l'est.

> [!CAUTION]
> **`app.ini` est la pièce dont la perte ne se rattrape pas, et c'est aussi celle qu'on oublie.**
> Il porte **six** valeurs sensibles :
>
> | Clé | Section | Perdue ou changée = |
> | --- | --- | --- |
> | `SECRET_KEY` | `[security]` | tout ce qui est chiffré en base devient illisible |
> | `INTERNAL_TOKEN` | `[security]` | les appels internes échouent |
> | `JWT_SECRET` | `[oauth2]` | jetons OAuth2 invalides |
> | `LFS_JWT_SECRET` | `[server]` | objets LFS inaccessibles |
> | `PASSWD` | `[mailer]` | tous les envois refusés par Brevo |
> | `TOKEN` | `[metrics]` | scrape en 401 (cf. [forgejo §Métriques](../archive/forgejo/README.md#métriques)) |
>
> Ce n'est **pas** « repartir d'une base vide » : c'est garder des données qu'on ne sait plus
> déchiffrer. La règle qui en découle gouverne toute la §A : **on copie `/data` en entier, jamais
> les seuls dépôts.**

> [!NOTE]
> **Bonne nouvelle, et elle simplifie beaucoup la bascule : `app.ini` porte aussi TOUTE la
> configuration.** Le chart écrit dans ce fichier, au démarrage, l'intégralité du bloc
> `gitea.config` de `helm-values.yaml` — 2FA obligatoire, `INSTALL_LOCK`, inscription fermée,
> allowlists anti-SSRF, mailer, indexeur, métriques. Copier `/data` emporte donc la configuration
> avec les données. **Deux clés seulement changent** sur la cible (§A.4).

## Partie A — la bascule

### A.0 Préparer la cible (aucun impact sur la production)

> [!NOTE]
> **Le `compose.yaml` réel vit dans l'autre dépôt** : `homelab_emeriss/forgejo/`, avec son
> `.env.example`, son `Caddyfile` (§A.6) et son README. Le squelette ci-dessous en est l'extrait
> minimal, gardé ici pour que la procédure reste lisible seule.

Sur la machine hôte, Docker et le `compose.yaml` ci-dessous. **Ne rien démarrer avant §A.3.**

```yaml
# compose.yaml — squelette. Le reverse proxy est un troisième service, cf. §A.6.
services:
  forgejo:
    image: code.forgejo.org/forgejo/forgejo:15.0.7-rootless
    # ⚠️ Épingler la version EXACTE de la source. Une bascule et une montée de version en même
    # temps, c'est deux causes possibles pour un seul symptôme.
    restart: unless-stopped
    user: "1000:1000"
    volumes:
      - ./data:/data
    # ⚠️ AUCUN `ports:` — l'exposition passe par le proxy du §A.6, sinon les quatre en-têtes et le
    # blocage de `/metrics` sont court-circuités. C'est ce que fait le compose réel de
    # homelab_emeriss/forgejo/.
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:18
    # Même majeure que la source (CNPG : ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie).
    # ⚠️ Une majeure différente fait échouer le pg_restore du §A.3, ou pire : passer avec des
    # avertissements.
    restart: unless-stopped
    environment:
      # ⚠️ MÊMES nom de base et rôle que la source (`app` / `app`) : c'est ce qui limite les
      # retouches d'app.ini à DEUX clés. Un autre nom oblige à --no-owner au restore et à
      # réécrire davantage.
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: ${DB_PASSWORD:?}
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 10s
      timeout: 5s
      retries: 10
```

```bash
mkdir -p data pgdata
sudo chown -R 1000:1000 data     # l'image rootless tourne en uid 1000 (git)
```

### A.1 Geler la source

> [!WARNING]
> **`selfHeal` d'ArgoCD remonte un `scale --replicas=0` en quelques secondes.** Couper l'auto-sync
> des **quatre** applications d'abord — c'est le piège δ de [`forgejo-pra.md`](forgejo-pra.md), et
> il a déjà coûté un diagnostic.

```bash
for a in root app forgejo forgejo-monitoring; do
  kubectl -n argocd patch application $a --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# Couper l'accès utilisateur AVANT d'arrêter quoi que ce soit : côté Cloudflare (désactiver la
# règle d'ingress du tunnel) ou en retirant le HTTPRoute. Sans ça, un push arrivé entre le
# pg_dump et le tar produit un dépôt plus récent que sa ligne en base.

# Sauvegarde de ceinture, tant que le pod tourne encore : une archive autoportante
kubectl -n forgejo exec deploy/forgejo -- \
  forgejo dump --database postgres --type tar.gz --file - > forgejo-dump-$(date +%F).tar.gz

# Puis arrêter l'applicatif. La BASE reste debout : le pg_dump du §A.2 en a besoin.
kubectl -n forgejo scale deploy/forgejo --replicas=0
kubectl -n forgejo wait --for=delete pod -l app.kubernetes.io/name=forgejo --timeout=120s
```

⚠️ **Les deux artefacts ne font pas doublon.** `forgejo dump` produit une archive autoportante
(`app.ini`, `forgejo-db.sql`, `repos/`, `data/`, `custom/`, `log/` — vérifié dans `cmd/dump.go`)
mais son SQL est généré par xorm, pas par `pg_dump` : c'est du `INSERT` générique, restaurable
partout, moins fidèle. Le §A.2 prend la voie fidèle. À 43 Mo, faire les deux est gratuit.

### A.2 Extraire

```bash
# --- Base : pg_dump format custom, depuis l'instance CNPG encore debout ---
kubectl -n forgejo exec forgejo-db-1 -c postgres -- \
  pg_dump -U postgres -Fc -d app > forgejo-app.dump

# --- /data : le pod est à 0, un pod jetable monte le PVC ---
# ⚠️ Le PV est node-local (openebs-lvm-thin) : son nodeAffinity colle ce pod au bon nœud tout
#    seul. RWO, donc l'applicatif DOIT être à 0 — sinon le pod reste Pending sans le dire.
kubectl -n forgejo run pvc-tar --rm -i --restart=Never \
  --image=busybox:1.37 \
  --overrides='{"spec":{"containers":[{"name":"pvc-tar","image":"busybox:1.37",
    "command":["tar","-C","/","-czf","-","--exclude=data/lost+found","--exclude=data/tmp","data"],
    "stdin":true,"volumeMounts":[{"name":"d","mountPath":"/data"}]}],
    "volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"forgejo-data"}}]}}' \
  > forgejo-data.tar.gz

# Contrôles AVANT d'aller plus loin — une archive tronquée se voit ici, pas au §A.5
tar -tzf forgejo-data.tar.gz | grep -c . ; du -h forgejo-data.tar.gz forgejo-app.dump
tar -tzf forgejo-data.tar.gz | grep 'data/gitea/conf/app.ini'   # DOIT sortir une ligne
```

> [!CAUTION]
> **Le pod jetable est un geste impératif assumé**, au sens de
> [`regles-gitops.md`](regles-gitops.md) : périmètre jetable, hors ArgoCD, `--rm`. Il ne laisse
> rien derrière lui. Vérifier quand même : `kubectl -n forgejo get pod pvc-tar` doit être vide.

### A.3 Restaurer sur la cible

L'ordre compte : la base d'abord (Forgejo migre son schéma au démarrage s'il trouve une base
vide — et écraserait alors la restauration).

```bash
# 1. Les données, en préservant les droits
sudo tar -xzf forgejo-data.tar.gz -C /srv/forgejo --strip-components=1   # -> /srv/forgejo/data
sudo chown -R 1000:1000 /srv/forgejo/data

# 2. La base SEULE d'abord
docker compose up -d db
docker compose exec -T db pg_restore -U app -d app --clean --if-exists < forgejo-app.dump

# 3. app.ini : les deux retouches du §A.4, AVANT le premier démarrage

# 4. Forgejo
docker compose up -d forgejo
docker compose logs -f forgejo     # aucun « migrate » massif attendu : la base est déjà à jour
```

### A.4 Les deux clés à changer dans `app.ini`

`/srv/forgejo/data/gitea/conf/app.ini` — **tout le reste se copie tel quel**.

| Clé | Valeur k8s | Valeur Docker | Pourquoi |
| --- | --- | --- | --- |
| `[database] HOST` | `forgejo-db-rw:5432` | `db:5432` | service du `compose.yaml` |
| `[database] PASSWD` | secret CNPG `forgejo-db-app` | `${DB_PASSWORD}` du `.env` | CNPG génère le sien, il meurt avec le cluster |

Restent **volontairement inchangés**, et les changer casse quelque chose :

- `[server] ROOT_URL = https://forgejo.wittner.tech/` et `DOMAIN` — l'URL publique ne bouge pas.
- `[server] PROTOCOL = http` — TLS reste terminé **en amont** (proxy), comme il l'était au
  Gateway. Mettre `https` ferait attendre à Forgejo un certificat qu'il n'a pas.
- `[server] APP_DATA_PATH = /data`, `[repository] ROOT = /data/git/gitea-repositories` — mêmes
  chemins dans le conteneur, c'est ce qui rend la copie transposable telle quelle.
- `[metrics] ENABLED = true` et son `TOKEN` — cf. §A.6, le blocage change de main.
- Les six valeurs sensibles — **ne pas les régénérer**, c'est tout l'objet de la manœuvre.

Puis, une fois le conteneur debout :

```bash
# Les hooks Git portent des chemins absolus ; les régénérer après tout déplacement.
docker compose exec -u 1000 forgejo forgejo admin regenerate hooks
docker compose exec -u 1000 forgejo forgejo doctor check --all
```

### A.5 Vérifier — avant de basculer quoi que ce soit

Tout ceci se fait **pendant que le trafic public est encore coupé et que l'instance k8s existe
toujours**. Aucun de ces contrôles n'est décoratif : chacun échoue sur une erreur différente.

```bash
# Accès local, en se présentant sous le bon hostname
curl -sI -H 'Host: forgejo.wittner.tech' http://127.0.0.1:3000/ | head -3
```

| # | Contrôle | Ce qu'il prouve, et lui seul |
| --- | --- | --- |
| 1 | La page d'accueil liste les **11 dépôts** | la base et les dépôts se voient l'un l'autre |
| 2 | **Un jeton d'API existant** répond encore (`curl -H 'Authorization: token …' …/api/v1/user`) | `SECRET_KEY` et `INTERNAL_TOKEN` sont bien passés — **le contrôle le plus important de la liste** |
| 3 | Connexion au compte admin, **2FA demandée** | `app.ini` est celui de la source, pas un neuf |
| 4 | `git clone` en HTTPS d'un dépôt privé, avec jeton | droits et chemins de dépôts |
| 5 | Un fichier **LFS** se télécharge | `LFS_JWT_SECRET` |
| 6 | Une **issue** et une **PR** existantes s'ouvrent | la base est complète, pas seulement le schéma |
| 7 | `curl -H 'Authorization: Bearer <token>' localhost:3000/metrics` répond du texte Prometheus | `[metrics] TOKEN` intact |

⚠️ **Le contrôle 2 est le seul qui distingue « ça démarre » de « c'est la même instance ».** Une
forge repartie avec un `SECRET_KEY` neuf sert des pages parfaitement normales — jusqu'à ce qu'un
jeton, une session ou un objet LFS soit sollicité.

### A.6 Basculer l'entrée

Trois choses changent de main en même temps.

1. **Le reverse proxy sur l'hôte.** Le `shared-gw` faisait plus que router — il posait quatre
   en-têtes et interceptait `/metrics`. Tout est à reposer, sinon **deux protections tombent en
   silence** :

   | À reposer | Était où | Si oublié |
   | --- | --- | --- |
   | `Strict-Transport-Security: max-age=31536000; includeSubDomains` | filtre `ResponseHeaderModifier` du HTTPRoute | dégradation HTTPS possible |
   | `X-Content-Type-Options: nosniff` | idem | décisif sur une forge qui sert des fichiers téléversés |
   | `X-Frame-Options: SAMEORIGIN` | idem | clickjacking |
   | `Referrer-Policy: strict-origin-when-cross-origin` | idem | un chemin de dépôt privé fuite dans le `Referer` |
   | **Blocage de `/metrics`** | règle `PathType: Exact` → redirection 302 | ⚠️ l'endpoint redevient **joignable depuis Internet**, protégé par le seul token |

   ⚠️ `[metrics] ENABLED` reste à `true` après la copie d'`app.ini`. **Le blocage au proxy n'est
   pas optionnel** : c'était la couche 2 sur trois, et la couche 3 (CiliumNetworkPolicy) n'existe
   plus du tout. Cf. [forgejo §Métriques](../archive/forgejo/README.md#métriques).

2. **Le tunnel Cloudflare** : l'origine passe de `192.168.1.50` (Traefik → `shared-gw`) à l'hôte
   Docker. ⚠️ Depuis le LAN, le DNS interne sert `192.168.1.50` pour **tout** `*.wittner.tech` :
   **un test local ne prouve rien sur le chemin externe.** C'est le piège de diagnostic principal
   de cette section, et il a déjà coûté plusieurs fausses pistes
   (cf. [forgejo §Réseau](../archive/forgejo/README.md#réseau)).

3. **Renovate** : le bot joignait `forgejo-http` en interne. Il passe par le hostname.

### A.7 Revenir en arrière

⚠️ **Ce retour n'est plus disponible depuis le 2026-09-11** : le §A.8 est fait, le composant est
archivé et le namespace `forgejo` n'existe plus. Remonter dans le cluster demanderait une
restauration complète, pas un `scale`. La procédure est conservée telle qu'elle était valable.

Tant que le §A.8 n'est pas fait, le retour coûte deux commandes — c'est la raison d'être du délai.

```bash
docker compose stop forgejo                 # une seule instance écrit, JAMAIS deux
kubectl -n forgejo scale deploy/forgejo --replicas=1
for a in root app forgejo forgejo-monitoring; do
  kubectl -n argocd patch application $a --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done
# puis repointer le tunnel sur 192.168.1.50
```

> [!CAUTION]
> **Deux instances qui écrivent dans deux bases, c'est une divergence, pas une redondance.** Dès
> que la cible sert du trafic, revenir en arrière veut dire **perdre** ce qui a été écrit depuis.
> D'où l'ordre : `stop` d'abord, remontée ensuite.

### A.8 Démonter — pas avant

**Garder l'instance k8s arrêtée mais intacte au moins 30 jours**, et ne rien détruire avant que le
§B ait produit **une restauration réussie** (§B.5). Le PVC est protégé du prune
(`helm.sh/resource-policy: keep`) : l'arrêt ne détruit rien tout seul.

Ce n'est qu'après que se retirent, dans cet ordre : les `Application` forgejo et
forgejo-monitoring, le namespace, puis les entrées `dashboard-forgejo.yaml` et
`servicemonitor` — et que se pose la question du §« Ce que la bascule fait perdre ».

> [!IMPORTANT]
> **Fait le 2026-09-11, avec deux écarts par rapport au texte ci-dessus.** Le composant est passé
> dans [`archive/forgejo/`](../archive/forgejo/README.md) en `forgejo.noapp.yaml` : l'`Application`
> sort du glob des tiers-2, ArgoCD la prune, et son finalizer emporte ce qu'elle gérait —
> namespace `forgejo`, `Cluster` CNPG `forgejo-db`, HTTPRoute publique, CiliumNetworkPolicy,
> `ObjectStore` et `ScheduledBackup`.
>
> ⚠️ **Le PVC `forgejo-data` part avec le namespace.** `helm.sh/resource-policy: keep` protège du
> prune de Helm, pas de la destruction du namespace qui contient le volume. Ce qui subsiste de la
> forge est donc ce que le §B a mis à l'abri sur la machine Docker, plus les backups velero et
> barman-cloud déjà écrits — jusqu'à expiration de leur TTL de 30 jours, et pas un jour de plus.
>
> Les deux écarts :
> - **`forgejo-monitoring` n'a PAS été retiré** : il a été *retourné vers l'extérieur*. Il porte
>   maintenant une `ScrapeConfig` sur `https://forgejo-metrics.lan.wittner.tech/metrics` (ns
>   `monitoring`) et deux alertes bâties sur `up{job="forgejo"}` — cf.
>   [`cluster/app/forgejo-monitoring`](../cluster/app/forgejo-monitoring/README.md) ;
>   ⚠️ **Complété le même jour, après coup** : la bascule laissait un trou que ce bilan ne voyait
>   pas. Elle a supprimé les deux seules sources qui parlaient d'autre chose que de l'application —
>   le DaemonSet node-exporter (l'HÔTE) et les métriques CNPG (la BASE) — sans rien mettre à la
>   place. Le disque de la machine Docker n'était donc surveillé par personne, alors que dépôts,
>   base et dumps s'y partagent un seul stockage. Deux scrapes de plus et treize alertes de plus
>   l'ont fermé, appuyés sur deux exportateurs côté `homelab_emeriss`.
>   ⚠️ **Mais PAS dans le même composant** : le volet base (`job="forgejo-db"`) a rejoint
>   `forgejo-monitoring`, le volet machine (`job="external-node"`) un composant NEUF,
>   [`cluster/app/hosts-monitoring`](../cluster/app/hosts-monitoring/README.md). Le critère est le
>   cycle de vie : une machine précède le service qu'elle héberge et lui survit, alors qu'un
>   exportateur de base meurt avec sa base. Le même critère a produit deux PILES distinctes côté
>   `homelab_emeriss` (`node-exporter/` et `forgejo/`).
>   ⚠️ Une dépendance à sens unique en résulte, et elle n'est vérifiée par rien : les trois alertes
>   de sauvegarde de `forgejo-monitoring` lisent des séries qui arrivent par le scrape de
>   `hosts-monitoring` (collecteur `textfile` de node-exporter) ;
> - **`dashboard-forgejo.yaml` a été GARDÉ**, amputé de ses deux panneaux Kubernetes (PVC et
>   redémarrages) et repointé sur le job `forgejo`. Le `ServiceMonitor`, lui, est bien parti — il
>   n'avait plus de Service à sélectionner.
>
> Trois conséquences en dehors du composant, toutes documentées sur place : la schedule velero est
> **désactivée** (la forge était son seul périmètre), les deux alertes de fraîcheur velero et les
> deux alertes `absent(...)` de cnpg-monitoring sont **commentées** (elles sonneraient sans fin),
> et le bot Renovate Forgejo pointe désormais l'URL publique.

## Partie B — sauvegarder la cible

### B.1 Ce que `forgejo dump` contient

Vérifié dans `cmd/dump.go` (v15.0.7), pas supposé :

| Entrée de l'archive | Source | Ligne |
| --- | --- | --- |
| `app.ini` | `setting.CustomConf` | 334 |
| `forgejo-db.sql` | dump xorm (`--database postgres`) | 524 |
| `repos/` | `RepoRootPath` | 532 |
| `data/` | `AppDataPath` (LFS, paquets, pièces jointes, index) | 458 |
| `custom/` | `CustomPath` | 469 |
| `log/` | `Log.RootPath` | 396 |

Un seul fichier emporte donc **tout ce qui est irremplaçable, `app.ini` compris**. C'est mieux que
la chaîne k8s, où les secrets cryptographiques sont un objet séparé à sceller à la main.

Options utiles : `--skip-index` (l'index bleve se reconstruit), `--skip-log`,
`--skip-repo-archives` (les archives `.zip` se refabriquent).

### B.2 Le script

À poser en `script/forgejo-backup.sh` **sur l'hôte Docker** — pas dans ce dépôt, qui décrit le
cluster.

```bash
#!/usr/bin/env bash
set -euo pipefail
# Sauvegarde quotidienne de la forge. Cible : bucket GCS, chiffré.
cd /srv/forgejo
STAMP=$(date +%F-%H%M)

# 1. Dump applicatif (voir B.1). --skip-index : l'index bleve se reconstruit.
docker compose exec -T -u 1000 forgejo \
  forgejo dump --database postgres --type tar.gz --skip-index --file - \
  > "/var/backups/forgejo/dump-${STAMP}.tar.gz"

# 2. Dump base FIDÈLE en plus du SQL xorm de l'archive : c'est la voie de restauration
#    privilégiée tant que la cible reste PostgreSQL.
docker compose exec -T db pg_dump -U app -Fc -d app \
  > "/var/backups/forgejo/db-${STAMP}.dump"

# 3. Envoi. Deux voies, choisir UNE (cf. B.3).
restic -r "gs:<bucket>:/forgejo" backup /var/backups/forgejo
restic -r "gs:<bucket>:/forgejo" forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

### B.3 Les quatre pièges

> [!CAUTION]
> **1. L'archive est en clair.** Elle contient `SECRET_KEY`, les jetons de session, les jetons
> d'API et **tous les dépôts privés**. Un bucket privé n'est qu'une couche. `restic` chiffre par
> construction — c'est la raison principale de le préférer, avant même la déduplication.

> [!WARNING]
> **2. `rsync` ne parle pas à un bucket.** `rsync(1)` fait du SSH. Vers GCS il faut
> `gcloud storage rsync`, `rclone` ou `restic`. Le nom identique de la sous-commande `gcloud` prête
> à confusion : ce n'est pas le même outil.

> [!WARNING]
> **3. Un miroir propage les suppressions.** `rsync --delete` ou `gcloud storage rsync` sur un
> répertoire local corrompu, vidé ou monté de travers **efface la copie distante**. Si la voie
> retenue est le miroir plutôt que `restic`, alors le **versioning du bucket** est obligatoire, pas
> recommandé.

> [!NOTE]
> **4. `forgejo dump` ne pose aucun verrou.** Base et dépôts sont pris à quelques secondes d'écart.
> Sur ce volume (43 Mo, un utilisateur) c'est sans conséquence — mais un `push` pendant le dump
> donne un dépôt plus récent que sa ligne en base. Sauvegarder aux heures creuses suffit ; arrêter
> le conteneur le temps du dump est la version stricte.

### B.4 Restaurer — la seule partie qui compte

> [!CAUTION]
> **Il n'existe pas de `forgejo restore`.** Le dump est à sens unique. La restauration est la
> séquence manuelle ci-dessous, et **rien ne la vérifie à votre place**.

```bash
restic -r "gs:<bucket>:/forgejo" snapshots
restic -r "gs:<bucket>:/forgejo" restore <id> --target /tmp/restore

tar -xzf /tmp/restore/var/backups/forgejo/dump-<STAMP>.tar.gz -C /tmp/dump

docker compose down
sudo rm -rf /srv/forgejo/data && sudo mkdir -p /srv/forgejo/data
sudo cp -a /tmp/dump/data/.   /srv/forgejo/data/          # AppDataPath
sudo cp -a /tmp/dump/repos    /srv/forgejo/data/git/gitea-repositories
sudo cp -a /tmp/dump/custom/. /srv/forgejo/data/gitea/
sudo cp /tmp/dump/app.ini /srv/forgejo/data/gitea/conf/app.ini
sudo chown -R 1000:1000 /srv/forgejo/data

docker compose up -d db
docker compose exec -T db pg_restore -U app -d app --clean --if-exists < db-<STAMP>.dump
docker compose up -d forgejo
docker compose exec -u 1000 forgejo forgejo admin regenerate hooks
docker compose exec -u 1000 forgejo forgejo doctor check --all
```

Puis **les sept contrôles du §A.5**, sans en sauter un — en particulier le n°2.

### B.5 L'exercice

Même logique que [`forgejo-pra-exercice.md`](forgejo-pra-exercice.md), en plus léger : restaurer
le dernier snapshot dans un `compose.yaml` **parallèle** (autre port, autre répertoire, base
séparée), passer les sept contrôles, détruire.

- **Une fois par trimestre**, et **immédiatement après la bascule** — le premier passage fait
  partie du §A, pas du régime courant.
- Tenir le journal des passages dans cette page, comme le fait l'exercice k8s. Une procédure
  jamais jouée est une intention.

| Date | Snapshot | Résultat | Ce qui a surpris |
| --- | --- | --- | --- |
| — | — | *(aucun passage à ce jour)* | — |

## Ce que la bascule fait perdre

À accepter explicitement, pas à découvrir après.

| Capacité | Aujourd'hui (k8s) | Après (Docker) |
| --- | --- | --- |
| **PITR de la base** | archivage WAL continu vers GCS, reprise **à la seconde** | dump quotidien → jusqu'à **24 h** perdues |
| Sauvegarde des objets | velero, namespace entier restaurable | néant : le `compose.yaml` versionné en tient lieu |
| Alertes | `ForgejoDown`, `ForgejoDeploymentMissing` (kube-state-metrics) | **mortes**. Reste à écrire une sonde sur l'hôte |
| Dashboard « Forge — forgejo » | ServiceMonitor in-cluster | **survit** si le cluster reste debout : `scrape_config` statique vers l'IP LAN, même token Bearer, séries `gitea_*` identiques |
| Anti-SSRF réseau | `CiliumNetworkPolicy` (egress LAN refusé) | moitié applicative seulement (`ALLOW_LOCALNETWORKS`, `ALLOWED_HOST_LIST`) — l'autre moitié demande un pare-feu hôte |
| Blocage de `/metrics` | 3 couches | **1 seule** (le token) tant que le proxy du §A.6 n'est pas posé |
| Redémarrage automatique | `Deployment`, `selfHeal` | `restart: unless-stopped` |
| PRA éprouvé | 100 Ko de procédure, 10 passages | **cette page, jamais jouée** |

La dernière ligne est le vrai coût. Tout le reste se rachète en quelques heures.
