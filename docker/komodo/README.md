# komodo — gestionnaire des piles de l'hôte

[Komodo](https://komo.do) v2 : une UI qui voit les conteneurs, leurs journaux et leur consommation,
et qui **déploie les autres piles de ce dépôt** depuis GitHub. Trois conteneurs :

| Service | Rôle | Port publié |
|---|---|---|
| `mongo` | Base de Komodo : configuration, comptes, jeton GitHub, historique | aucun |
| `core` | UI + API | `9120/tcp` sur l'IP LAN |
| `periphery` | Agent sur l'hôte : socket Docker, `docker compose` | aucun (il se connecte **vers** Core) |

Procédure amont : <https://komo.do/docs/setup/mongo>. Ce qui en diverge, et pourquoi, est en tête de
[`compose.yaml`](compose.yaml).

> [!CAUTION]
> **Komodo est un root distant.** Periphery monte la socket Docker, et les terminaux de l'UI sont
> **activés** (choix assumé) : un compte Komodo compromis ouvre un shell root sur l'hôte. D'où :
> exposition **LAN seule** (`komodo.lan.wittner.tech`, aucune entrée cloudflared), inscription
> fermée, et `.env` en `0600`. Pour fermer les terminaux : `PERIPHERY_DISABLE_TERMINALS` et
> `PERIPHERY_DISABLE_CONTAINER_TERMINALS` à `"true"` dans [`compose.yaml`](compose.yaml), puis
> `bin/redeploy komodo`.

## Qui déploie quoi

| Pile | Déployée par | Geste après un merge |
|---|---|---|
| `node-exporter/`, `cadvisor/` | **Komodo**, déclarées dans [`sync/piles.toml`](sync/piles.toml) | **aucun** — la procédure `deploiement-auto` déploie dans les 15 min |
| `komodo/` | **`bin/redeploy komodo`** | `git pull && bin/redeploy komodo` sur l'hôte |

⚠️ **Komodo ne pilote pas sa propre pile** : un Core qui redéploie son compose s'arrête au milieu de
l'opération qu'il conduit. Et **`bin/redeploy` refuse les piles de `sync/`** — il lit leurs
`run_directory` — parce que deux outils qui lancent `docker compose up` sur le même projet, depuis
deux clones différents, se volent les conteneurs à chaque passage.

⚠️ **Tout merge sur `main` part en production dans le quart d'heure.** La procédure
`deploiement-auto` (déclarée en bas de [`sync/piles.toml`](sync/piles.toml)) joue la Resource Sync
toutes les 15 min ; une pile dont le `compose.yaml` ou la config a changé est redéployée. Renovate
**automerge** les correctifs et mineures de ces piles ([`renovate.json`](../../renovate.json) à la
racine) : une release passe donc en production à J+7 sans personne — c'est voulu, comme sous
ArgoCD. Aucun webhook GitHub (Komodo n'est pas joignable depuis Internet), aucune « auto update »
d'image : c'est le dépôt qui décide, pas le registre.

⚠️ **Sauf Komodo lui-même** : sa pile n'est pas dans la sync, et `renovate.json` lui **refuse**
l'automerge (`docker/komodo/**`). Un automerge ferait déclarer au dépôt une version que l'hôte ne
fait pas tourner, et l'écart ne se verrait qu'au prochain `bin/redeploy`, longtemps après.

**Suspendre l'auto-déploiement** (incident, opération à la main) : *Procedures* →
`deploiement-auto` → décocher *Schedule enabled*. Le prochain **Execute** de la sync remet la valeur
du dépôt ; pour une suspension qui dure, `schedule_enabled = false` dans `sync/piles.toml`.

⚠️ **Les piles pilotées ne lisent plus leur `.env`.** Komodo clone le dépôt dans
`/srv/komodo/periphery/stacks/<pile>/` et y écrit le `.env` à partir du champ `environment` de
[`sync/piles.toml`](sync/piles.toml). Les `.env` du clone `/opt/homelab/homelab_gitops` de ces
piles ne servent plus ; leurs `.env.example` restent la documentation des variables.

⚠️ **Komodo lit tout le dépôt**, `k8s/` compris : son clone est celui de `homelab_gitops` entier.
Il n'en exécute que `docker/` (le *Resource path* de la sync et les `run_directory`), et les
secrets de `k8s/` sont scellés — mais le jeton GitHub de Komodo ouvre le dépôt du cluster.

## Prérequis d'hôte

Tout est au [bootstrap](../doc/bootstrap-debian.md) : AVX (§6, MongoDB ≥ 5 ne démarre pas sans),
arborescence `/srv/komodo` en `0700 root` (§5.2). Rien d'autre — pas de paquet.

## Mise en service

### 1. `.env`, sur l'hôte

```bash
cd ~/homelab
(umask 077; cp komodo/.env.example komodo/.env)
git check-ignore -v komodo/.env           # DOIT répondre
```

Les quatre secrets se génèrent et se collent **sans passer par la ligne de commande** : un secret en
argument est lisible dans `ps` et reste dans l'historique du shell.

```bash
# Génère un secret par ligne, à l'écran — à recopier dans komodo/.env avec un éditeur.
for _ in 1 2 3 4; do openssl rand -base64 33 | tr -d '/+=' | cut -c1-40; done
${EDITOR:-nano} komodo/.env               # LISTEN_ADDR, puis les 4 secrets
stat -c '%a' komodo/.env                  # 600
```

⚠️ `KOMODO_INIT_ADMIN_PASSWORD` : le noter dans le gestionnaire de mots de passe **avant** le
démarrage, c'est celui de la première connexion.

### 2. Démarrage

```bash
bin/redeploy komodo
docker compose -f komodo/compose.yaml ps            # trois services « running »
docker compose -f komodo/compose.yaml logs periphery | grep -i connect
sudo ls /srv/komodo/keys                            # core.key core.pub periphery.key periphery.pub
```

⚠️ Si `mongo` redémarre en boucle avec le code **132** : pas d'AVX — cf. bootstrap §6.

### 3. Route Traefik — autre dépôt

`homelab_ysera/traefik/dynamic/komodo.yaml` : `komodo.lan.wittner.tech` → `http://192.168.1.15:9120`.
Commité là-bas, il est servi aussitôt (le CT 201 monte le répertoire). En attendant, l'UI répond sur
`http://192.168.1.15:9120` — en clair, à n'utiliser que le temps de la mise en service.

### 4. Première connexion

`https://komodo.lan.wittner.tech`, compte `KOMODO_INIT_ADMIN_USERNAME`. Vérifier :

- *Servers* : `vert-emeriss` est **vert** (Periphery connecté).
- *Procedures* : « Backup Core Database » existe, planifiée chaque jour à 01:00.

### 5. Jeton GitHub — lecture seule, un seul dépôt

Sur GitHub : *Settings → Developer settings → Fine-grained tokens → Generate new token*.

- *Repository access* : **Only select repositories** → `jbwittner/homelab_gitops`.
- *Permissions* : **Contents → Read-only**. Rien d'autre (*Metadata* s'ajoute seul).
- Expiration : un an, et un rappel dans l'agenda — un jeton expiré ne casse rien de visible, sauf
  que la sync cesse de voir les nouveaux commits — et la procédure `deploiement-auto` passe en
  échec à chaque quart d'heure (`failure_alert`).

Dans Komodo : *Settings → Providers → Git → github.com* → compte `jbwittner`, coller le jeton.
⚠️ Le nom de compte doit être **`jbwittner`** : c'est le `git_account` de
[`sync/piles.toml`](sync/piles.toml).

⚠️ **Pas un jeton classique** (`ghp_…`) : il ouvrirait tous les dépôts du compte. Même raisonnement
que la clé de déploiement du bootstrap §5.1. Le jeton vit dans la base Mongo (et donc dans ses
sauvegardes, cf. plus bas).

### 6. Resource Sync — la seule ressource créée à la main

*Syncs → New* : nom **`homelab_gitops`** — c'est le nom qu'appelle la procédure `deploiement-auto`, à
ne pas changer sans elle. Puis :

| Champ | Valeur |
|---|---|
| Source | Git Repo |
| Git provider / account | `github.com` / `jbwittner` |
| Repo / branch | `jbwittner/homelab_gitops` / `main` |
| Resource paths | `docker/komodo/sync` — chemin depuis la racine du dépôt, pas depuis `docker/` |
| Include variables | **activé** — sinon `[[EMERISS_LAN_IP]]` reste littéral |
| Delete unmatched | **désactivé** — sinon la sync supprimerait les ressources par défaut (procédures) |
| Managed mode | désactivé — l'UI n'écrit pas dans le dépôt, le dépôt écrit dans l'UI |

**Refresh**, puis lire le diff : il doit annoncer **1 variable, 2 stacks et 1 procédure à créer, 2 stacks à
déployer**.
**Execute**.

⚠️ **Le premier Execute recrée les conteneurs** des deux exportateurs — quelques secondes sans
métriques. Komodo adopte le projet compose existant (même `project_name`), mais le relance depuis
**son** clone. Contrôle immédiat :

```bash
docker inspect cadvisor-nginx-1 --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep cadvisor.conf
#   /srv/komodo/periphery/stacks/cadvisor/docker/cadvisor/nginx/cadvisor.conf
#   (et NON /opt/homelab/... : sinon le conteneur vient encore de bin/redeploy)
curl -sI http://192.168.1.15:8080/metrics | head -1   # 401 — l'authentification mord toujours
curl -sI http://192.168.1.15:9100/metrics | head -1   # 401
```

## Mise à jour

**Piles pilotées** (Renovate sur `node-exporter`, `cadvisor`) : rien à faire. La PR s'automerge
(correctifs, mineures) et `deploiement-auto` la déploie dans le quart d'heure. Pour ne pas attendre :
*Syncs → homelab_gitops* → **Refresh** → **Execute**. Une majeure attend un merge à la main, puis
part de la même façon.

**Komodo lui-même** (`komodo-core` + `komodo-periphery`, une seule PR groupée) :

```bash
cd ~/homelab && git pull --ff-only
bin/redeploy komodo
```

⚠️ Une **majeure** de Komodo ou **toute** montée de `mongo` attend une approbation dans le dashboard
Renovate. Avant de l'approuver : **sauvegarde à la main** (*Procedures → Backup Core Database →
Run*), et pour mongo, lire les notes de compatibilité — MongoDB ne saute pas de majeure (8.0 → 9.0
oblige à poser `setFeatureCompatibilityVersion` à `"8.0"` d'abord, cf. la doc MongoDB de la cible).

## Bascule depuis `homelab_emeriss` — 2026-10-22

Ces piles vivaient dans un dépôt à part, `homelab_emeriss`, lu par une Sync du même nom. Le dépôt
est archivé ; la bascule, jouée une fois, se fait dans cet ordre :

1. **Clé de déploiement** : la retirer de `homelab_emeriss` et l'ajouter à `homelab_gitops`, en
   lecture seule (cf. [bootstrap §5.1](../doc/bootstrap-debian.md)).
2. **Clone de l'hôte** : `git clone github-homelab:jbwittner/homelab_gitops.git
   /opt/homelab/homelab_gitops`, recopier `komodo/.env` (`0600`) de l'ancien clone, puis
   `ln -sfn /opt/homelab/homelab_gitops/docker ~/homelab` et `bin/redeploy komodo` — le projet
   s'appelle toujours `komodo`, les conteneurs sont repris.
3. **Jeton GitHub** : un nouveau, limité à `homelab_gitops` (§5), saisi à la place de l'ancien.
4. **Nouvelle Sync** `homelab_gitops` (§6). Le diff annonce **2 stacks modifiées** (`repo`,
   `run_directory`) et **1 procédure à créer** ; la variable est déjà là. **Execute**, puis le
   contrôle du §6 — avec le chemin `stacks/cadvisor/docker/cadvisor/…`.
5. **Supprimer la Sync `homelab_emeriss`** (*delete unmatched* étant désactivé, elle ne retire
   rien en partant), révoquer l'ancien jeton, puis `rm -rf /opt/homelab/homelab_emeriss`.

## Sauvegarde

La procédure **« Backup Core Database »** (créée au premier démarrage, chaque jour à 01:00) dépose un
dump gzip daté dans `/srv/komodo/backups/`, et garde les **14** derniers.

> [!WARNING]
> **Même disque que la base**, et **non chiffré**. Cela protège d'une fausse manipulation (sync
> qui supprime, configuration écrasée), **pas d'une perte de l'hôte**. Le dump contient le jeton
> GitHub et les hachages des comptes : le répertoire est en `0700 root`, et toute copie hors de
> l'hôte doit être chiffrée d'abord. Aucune copie hors hôte n'est en place aujourd'hui.

Ce qui est perdu sans sauvegarde, et ce qui ne l'est pas : la **déclaration des piles** est dans ce
dépôt (`sync/piles.toml`) — une base vide plus un *Execute* la reconstruit. Ce qui manque alors :
comptes, jeton GitHub, historique des déploiements. Reconstituables à la main en dix minutes.

Restauration : <https://komo.do/docs/setup/backup#restore> (conteneur `komodo-cli`,
`km database restore`). ⚠️ La restauration **ne vide pas** la base cible : restaurer dans une base
neuve, ou la vider avant.

## Opérations

```bash
docker compose -f ~/homelab/komodo/compose.yaml logs -f core
docker compose -f ~/homelab/komodo/compose.yaml exec mongo mongosh --quiet --eval 'db.runCommand({ping:1})'
```

**Rotation du mot de passe de la base** — le `.env` seul ne suffit pas, MongoDB ne relit
`MONGO_INITDB_*` qu'à la création :

```bash
# 1. Dans la base, en saisissant l'ancien puis le nouveau mot de passe (jamais en argument) :
docker compose -f ~/homelab/komodo/compose.yaml exec mongo \
  mongosh -u komodo --authenticationDatabase admin admin \
  --eval 'db.changeUserPassword("komodo", passwordPrompt())'
# 2. Puis KOMODO_DATABASE_PASSWORD dans komodo/.env, et :
bin/redeploy --no-pull komodo   # options AVANT la pile
```

**Clés Core ↔ Periphery perdues** (`/srv/komodo/keys` vidé) : `bin/redeploy --no-pull komodo`
les régénère. Si *Servers → vert-emeriss* reste rouge ensuite, c'est que le Server attend encore
l'ancienne clé publique : la corriger dans sa configuration. Rien n'est perdu côté piles — les
conteneurs tournent sans Komodo.
