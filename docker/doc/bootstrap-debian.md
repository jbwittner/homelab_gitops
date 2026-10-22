# Bootstrap — préparer un Debian neuf à recevoir les piles de ce dépôt

## Rôle

Amener une machine **Debian 13 (trixie) fraîchement installée** à l'état exact que supposent les
`compose.yaml` de ce dépôt : Docker en place, arborescence créée, dépôt cloné.

Ce document s'arrête **avant** la mise en service d'un service donné. Chaque pile a son propre
README, qui prend le relais à partir de `cp .env.example .env` :

| Service | Répertoire | Données sur l'hôte | Port publié | Suite |
|---|---|---|---|---|
| Supervision de l'hôte | `node-exporter/` | `/etc/node-exporter/web-config.yml` | `9100/tcp` sur l'IP LAN | [`node-exporter/README.md`](../node-exporter/README.md) |
| Supervision des conteneurs | `cadvisor/` (**deux** services : `cadvisor` + `nginx`) | `/etc/cadvisor/htpasswd` (hachage bcrypt du mot de passe de scrape) | `8080/tcp` sur l'IP LAN — **celui de nginx**, cAdvisor n'en publie aucun | [`cadvisor/README.md`](../cadvisor/README.md) |
| Gestionnaire des piles | `komodo/` (**trois** services : `mongo` + `core` + `periphery`) | `/srv/komodo/` : `mongo/`, `keys/` (clés privées Core ↔ Periphery), `backups/`, `periphery/` (clones du dépôt) | `9120/tcp` sur l'IP LAN — **celui de Core** ; ni Mongo ni Periphery n'en publient | [`komodo/README.md`](../komodo/README.md) |

⚠️ **Les deux exportateurs ont chacun leur pile, et c'est voulu.** La supervision de l'**hôte** et
celle des **conteneurs** précèdent toute pile applicative et lui survivent. Rangées dans le compose
d'une autre pile, elles seraient arrêtées par son `docker compose down` — pendant l'incident qu'on
veut voir. Côté cluster, elles relèvent toutes deux du composant `hosts-monitoring`.

⚠️ **Les ports 9100 et 8080 court-circuitent Traefik** : qui les joint depuis le LAN obtient les
métriques sans passer par le proxy. Leur seule protection est le `basic_auth` **posé sur la machine
elle-même** — le `web-config.yml` ci-dessus et le `htpasswd` de nginx —, et non un middleware du
reverse-proxy, qui ne couvrirait que le chemin passant par lui. C'est pour cela qu'ils ne sont pas
optionnels.

⚠️ **`cadvisor/` est la seule pile à deux conteneurs, et ce n'est pas un choix d'architecture mais
une contrainte du programme.** cAdvisor ne sait pas authentifier `/metrics` : ses drapeaux
`--http_auth_file` / `--http_digest_file` ne couvrent que l'UI web, et son API JSON `/api/v1.3/...`
est enregistrée avant même que l'authenticator n'existe. Un nginx local porte donc
l'authentification et ne laisse sortir que `/metrics` ; **cAdvisor lui-même ne publie aucun port**,
et c'est cette absence qui ferme le court-circuit. Détail et vérification dans
[`cadvisor/README.md`](../cadvisor/README.md).

⚠️ **Komodo déploie les deux exportateurs, mais pas lui-même.** `node-exporter/` et `cadvisor/` sont
déclarées dans `komodo/sync/piles.toml` et redéployées depuis l'UI Komodo, à partir de **son**
clone du dépôt (`/srv/komodo/periphery/stacks/`). `komodo/` reste sur `bin/redeploy`, qui refuse
les deux autres. Komodo à l'arrêt ne coupe rien : les conteneurs tournent sans lui.

> [!CAUTION]
> **Komodo est un équivalent root accessible par le navigateur.** Periphery monte la socket Docker
> et ses terminaux sont activés : un compte Komodo vaut un shell root sur cette machine. Son UI ne
> sort donc **jamais** du LAN (`komodo.lan.wittner.tech`, aucune entrée cloudflared).

`~/.ssh/id_deploiement_homelab` (§5.1), la clé avec laquelle l'hôte lit le dépôt, n'apparaît pas dans
ce tableau : elle appartient au compte qui tire, pas à une pile.

> [!IMPORTANT]
> **Ce tableau est le contrat.** Ajouter un service ou un outil au dépôt sans mettre à jour ce
> fichier produit une machine incomplète que rien ne signale : le compose démarre, et c'est le
> réglage d'hôte manquant (répertoire, paquet) qui se découvre en production.

> [!CAUTION]
> **Le groupe `docker` est un équivalent root.** Qui en est membre monte `/` dans un conteneur
> privilégié. Ce n'est pas une théorie ici : les `.env` de ce dépôt portent des secrets
> cryptographiques, et `docker inspect` les rend lisibles à tout membre du groupe. N'y mettre que
> les comptes qui administrent déjà la machine.

## Prérequis

- Debian 13 (trixie), installation **minimale** : ni environnement de bureau, ni `task-web-server`.
  Debian 12 (bookworm) fonctionne — les seuls écarts sont signalés en place.
- Une **IP LAN fixe** sur cet hôte, connue à l'avance : elle est écrite des deux côtés
  (`LISTEN_ADDR` des `.env` d'ici, et l'URL des services dans
  `homelab_ysera/traefik/dynamic/` — un autre dépôt). Ici notée `192.168.1.15`.
- L'accès SSH à l'hôte Traefik (`192.168.1.50`), qui n'est **pas** cette machine.
- Le dimensionnement de la §« Matériel minimum » du README du service visé, s'il en a une.
- **Un CPU x86_64 avec AVX** — exigé par MongoDB ≥ 5.0, donc par `komodo/`. Sans lui, `mongo`
  meurt au démarrage sur le code 132 (« Illegal instruction »), sans autre message. Tout CPU
  depuis 2011 l'a ; une VM peut le masquer si le type de CPU émulé est générique (`kvm64` sous
  Proxmox). Contrôle au §6.

À l'installateur Debian, deux choix qui coûtent cher à défaire :

- **Partitionnement** : `/srv` doit être sur le stockage rapide. Un `/` unique sur SSD convient.
  ⚠️ **Ne pas laisser l'installateur allouer tout le disque.** Son découpage guidé donne un `/srv`
  taillé sur rien de connu — 18 Go sur un disque de 238 Go, constaté le 11 septembre 2026 — et ne
  laisse aucun extent libre dans le VG. En LVM tout se rattrape ensuite (`lvextend -r`, en ligne),
  à deux conditions : garder des extents libres, et **ne jamais avoir à réduire** un volume déjà
  rempli. Un `lvreduce` demande de démonter, et en xfs il n'existe pas. Des extents libres sont
  aussi ce qui permet un **snapshot LVM** avant une migration de données sans retour arrière.
- **Sélection de logiciels** : ne cocher que `SSH server` et `standard system utilities`.

## 1. Compte, sudo, SSH

Le compte d'exploitation de cet hôte est **`jbwittner`** : c'est lui qui est cité partout dans ce
document, et c'est le compte créé par l'installateur.

```bash
# En root, si l'installateur n'a pas mis le compte dans sudo :
# ⚠️ `su` SANS TIRET garde le PATH de l'utilisateur, d'où `/usr/sbin` est absent : `usermod` et
# `sshd` répondent alors « command not found » alors qu'ils sont installés. Le tiret ouvre
# un shell de LOGIN, donc le PATH de root. Toute la suite du document le suppose.
su -
apt update && apt install -y sudo
usermod -aG sudo jbwittner
# Vérifier :
getent group sudo
# Puis se déconnecter/reconnecter — l'appartenance à un groupe n'est lue qu'à l'ouverture de session.
```

Clé publique et fermeture du mot de passe, **dans cet ordre** :

```bash
# Depuis le poste client, AVANT de fermer quoi que ce soit :
ssh-copy-id jbwittner@192.168.1.15
# Vérifier que la connexion par clé marche dans un SECOND terminal, sans fermer le premier.
```

```bash
# Sur l'hôte — drop-in, pas d'édition de /etc/ssh/sshd_config : un paquet mis à jour peut
# proposer de remplacer le fichier principal, jamais les drop-ins.
sudo tee /etc/ssh/sshd_config.d/10-durcissement.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t && sudo systemctl restart ssh
```

> [!WARNING]
> Sur Debian 12+, `ssh` est **activé par socket** (`ssh.socket`). Un `Port` changé dans
> `sshd_config` n'a alors aucun effet : c'est `systemctl edit ssh.socket` qui décide de l'écoute.
> Les directives ci-dessus, elles, sont bien lues par `sshd`.

## 2. Horloge, locales, mises à jour non surveillées

```bash
sudo timedatectl set-timezone Europe/Paris     # doit correspondre à TZ des .env
timedatectl show -p NTPSynchronized            # systemd-timesyncd est actif par défaut

sudo apt install -y locales-all ca-certificates curl gnupg git

sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # répondre « Oui »
```

> [!IMPORTANT]
> `unattended-upgrades` met à jour **l'hôte**, jamais les images des conteneurs. Les versions des
> images sont épinglées en dur dans les `compose.yaml` et suivies par Renovate ; un tag mis à jour
> ne prend effet qu'au `docker compose pull && docker compose up -d` suivant. Rien ne le fait tout
> seul, et c'est voulu — cf. [`bin/redeploy`](../bin/redeploy).

## 3. Swap et dimensionnement réel

Le swap est un filet, pas un confort : **sans lui, le premier pic mémoire d'un conteneur se règle
par l'OOM killer**, qui choisit sa victime sans consulter personne.

Constater ce que la machine a réellement, avant de décider :

```bash
# ⚠️ Chemin ABSOLU : `/usr/sbin` n'est pas dans le PATH d'un utilisateur non-root sur Debian, et
# `swapon` y vit. Sans le chemin, « command not found » — pas « pas de swap ». Les commandes en
# `sudo` de ce document n'ont pas ce problème : `sudo` impose son propre `secure_path`, qui inclut
# `/usr/sbin`.
/usr/sbin/swapon --show   # si vide, l'installateur n'a pas créé de partition de swap
free -h                   # RAM — à confronter à la « Matériel minimum » des piles visées
nproc                     # vCPU
# ⚠️ Les TROIS points de montage, pas seulement `/srv` : selon le découpage, `/var` peut être un
# volume à part — c'est là que vit `/var/lib/docker`. Une place lue sur `/` alors que `/var` est
# séparé ne dit rien de ce qui va réellement se remplir.
df -h / /var /srv
lsblk                     # découpage réel — quel volume porte quoi
sudo vgs                  # VFree : ce qui reste pour agrandir plus tard
```

L'installateur Debian dimensionne le swap **à peu près comme la RAM** : un swap de ~1,7 Go trahit
donc une machine à ~2 Go de RAM.

Si le swap est **déjà présent et ≥ 1 Go**, il n'y a rien à créer : passer directement au
`swappiness` en fin de section.

Si absent — fichier de swap de 2 Go :

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

⚠️ `fallocate` échoue silencieusement en swap utilisable sur **Btrfs** : y utiliser
`btrfs filesystem mkswapfile`. Sur ext4/xfs, rien à signaler.

**Dans les deux cas** — swap hérité de l'installateur ou fichier créé ci-dessus :

```bash
# Swapper tard : le swap est un filet pour les pics, pas un étage de stockage.
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system
```

## 4. Docker CE

⚠️ **Pas `apt install docker.io`.** Le paquet Debian est en retard de plusieurs majeures et ne
fournit pas le plugin `compose` v2 ; toutes les commandes de ce dépôt sont en `docker compose`
(sous-commande), jamais `docker-compose` (binaire séparé).

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker jbwittner   # ⚠️ équivalent root, cf. l'avertissement en tête
# Se déconnecter/reconnecter, puis :
docker compose version                  # doit RÉPONDRE — la version importe peu (v5.x en 2026),
                                        # ce qui compte est que la SOUS-COMMANDE existe : le
                                        # binaire séparé `docker-compose` n'est plus le sujet.
```

**Rotation des journaux** — sans elle, les journaux d'un conteneur `restart: unless-stopped`
grossissent sans plafond jusqu'à remplir `/var/lib/docker` :

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
```

⚠️ Ce réglage ne s'applique qu'aux conteneurs **créés après** le redémarrage du démon. Un
conteneur existant garde sa configuration de journalisation jusqu'à sa recréation.

> [!CAUTION]
> **Arrêter `nftables` coupe la sortie réseau de TOUS les conteneurs, en silence.** L'unité Debian
> porte `ExecStop=/usr/sbin/nft flush ruleset` : `systemctl stop nftables` — et donc
> `disable --now` — vide **tout** le ruleset, y compris les tables que Docker y a posées. Docker ne
> les recrée qu'au démarrage du démon, qui ne bouge pas.
>
> Constaté le 10 septembre 2026 sur cet hôte. Symptômes, tous **muets** :
>
> - `ip_forward` à 1, pont `br-*` `UP`, IP attribuées : tout paraît normal ;
> - la résolution DNS fonctionne dans les conteneurs — le serveur embarqué de Docker relaie via
>   l'hôte et n'a besoin d'aucune règle, ce qui égare le diagnostic ;
> - toute connexion TCP sortante **expire** au lieu d'échouer, faute de traduction d'adresse : les
>   paquets partent en `172.x.x.x`, la passerelle n'a pas de route retour.
>
> ```bash
> sudo systemctl restart docker      # le démon repose ses règles au démarrage
> ```
>
> ⚠️ Ce redémarrage relance les conteneurs : quelques secondes d'indisponibilité.
>
> **Le contrôle qui le voit**, depuis n'importe quel conteneur — et non depuis l'hôte, qui répond
> normalement puisque ses propres règles ne sont pas en cause :
>
> ```bash
> docker run --rm busybox:1.37 sh -c 'timeout 8 nc -z 1.1.1.1 443 && echo OK || echo TIMEOUT'
> ```

### 4.0 `apache2-utils` — le `htpasswd` des exportateurs

```bash
sudo apt install -y apache2-utils
```

Deux formes en sortent, et elles ne servent qu'**une fois par rotation** du mot de passe de scrape.
⚠️ **C'est le même mot de passe dans les deux cas** — seul le format attendu par le lecteur change.

```bash
# ⚠️ Le mot de passe se SAISIT, il ne se passe JAMAIS en argument (`-b`) : un secret sur la ligne
# de commande est lisible par tout compte de la machine dans `ps` le temps de l'exécution, et il
# reste ensuite dans `~/.bash_history`. Les deux formes ci-dessous le demandent à la frappe.
# `-n` écrit sur la sortie standard au lieu d'un fichier, `-B` force bcrypt, `-C 12` le coût.

# (a) Pour le YAML d'`exporter-toolkit` — pile `node-exporter/`.
#     Il veut le hachage SEUL : le `tr` retire le `:` de séparation et le saut de ligne.
htpasswd -nBC 12 "" | tr -d ':\n' ; echo

# (b) Pour le `htpasswd` de nginx — pile `cadvisor/`.
#     Il veut la ligne COMPLÈTE `prometheus:$2y$12$...`, identifiant compris.
htpasswd -nBC 12 prometheus
```

⚠️ **Ne pas intervertir les deux formes.** Un hachage nu déposé dans le fichier de nginx donne une
ligne sans identifiant, que nginx ignore **en silence** : l'authentification refuse alors tout le
monde, et le symptôme est un 401 permanent qu'on prend pour une divergence de mot de passe.

⚠️ **Sans ce paquet, rien n'échoue au `docker compose up`** : les exportateurs démarrent avec le
`REMPLACER` des fichiers d'exemple, aucun mot de passe ne correspond, et le symptôme est un **401
côté cluster** — donc une alerte de disponibilité de la machine, pas une alerte de configuration.

## 5. Arborescence et dépôt

### 5.1 Accès au dépôt — clé de déploiement GitHub

Le dépôt est **privé** sur GitHub (`git@github.com:jbwittner/homelab_gitops.git`) : l'hôte le lit
par SSH, avec une clé qui n'ouvre que lui.

⚠️ **Ce dépôt est partagé avec le cluster** : `docker/` pour cet hôte, `k8s/` pour ArgoCD. La clé
ouvre donc aussi `k8s/` en lecture. C'est acceptable parce que les secrets y sont **scellés**
(illisibles sans la clé du contrôleur sealed-secrets, qui ne vit pas dans Git) — et c'est la raison
pour laquelle rien, sous `k8s/`, ne doit jamais être versionné en clair.

> [!CAUTION]
> **Ne pas recopier une clé personnelle sur cet hôte.** Une clé personnelle donne accès à *tous*
> les dépôts du compte, et à tout ce qui accepte cette clé ailleurs. Une **clé de déploiement**
> GitHub est attachée à **un seul dépôt** et se révoque seule, sans toucher au reste. Sur une
> machine où le groupe `docker` est déjà un équivalent root, c'est la différence entre « un hôte
> compromis » et « un hôte compromis qui emporte le compte GitHub ».

```bash
# Clé DÉDIÉE à cet hôte. Sans passphrase : le `git pull` doit pouvoir se jouer sans rien connaître,
# et la clé est de toute façon en lecture seule sur un seul dépôt.
ssh-keygen -t ed25519 -a 100 -N "" \
  -f ~/.ssh/id_deploiement_homelab \
  -C "deploiement homelab_gitops @ $(hostname)"
chmod 600 ~/.ssh/id_deploiement_homelab
cat ~/.ssh/id_deploiement_homelab.pub
```

Déposer cette **clé publique** sur GitHub : dépôt → *Settings* → *Deploy keys* → *Add deploy key*.
⚠️ **Ne pas cocher « Allow write access ».** L'hôte lit, il ne pousse jamais : une configuration
modifiée en production et jamais remontée est exactement ce que ce dépôt existe pour empêcher. Et
la garantie tient côté serveur — un `git push` d'ici est refusé par GitHub, pas par une
configuration locale qu'un `git remote set-url` suffirait à défaire.

⚠️ **GitHub refuse qu'une même clé soit clé de déploiement de deux dépôts** (« Key is already in
use »). Changer le dépôt que lit l'hôte, c'est donc **déplacer** la clé : la retirer de l'ancien
dépôt, puis l'ajouter au nouveau. L'alias SSH ci-dessous ne change pas.

```bash
# Alias SSH — évite de dépendre de la clé par défaut du compte.
cat >> ~/.ssh/config <<'EOF'

Host github-homelab
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_deploiement_homelab
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
```

⚠️ **`IdentitiesOnly yes` n'est pas décoratif.** Sans lui, SSH propose toutes les clés qu'il
connaît ; GitHub retient la **première** acceptée, et si ce n'est pas la clé de déploiement du bon
dépôt, la réponse est `ERROR: Repository not found` — un message qui accuse le dépôt alors que le
problème est la clé.

Épingler l'empreinte de GitHub plutôt que l'accepter à l'aveugle :

```bash
# ⚠️ `ssh-keyscan >> known_hosts` seul est une confiance aveugle : il enregistre ce que répond le
# réseau, y compris un intercepteur. Comparer AVANT à l'empreinte publiée par GitHub.
ssh-keyscan -t ed25519 github.com 2>/dev/null | ssh-keygen -lf -
#   attendu : SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
ssh-keyscan -t ed25519 github.com 2>/dev/null >> ~/.ssh/known_hosts

# Vérification de bout en bout — doit nommer le DÉPÔT, pas le compte :
ssh -T github-homelab
#   « Hi jbwittner/homelab_gitops! You've successfully authenticated,
#     but GitHub does not provide shell access. »
```

### 5.2 Répertoires et clone

```bash
# Supervision. Deux répertoires, tous deux en 0700 root :
#
# ⚠️ `/etc/node-exporter` — il portera le hachage bcrypt du mot de passe de scrape. Le FICHIER
#    qu'il contient sera en 0644 (le conteneur tourne en `nobody` et doit le lire) ; c'est le 0700
#    du répertoire qui empêche un compte quelconque de l'hôte d'y accéder.
sudo install -d -m 700 -o root -g root /etc/node-exporter
# ⚠️ `/etc/cadvisor` — même disposition et même raison : il porte le hachage bcrypt, le FICHIER
#    est en 0644 pour que les workers nginx (non privilégiés) le lisent, et c'est le 0700 du parent
#    qui ferme l'accès aux comptes de la machine.
sudo install -d -m 700 -o root -g root /etc/cadvisor

# Komodo. ⚠️ TOUT `/srv/komodo` en 0700 root, pas seulement `keys/` : `keys/` porte les clés
#    PRIVÉES du lien Core ↔ Periphery, `backups/` des dumps NON CHIFFRÉS de la base — jeton GitHub
#    compris —, `mongo/` la base elle-même. Les trois conteneurs tournent en root (mongo fait son
#    propre `chown` uid 999 sur `mongo/db` et `mongo/configdb` au démarrage) : rien ne demande
#    qu'un compte de l'hôte puisse y lire.
# ⚠️ Ils doivent exister AVANT le premier `up` : un bind sur un chemin absent est créé par Docker,
#    en root:root 0755 — lisible par tous. Et `periphery/` doit être au MÊME chemin dedans et dehors
#    (cf. `komodo/compose.yaml`).
sudo install -d -m 700 -o root -g root /srv/komodo
sudo install -d -m 700 -o root -g root \
  /srv/komodo/mongo /srv/komodo/mongo/db /srv/komodo/mongo/configdb \
  /srv/komodo/keys /srv/komodo/backups /srv/komodo/periphery

# Le dépôt lui-même — il ne contient que de la configuration, jamais de données. Il faut le cloner
# AVANT de poser les fichiers d'authentification : leurs exemples en viennent.
sudo mkdir -p /opt/homelab && sudo chown jbwittner:jbwittner /opt/homelab
git clone github-homelab:jbwittner/homelab_gitops.git /opt/homelab/homelab_gitops
cd /opt/homelab/homelab_gitops/docker   # ⚠️ docker/, pas la racine : k8s/ n'a rien à faire ici
git remote -v                          # origin -> github-homelab:jbwittner/homelab_gitops.git
git check-ignore -v cadvisor/.env      # DOIT répondre : sinon le .env part au premier commit
git check-ignore -v komodo/.env        # idem — et celui-ci porte des SECRETS

# Les DEUX fichiers d'authentification des exportateurs. ⚠️ Ils doivent EXISTER avant le premier
# `docker compose up` des piles concernées : les `volumes:` les montent comme FICHIERS, et un bind
# sur un chemin absent fait créer un RÉPERTOIRE vide par Docker — l'exportateur échoue alors sur
# une erreur de parseur (ou de lecture du fichier d'auth, pour nginx), pas sur « fichier manquant ».
# Le hachage se produit ensuite, cf. le §4.0 et les deux fichiers d'exemple.
#
# ⚠️ UN SEUL MOT DE PASSE pour les deux : le découpage suit le CYCLE DE VIE, pas le nombre de
#    fichiers. Les deux piles mesurent la machine, et le cluster les range dans le même composant
#    (`hosts-monitoring`, un seul Secret scellé). Il n'existe aucun scénario où node-exporter part
#    sans cadvisor.
# ⚠️ MAIS PAS LE MÊME FORMAT — le YAML `exporter-toolkit` veut le hachage SEUL, le `htpasswd` de
#    nginx veut la ligne COMPLÈTE `prometheus:$2y$...`. Cf. §4.0, formes (a) et (b).
sudo install -D -m 644 -o root -g root \
  /opt/homelab/homelab_gitops/docker/node-exporter/monitoring/web-config.example.yml \
  /etc/node-exporter/web-config.yml
sudo install -D -m 644 -o root -g root \
  /opt/homelab/homelab_gitops/docker/cadvisor/monitoring/htpasswd.example \
  /etc/cadvisor/htpasswd

# ⚠️ AUCUN fichier d'hôte pour la conf nginx de `cadvisor/`, et c'est délibéré : elle est montée
# DEPUIS LE DÉPÔT (`cadvisor/nginx/cadvisor.conf`). Elle ne porte aucun secret, donc il n'y a pas
# de copie de référence à faire diverger de l'original — contrairement aux fichiers ci-dessus.

# Raccourci depuis le home — `cd ~/homelab` mène à `docker/`, là où se lancent `bin/redeploy` et
# les `docker compose -f ~/homelab/<pile>/compose.yaml` de la documentation.
ln -sfn /opt/homelab/homelab_gitops/docker ~/homelab
```

⚠️ **Rien ne met ce clone à jour tout seul.** Aucun timer ni unité systemd ne joue de `git pull`
sur cet hôte — les seuls `pull` du reflog sont manuels. Constaté le 11 septembre 2026 : la machine
était sur `394c136` quand le dépôt était trois commits plus loin, sur `af021ec`. Un clone en
retard ne produit **aucune** erreur : il produit un `docker compose up -d` qui redéploie sagement
l'ancienne configuration. Le contrôle du §6 est donc à rejouer après chaque changement poussé, pas
seulement au bootstrap. ⚠️ Cela ne vaut plus que pour `komodo/` : les piles pilotées par Komodo
sont lues depuis **son** clone, qu'il tire lui-même à chaque déploiement.

⚠️ Le lien est un **lien symbolique, pas un alias shell** : il marche pour `cd`, mais aussi pour
`scp`, `rsync`, `docker compose -f ~/homelab/cadvisor/compose.yaml`, et depuis n'importe quel outil.
`-n` évite de créer `~/homelab/docker` si le lien existe déjà, `-f` le remplace en cas de
recible.

⚠️ Les répertoires de données `/srv/<service>/…` et leurs propriétaires sont fixés **par le README
du service** qui en a besoin, et ajoutés ici au même changement. Seule `komodo/` en a (ci-dessus).

## 6. Vérification avant de déployer quoi que ce soit

```bash
# 1. Docker et compose v2
docker compose version
docker run --rm hello-world

# 2. Rotation des journaux effective
docker info --format '{{.LoggingDriver}}'
sudo cat /etc/docker/daemon.json

# 3. Swap présent — chemin absolu, `/usr/sbin` n'est pas dans le PATH d'un non-root
/usr/sbin/swapon --show
df -h / /var /srv

# 4. Horloge synchronisée et fuseau correct
timedatectl

# 5. L'accès au dépôt — ne doit RIEN demander.
cd /opt/homelab/homelab_gitops/docker   # ⚠️ docker/, pas la racine : k8s/ n'a rien à faire ici
ssh -T github-homelab                   # doit nommer le DÉPÔT, pas le compte
git ls-remote origin refs/heads/main
git pull --ff-only

# 6. Supervision — les DEUX exportateurs répondent, et leur authentification MORD.
#    ⚠️ Le 401 est le contrôle qui compte. Un exportateur démarré sans `--web.config.file`, ou
#    avec un fichier resté à `REMPLACER`, répond 200 à qui demande : l'inventaire des systèmes de
#    fichiers, des interfaces et de la charge pour le premier, les noms et la consommation des
#    conteneurs pour le second. Un 200 ici est une fuite, pas un succès.
curl -sI  http://<IP_LAN>:9100/metrics | head -1      # DOIT dire 401
curl -sI  http://<IP_LAN>:8080/metrics | head -1      # DOIT dire 401  (nginx de la pile cadvisor)
# ⚠️ UN mot de passe : celui du 9100 ouvre AUSSI le 8080 (même composant `hosts-monitoring`).
curl -sI http://<IP_LAN>:8080/api/v1.3/containers | head -1   # DOIT dire 404
#    ⚠️ CONTRÔLE PROPRE À LA PILE cadvisor, et il ne teste PAS la même chose que le 401 ci-dessus.
#    cAdvisor sert sur son port une UI web et une API JSON qu'il ne sait PAS authentifier (ses
#    drapeaux `--http_auth_*` ne couvrent que l'UI, et l'API est enregistrée avant l'authenticator).
#    C'est le nginx de la pile qui les ferme, et lui seul. Un 401 ici au lieu d'un 404 signifierait
#    que la conf nginx a été relâchée en `location /metrics` (préfixe) au lieu de `location =
#    /metrics` (exact) ; un 200 signifierait que cAdvisor publie un port en direct.

# 7. Komodo — les prérequis, pas le service.
grep -m1 -wo avx /proc/cpuinfo           # DOIT répondre « avx » : sinon MongoDB ne démarre pas
sudo stat -c '%a %U %n' /srv/komodo /srv/komodo/keys /srv/komodo/backups   # 700 root, partout
stat -c '%a' ~/homelab/komodo/.env       # 600 — il porte les secrets de la base
```

## 7. Ce que ce document ne couvre pas

- **La mise en service des services** — `.env`, ordre de démarrage : README de chaque pile.
- **L'hôte Traefik (`192.168.1.50`)** — les configurations dynamiques et l'ingress `cloudflared`.
  C'est une autre machine, et depuis le 11 septembre 2026 **ce dépôt n'en garde plus aucune copie**.
  Les fichiers vivent dans `homelab_ysera/traefik/dynamic/` : `node-exporter-emeriss.yml`,
  `cadvisor-emeriss.yml`, `komodo.yaml`. Le CT 201 monte ce répertoire sur `/etc/traefik-git`,
  donc ce qui est commité là-bas est ce qui est servi.
  ⚠️ **Pourquoi les copies ont été retirées** : l'une d'elles avait divergé dans les deux sens
  — un routeur servi qu'elle ignorait, un autre qu'elle déclarait sans qu'il soit servi. Rien ne
  synchronisait les deux exemplaires, et l'écart ne se voyait qu'en interrogeant Traefik. Ne pas
  les recréer.
  ⚠️ **Ce qui reste couplé à cet hôte-ci** : l'IP LAN. Elle est écrite dans `komodo/.env`, dans la
  variable `EMERISS_LAN_IP` de `komodo/sync/piles.toml` (qui alimente les deux exportateurs), et
  dans l'URL des services là-bas — elle se change **des deux côtés**, dans deux dépôts.
  ⚠️ **Rien à déclarer au résolveur, en revanche** : AdGuard réécrit `*.wittner.tech` vers
  `192.168.1.50` par une règle générique. Les deux noms de métrologie — `node-exporter-emeriss`,
  `cadvisor-emeriss` — résolvent donc **avant même d'exister**, et n'importe quel nom inventé aussi.
  ⚠️ Corollaire qui coûte du temps quand on l'ignore : **« ça résout » ne prouve rien**. Un nom qui
  résout sans routeur reçoit le 404 par défaut de Traefik, indiscernable d'une erreur de
  configuration — le seul fichier qui fasse exister un nom est celui de
  `homelab_ysera/traefik/dynamic/`, et cela se vérifie dans l'API de Traefik, pas depuis cet hôte.
  ⚠️ Second corollaire, côté sécurité : un `dig` depuis le LAN ne prouve **jamais** qu'un nom est
  privé. Seul `dig +short <nom> @1.1.1.1`, réponse vide, le dit.
- **Les sauvegardes hors de l'hôte.** Seule `komodo/` porte un état, et elle se sauvegarde
  elle-même : dump quotidien dans `/srv/komodo/backups/`, **sur le même disque** — cf.
  [`komodo/README.md`](../komodo/README.md#sauvegarde). Rien ne copie ces dumps ailleurs
  aujourd'hui, et rien dans ce bootstrap n'installe d'outil pour le faire. La perte est bornée :
  la déclaration des piles vit dans ce dépôt, seuls les comptes et le jeton GitHub de Komodo
  seraient à refaire.
- **Renovate.** Le régime est déclaré dans `renovate.json` à la racine du dépôt (cooldown de
  7 jours, automerge des correctifs et mineures, sauf `docker/komodo/`). Rien dans ce bootstrap
  n'installe le robot : c'est le Renovate **du cluster** (`k8s/app/renovate/`), authentifié en
  GitHub App, qui le lit — et seulement si `homelab_gitops` est coché dans l'installation de l'App.
  ⚠️ Un cluster arrêté, c'est donc aussi un hôte Docker qui ne reçoit plus de mises à jour.
  Une PR mergée sur `node-exporter`/`cadvisor` part seule (procédure `deploiement-auto`, 15 min) ;
  sur `komodo/`, elle attend [`bin/redeploy komodo`](../bin/redeploy) (`git pull` d'abord — le
  script ne tire pas le dépôt, seulement les images). Sans ce geste, le dépôt déclare une version
  que l'hôte ne fait pas tourner, et l'écart ne se voit qu'au prochain redémarrage.
