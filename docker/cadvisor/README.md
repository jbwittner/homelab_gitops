# cadvisor — supervision des conteneurs

## Rôle

Expose la consommation **par conteneur** (CPU, mémoire, réseau, E/S bloc, événements OOM) sur
`https://cadvisor-emeriss.lan.wittner.tech/metrics`, où elle est scrutée **depuis le cluster**.
Rien ne les lit ici : cette pile n'a ni Prometheus ni Grafana.

C'est le second étage de la supervision de cette machine :

| Pile | Mesure | Répond à |
| --- | --- | --- |
| [`node-exporter/`](../node-exporter/README.md) | la **machine** | « il reste combien de disque, de RAM ? » |
| `cadvisor/` | les **conteneurs** | « **qui** consomme ? » |

`node-exporter` dit qu'il reste 8 Go de RAM, jamais qui les a pris. C'est le trou que cette pile
comble, et le seul — si la question est « est-ce qu'un conteneur est tombé », les healthchecks du
compose y répondent déjà.

## Pourquoi une pile à part

Même critère que `node-exporter/` : le **cycle de vie**. Ce qui est mesuré ici appartient au démon
Docker de la machine — ça précède toute pile applicative et ça lui survit. Rangée dans le compose
d'une autre pile, elle serait arrêtée par son `docker compose down`, c'est-à-dire **pendant
l'incident qu'on veut voir**.

## ⚠️ Pourquoi DEUX conteneurs

**cAdvisor ne sait pas authentifier `/metrics`.** Ce n'est pas un réglage oublié, c'est une
propriété du programme — vérifié dans la source de la `v0.55.1` :

- `--http_auth_file` / `--http_digest_file` n'enveloppent que les **pages de l'UI web** et les
  ressources statiques (`cmd/internal/http/handlers.go`). Les deux drapeaux le disent eux-mêmes :
  *« HTTP auth file for the web UI »*.
- `/metrics` est posé par `RegisterPrometheusHandler` avec un `http.HandlerFunc` **nu**, qui ne
  passe jamais par l'authenticator.
- `/api/v1.3/...` est pire : enregistré **avant** que l'authenticator n'existe. L'API JSON donne les
  variables d'environnement, les commandes et les points de montage de chaque conteneur.

Posé seul sur l'IP LAN, cAdvisor livrerait donc tout cela à qui interroge le port — nettement plus
que `node-exporter`, dont on a jugé utile de fermer l'accès.

D'où la disposition :

```
                      LAN
                       │
                       │  192.168.1.15:8080   ← le SEUL port ouvert
                       ▼
                   ┌────────┐
                   │ nginx  │  auth_basic + 404 sur tout sauf /metrics
                   └────┬───┘
                        │  réseau privé du compose
                        ▼
                   ┌──────────┐
                   │ cAdvisor │  AUCUN `ports:` — injoignable depuis le LAN
                   └──────────┘
```

⚠️ **C'est l'absence de `ports:` sur cAdvisor qui fait tout le travail.** Le jour où quelqu'un en
ajoute un « pour déboguer », l'UI et l'API repartent sur le LAN sans authentification.

⚠️ **Ne pas « simplifier » en publiant cAdvisor et en posant un `basicAuth` côté Traefik.** Traefik
est sur une autre machine : pour qu'il joigne l'exportateur, le port devrait être publié sur l'IP
LAN, donc joignable directement, donc contournable. Un middleware ne couvre que le chemin qui passe
par lui.

## Fichiers

- `compose.yaml` — les deux services, tags d'image **en dur** (Renovate)
- `.env.example` — `LISTEN_ADDR`, `LISTEN_PORT`. Aucun secret
- `nginx/cadvisor.conf` — la conf du mandataire. ⚠️ **Montée depuis le dépôt**, pas recopiée sur
  l'hôte : elle ne porte aucun secret, donc pas de copie de référence à faire diverger
- `monitoring/htpasswd.example` — copie de référence de `/etc/cadvisor/htpasswd`. ⚠️ **Fichier
  d'hôte, à poser AVANT le premier `up`**
- ⚠️ **Pas de `traefik/` dans cette pile, et c'est délibéré.** La règle du reverse-proxy vit dans
  **`homelab_ysera/traefik/dynamic/cadvisor-emeriss.yml`**, le seul exemplaire qui existe — celui que Traefik
  charge, par le montage `mp0` du CT 201. Ce dépôt n'en garde AUCUNE copie et n'en a jamais
  gardé : le fichier y a été écrit, puis déposé là-bas le 11 septembre 2026, le jour où les copies
  des autres piles ont été retirées. **Ne pas en créer une.**
  ⚠️ **Couplage à tenir** : l'URL du service là-bas et `LISTEN_ADDR`/`LISTEN_PORT` du `.env` d'ici
  sont **la même valeur vue de deux dépôts**.

⚠️ **Le nom porte celui de la machine** — `cadvisor-emeriss`. Même raison que
`node-exporter-emeriss` : cette pile est duplicable telle quelle sur un autre hôte, et un nom
générique ferait collision au premier second exportateur — dans les noms de routeurs de Traefik,
qui sont **globaux**, et dans la règle `Host(...)`. Le résolveur, lui, n'est pas concerné : il
répond pour tout `*.wittner.tech` sans rien savoir des noms.

## Mise en service

```bash
# 1. Le fichier d'authentification, D'ABORD — un bind sur un chemin absent fait créer un
#    RÉPERTOIRE par Docker, et nginx échoue alors sur une erreur de lecture.
sudo install -d -m 700 -o root -g root /etc/cadvisor
sudo install -D -m 0644 -o root -g root \
  cadvisor/monitoring/htpasswd.example /etc/cadvisor/htpasswd

# ⚠️ FORME DIFFÉRENTE de celle de node-exporter : ici on veut la ligne COMPLÈTE
#    `prometheus:$2y$12$...`, pas le hachage nu. Le mot de passe est le MÊME que le sien.
htpasswd -nBC 12 prometheus          # mot de passe à la frappe
sudo tee /etc/cadvisor/htpasswd >/dev/null <<<'<la ligne complète collée ici>'
sudo chmod 0644 /etc/cadvisor/htpasswd

# 2. La pile — ⚠️ c'est KOMODO qui la déploie, pas `docker compose` ni `bin/redeploy` (qui la
#    refuse). Déclarée dans `komodo/sync/piles.toml`, avec son `.env` (champ `environment`) :
#    déployée par la procédure `deploiement-auto` (≤ 15 min). Cf. komodo/README.md. Le `.env.example` reste la
#    documentation des variables ; un `.env` dans ce répertoire n'est plus lu.

# 3. Vérifier — l'authentification DOIT mordre, et le reste DOIT être fermé
curl -sI  http://<LISTEN_ADDR>:8080/metrics              # attendu : 401
curl -sI  http://<LISTEN_ADDR>:8080/containers/          # attendu : 404 (l'UI ne sort pas)
curl -sI  http://<LISTEN_ADDR>:8080/api/v1.3/containers  # attendu : 404 (l'API non plus)
curl -s -u prometheus:<motdepasse> http://<LISTEN_ADDR>:8080/metrics | head -3
```

Puis, **dans `homelab_ysera`**, vérifier que `traefik/dynamic/cadvisor-emeriss.yml` porte l'IP LAN
réelle de cet hôte. **Rien à faire côté DNS** : AdGuard réécrit `*.wittner.tech` vers
`192.168.1.50` par une règle générique, donc `cadvisor-emeriss.lan.wittner.tech` résout
déjà — y compris avant que le routeur existe.

⚠️ **« Ça résout » ne prouve donc rien.** Un nom sans routeur reçoit le 404 par défaut de Traefik,
et le symptôme, vu du cluster, est une cible Prometheus en erreur — indiscernable d'une panne de
réseau. Le seul fait qui fasse exister ce nom est le fichier ci-dessus.

## Contraintes

- **L'absence de `ports:` sur cAdvisor est load-bearing.** C'est elle, et rien d'autre, qui empêche
  l'UI web et l'API JSON d'atteindre le LAN.
- **La cardinalité est bridée exprès.** `--store_container_labels=false` est le réglage qui compte :
  par défaut cAdvisor convertit chaque label de conteneur en label Prometheus, et compose en pose un
  (`com.docker.compose.config-hash`) qui **change à chaque modification du compose**. Chaque
  `docker compose up` créerait alors une série neuve, et les anciennes ne meurent jamais. C'est le
  mode de panne classique de cAdvisor sur un Prometheus.
- **`--disable_metrics` REMPLACE la liste par défaut, il ne s'y ajoute pas.** D'où la liste longue
  dans le `compose.yaml` : elle reprend les désactivations par défaut *plus* les quatre ajoutées.
  En retirer une au hasard réactive donc aussi tout le défaut.
- **Pas de `privileged: true`**, contrairement à l'exemple amont. Il n'y sert qu'à lire
  `/dev/kmsg` pour les OOM tués par le noyau. Le prix est une ligne d'avertissement au démarrage ;
  `container_oom_events_total` (celui du cgroup) fonctionne sans.
- **Ce conteneur monte `/` et la socket Docker.** Qui peut `docker exec` dedans lit tout le disque
  et interroge l'API Docker. Le groupe `docker` étant déjà un équivalent root, ça n'ouvre rien de
  neuf — mais c'est le conteneur le plus exposé de cet hôte avec celui de `node-exporter`.
- **nginx ne relit pas son fichier d'authentification à chaud**, contrairement à
  `exporter-toolkit` qui relit le sien à chaque requête. Après rotation du mot de passe :
  `docker compose -f cadvisor/compose.yaml exec nginx nginx -s reload`.
- **Le mot de passe est celui de `node-exporter/`, pas un second.** Le découpage des credentials
  suit le **cycle de vie**, pas le nombre de fichiers : les deux piles mesurent la machine et
  relèvent du même composant de cluster (`hosts-monitoring`, un seul Secret scellé).
  ⚠️ Tourner celui de `hosts-monitoring` touche donc **deux** fichiers d'hôte —
  `/etc/node-exporter/web-config.yml` et `/etc/cadvisor/htpasswd` — et **un seul prend effet tout
  seul**. Oublier le `nginx -s reload` laisse cette pile seule en 401, ce qui ressemble à une panne
  plutôt qu'à une rotation inachevée.
- **Entre Traefik et cette machine, le mot de passe passe en clair sur le LAN** — le TLS s'arrête
  au proxy.

## Opérations

```bash
# L'authentification mord, et rien d'autre que /metrics ne sort
curl -sI http://<LISTEN_ADDR>:8080/metrics              # 401 attendu
curl -sI http://<LISTEN_ADDR>:8080/api/v1.3/containers  # 404 attendu

# Les métriques arrivent, et elles nomment les conteneurs
curl -s -u prometheus:<mdp> http://<LISTEN_ADDR>:8080/metrics \
  | grep container_memory_working_set_bytes | grep -v '^#' | head

# ⚠️ Contrôle de CARDINALITÉ — le nombre de séries doit rester stable dans le temps.
#    S'il grimpe après chaque `docker compose up`, c'est que `store_container_labels` a été
#    remis à `true` quelque part.
curl -s -u prometheus:<mdp> http://<LISTEN_ADDR>:8080/metrics | grep -vc '^#'

# 502 sur /metrics = cAdvisor ne répond pas. nginx, lui, va bien : il résout `cadvisor` À CHAQUE
# REQUÊTE (cf. le `resolver` de nginx/cadvisor.conf), donc il démarre et sert le 401 même quand
# l'exportateur est absent, et il repart tout seul dès qu'il revient. Regarder cAdvisor, pas nginx.
docker compose -f cadvisor/compose.yaml logs cadvisor

# Les erreurs de nginx — c'est là que se lit un 401 répété, donc une divergence de mot de passe.
docker compose -f cadvisor/compose.yaml logs nginx
```
