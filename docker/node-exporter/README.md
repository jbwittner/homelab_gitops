# node-exporter — supervision de l'hôte

## Rôle

Expose les métriques **de la machine** (disque, mémoire, charge, réseau, uptime) sur
`https://node-exporter-emeriss.lan.wittner.tech/metrics`, où elles sont scrutées **depuis le
cluster** — composant **`hosts-monitoring`** de `homelab_gitops`. Rien ne les lit ici : cette pile
n'a ni Prometheus ni Grafana.

## Pourquoi une pile à part

Le critère est le **cycle de vie**, pas la machine. Ce qui est mesuré ici appartient à la
**machine** : ça précède toute pile applicative et ça lui survit.

⚠️ Rangé dans le compose d'une autre pile, cet exportateur serait arrêté par son
`docker compose down` — c'est-à-dire **précisément pendant l'incident qu'on veut voir**.

## Pourquoi il existe

Cet hôte n'est pas un nœud du cluster : le DaemonSet node-exporter de kube-prometheus-stack ne le
mesure pas. Sans cette pile, le disque de cette machine n'est surveillé par personne.

## Fichiers

- `compose.yaml` — le service, tag d'image **en dur** (Renovate)
- `.env.example` — `LISTEN_ADDR`, `LISTEN_PORT`. Aucun secret
- `monitoring/web-config.example.yml` — copie de référence de `/etc/node-exporter/web-config.yml`,
  le `basic_auth` de l'exportateur. ⚠️ **Fichier d'hôte, à poser AVANT le premier `up`**
- ⚠️ **Pas de `traefik/` dans cette pile, et c'est délibéré.** La règle du reverse-proxy vit dans
  **`homelab_ysera/traefik/dynamic/node-exporter-emeriss.yml`**, le seul exemplaire qui existe — celui que Traefik
  charge, par le montage `mp0` du CT 201. Ce dépôt en gardait une « copie de référence » : elle a été
  retirée le 11 septembre 2026, en même temps que celle d'une autre pile — qui, elle, avait divergé
  dans les deux sens. Celle-ci était encore à l'identique : c'était un sursis, pas une garantie.
  **Ne pas en recréer une.**
  ⚠️ **Couplage à tenir** : l'URL du service là-bas et `LISTEN_ADDR`/`LISTEN_PORT` du `.env` d'ici
  sont **la même valeur vue de deux dépôts**.

⚠️ **Le nom porte celui de la MACHINE** — `node-exporter-emeriss`, pas `node-exporter`. Cette pile
est duplicable telle quelle sur un autre hôte : un nom générique ferait collision au premier
second exportateur — dans les noms de routeurs de Traefik, qui sont **globaux**, et dans la règle
`Host(...)` : le second écraserait le premier en silence. Le résolveur, lui, n'est pas concerné, il
répond pour tout `*.wittner.tech` sans rien savoir des noms. Le fichier Traefik, le router et le
hostname portent donc tous les trois le suffixe.

## Mise en service

```bash
# 1. Le fichier d'authentification, D'ABORD — un bind sur un chemin absent fait créer un
#    RÉPERTOIRE par Docker, et l'exportateur échoue alors sur une erreur de parseur.
sudo install -D -m 0644 -o root -g root \
  node-exporter/monitoring/web-config.example.yml /etc/node-exporter/web-config.yml
htpasswd -nBC 12 "" | tr -d ':\n' ; echo          # paquet `apache2-utils`, mot de passe à la frappe
sudo sed -i 's#REMPLACER#<hachage>#' /etc/node-exporter/web-config.yml

# 2. La pile — ⚠️ c'est KOMODO qui la déploie, pas `docker compose` ni `bin/redeploy` (qui la
#    refuse). Déclarée dans `komodo/sync/piles.toml`, avec son `.env` (champ `environment`) :
#    déployée par la procédure `deploiement-auto` (≤ 15 min). Cf. komodo/README.md. Le `.env.example` reste la
#    documentation des variables ; un `.env` dans ce répertoire n'est plus lu.

# 3. Vérifier — l'authentification DOIT mordre
curl -sI  http://<LISTEN_ADDR>:9100/metrics                      # attendu : 401
curl -s -u prometheus:<mdp-node> http://<LISTEN_ADDR>:9100/metrics | head -3   # attendu : des métriques
```

Puis, **dans `homelab_ysera`**, vérifier que `traefik/dynamic/node-exporter-emeriss.yml` porte l'IP LAN
réelle de cet hôte. **Rien à faire côté DNS** : AdGuard réécrit `*.wittner.tech` vers
`192.168.1.50` par une règle générique, donc `node-exporter-emeriss.lan.wittner.tech` résout
déjà — y compris avant que le routeur existe.

⚠️ **« Ça résout » ne prouve donc rien.** Un nom sans routeur reçoit le 404 par défaut de Traefik,
et le symptôme, vu du cluster, est une cible Prometheus en erreur — indiscernable d'une panne de
réseau. Le seul fait qui fasse exister ce nom est le fichier ci-dessus.

## Contraintes

- **`network_mode: host` est load-bearing.** Sur un réseau bridge, les compteurs réseau seraient
  ceux du conteneur : des chiffres plausibles, entièrement faux, que rien ne signale.
- **`--path.rootfs=/rootfs` est load-bearing.** Sans lui, avec le montage de `/`, l'exportateur
  mesure la couche overlay du conteneur et non `/srv` ni `/var` : les métriques existent, les
  alertes de disque ne se déclenchent jamais.
- **`/` est monté en entier, en lecture seule.** Le collecteur `filesystem` n'appelle que
  `statfs(2)`, mais qui peut `docker exec` dans ce conteneur lit tout le disque — y compris les
  `.env` des autres piles. Le groupe `docker` étant déjà un équivalent root, ça n'ouvre rien de neuf.
- **`web-config.yml` n'est pas optionnel** et **doit exister avant le premier `up`**.
- **Le mot de passe de scrape est recopié à DEUX endroits** : `/etc/node-exporter/web-config.yml`
  ici, et le SealedSecret `node-exporters` du composant `hosts-monitoring`. Rien ne les
  synchronise ; une divergence se lit en 401, donc en `up == 0`, donc en `ExternalNodeDown`.
  ⚠️ **C'est aussi celui de `/etc/cadvisor/htpasswd`** (même composant de cluster, autre format) :
  une rotation touche les deux fichiers, cf. [`cadvisor/README.md`](../cadvisor/README.md).
- **Entre Traefik et cette machine, le mot de passe passe en clair sur le LAN** — le TLS s'arrête
  au proxy.

## Opérations

```bash
# L'exportateur répond, et l'authentification mord
curl -sI http://<LISTEN_ADDR>:9100/metrics                       # 401 attendu

# Les systèmes de fichiers réellement vus — doit nommer / et /srv (et /var s'il est séparé),
# et PAS des couches overlay
curl -s -u prometheus:<mdp-node> http://<LISTEN_ADDR>:9100/metrics \
  | grep node_filesystem_size_bytes
```
