# hosts-monitoring

## Rôle

Supervise les **machines hors cluster** — celles que ce cluster surveille sans les porter. Une
seule aujourd'hui :

| Machine | Hostname scruté | `job` | `instance` |
| --- | --- | --- | --- |
| `vert-emeriss` | `node-exporter-emeriss.lan.wittner.tech` | `external-node` | `vert-emeriss` |

Six alertes, groupe `external-node.rules` : disponibilité, disque, mémoire, et l'état du collecteur
`textfile`.

## Pourquoi il est séparé de `forgejo-monitoring`

Le critère est le **cycle de vie**, le même qui sépare les piles `node-exporter/` et `forgejo/`
dans `homelab_emeriss`.

Une machine **précède** le service qu'elle porte et lui **survit**. `vert-emeriss` héberge la forge
aujourd'hui ; le jour où celle-ci déménage, disparaît ou se dédouble, ce qui mesure son disque et sa
mémoire n'a aucune raison de bouger.

⚠️ Mis dans `forgejo-monitoring`, ce scrape serait supprimé par un `prune` ArgoCD le jour où on
retire la forge — c'est-à-dire **précisément quand on surveillerait la machine pour savoir ce
qu'elle devient**.

Le composant est nommé au **pluriel** parce qu'en ajouter une seconde doit être un fichier de plus,
pas une refonte : aucune règle ne nomme de machine, toutes sélectionnent `job="external-node"` et se
ventilent par `instance`.

## Pourquoi il existe

Jusqu'au 2026-09-11, la forge tournait dans ce cluster et le DaemonSet node-exporter de
kube-prometheus-stack mesurait ses nœuds. La bascule vers Docker
([doc/forgejo-docker-bascule-et-sauvegarde.md](../../../doc/forgejo-docker-bascule-et-sauvegarde.md))
a emporté cette source **sans la remplacer** : entre cette date et ce composant, le disque de
`vert-emeriss` n'était surveillé par personne — alors que c'est le mode de panne le plus probable
de ce qu'elle porte, dépôts, base et dumps se partageant un seul stockage.

## Le couplage avec `forgejo-monitoring` — à sens unique

⚠️ **Ce composant transporte, sans que son nom le dise, les métriques de sauvegarde de la forge.**
`forgejo-ctl backup` écrit un fichier `.prom` dans le collecteur `textfile` de node-exporter :
`forgejo_backup_*` arrive donc par **ce** scrape. Les trois alertes qui s'en servent
(`forgejo-backup.rules`) vivent dans `forgejo-monitoring` — elles parlent de la forge, pas de la
machine.

⚠️ **Le dashboard qui montre ces machines ne les AFFICHE pas pour autant.** « Machines — system » ne
montre que la santé du *transport* (tuile « Collecteur textfile ») ; la fraîcheur et le résultat
des sauvegardes s'affichent dans « Forge — forgejo », section Sauvegarde. Le canal appartient à la
machine, son contenu à la forge — c'est la même frontière que pour les alertes.

Conséquences, dans les deux sens :

- une panne **ici** (`ExternalNodeDown`, `ExternalNodeScrapeMissing`,
  `ExternalNodeTextfileCollectorFailing`) rend ces trois alertes-là **aveugles** ;
- une panne **là-bas** n'a aucun effet ici.

C'est écrit des deux côtés parce que rien ne le vérifie.

## Fichiers

- `hosts-monitoring.app.yaml` — Application, ns **`monitoring`**, wave `2`
- `manifests/scrapeconfig-vert-emeriss.yaml` — **un fichier par machine**
- `manifests/prometheusrule.yaml` — six alertes, groupe `external-node.rules`
- `manifests/node-exporters.secret.example.yaml` — template du couple `basicAuth`, **au pluriel** :
  il porte le credential de toutes les machines du composant. ⚠️ Son `SealedSecret` **n'est pas
  encore dans le repo** : ligne commentée dans `kustomization.yaml` — cf. *Opérations*

## Les six règles

| Alerte | Expression | `for` | Sévérité |
| --- | --- | --- | --- |
| `ExternalNodeDown` | `up{job="external-node"} == 0` | 10 min | critical |
| `ExternalNodeScrapeMissing` | `absent(up{job="external-node"})` | 15 min | critical |
| `ExternalNodeDiskAlmostFull` | `< 10 %` libres | 30 min | critical |
| `ExternalNodeDiskWillFill` | `predict_linear(...[6h], 4 j) < 0` **et** `< 30 %` libres | 1 h | warning |
| `ExternalNodeMemoryPressure` | `MemAvailable < 10 %` | 20 min | warning |
| `ExternalNodeTextfileCollectorFailing` | `node_textfile_scrape_error == 1` | 30 min | warning |

## Contraintes

- **Un `ServiceMonitor` ne peut rien faire ici** : il sélectionne des `Service`, et ces machines
  n'en ont aucun. La `ScrapeConfig` est la seule forme qui accepte une cible statique hors cluster.
  ⚠️ Elle exige le label `release: kube-prometheus-stack`, faute de quoi elle est ignorée **sans
  erreur** — premier point à vérifier si la cible n'apparaît pas dans `/targets`.
- **Aucune des ~40 règles `node-exporter.rules` de kube-prometheus-stack ne s'applique.** Elles
  sélectionnent `job="node-exporter"`, et ces cibles portent `job="external-node"`. C'est
  délibéré : reprendre le nom du DaemonSet ferait entrer une machine hors cluster dans les RÈGLES
  et les agrégations des nœuds Talos. Le prix est payé à la main dans `prometheusrule.yaml` — et le
  piège est de croire que ces règles arrivent gratuitement.
  ⚠️ **Cet argument ne vaut plus pour les DASHBOARDS depuis le 2026-09-11** : « Machines — system »
  couvre volontairement les deux jobs, et c'est le job distinct qui permet à
  « Storage — cluster » de filtrer les externes. La séparation sert donc toujours, mais dans
  l'autre sens.
- **`job` et `instance` sont les seuls points de couplage** entre les ScrapeConfigs et les règles.
  Ils sont posés par `relabeling` ; sans lui, une ScrapeConfig nomme son job
  `scrapeConfig/monitoring/<nom>` et `instance` vaut le hostname du **proxy**, pas celui de la
  machine. ⚠️ Le `job` est aussi lu par `forgejo-backup.rules`, **dans l'autre composant** : le
  changer casse des règles dans deux endroits.
- **`instance` doit rester aligné avec celui de `scrapeconfig-db.yaml`** de `forgejo-monitoring` —
  même machine, deux composants. C'est la seule chose qui permette de rapprocher un incident de
  base d'un incident de disque. Rien ne le vérifie ; une divergence ne casse rien, elle rend le
  rapprochement impossible.
- **`node_textfile_scrape_error` mérite sa propre alerte** parce que node-exporter, devant un
  `.prom` illisible, n'abandonne pas ce fichier-là : il abandonne **tout** le collecteur textfile
  (vérifié le 2026-09-11 sur l'image v1.12.1). Sans cette règle, la panne se présenterait comme
  `ForgejoBackupNoMetric` — donc comme « aucune sauvegarde n'a jamais abouti », ce qui est faux et
  envoie diagnostiquer au mauvais endroit.
- **Le Secret est propre à ce composant.** Le `postgres-exporter` de la même machine a le sien
  (`forgejo-db-metrics`, dans `forgejo-monitoring`). Ce n'est pas une isolation cryptographique —
  même hôte, même `docker inspect` — c'est une indépendance de cycle de vie.
- **Le secret n'est pas partagé avec ce qu'il surveille — il en est une COPIE**, et la référence
  n'est même pas récupérable : l'hôte n'en garde qu'un **hachage bcrypt**. Une divergence se
  manifeste en **401**, donc en `up == 0`, donc en `ExternalNodeDown` : un secret mal tourné allume
  une alerte de panne machine. Assumé — un scrape muet n'est pas distinguable d'une machine morte.
  ⚠️ **Ordre de rotation : le cluster D'ABORD, les hôtes ensuite.** `exporter-toolkit` relit son
  fichier à chaque requête ; ce Secret demande un commit et une synchro ArgoCD.
- **Tout le chemin réseau du scrape est hors du cluster** : DNS LAN, route vers `192.168.1.50`,
  déclaration du hostname AU reverse proxy, certificat wildcard `*.lan.wittner.tech`. ⚠️ Un
  hostname non déclaré là-bas répond **404** alors que tout est sain ici (cf.
  [doc/reseau.md](../../../doc/reseau.md)).
- **Le TLS s'arrête au proxy.** Entre Traefik et la machine, le mot de passe de scrape passe en
  clair sur le LAN — conséquence assumée de ne pas gérer un certificat auto-signé, qui imposerait
  un `insecureSkipVerify` que ce dépôt refuse.

## Ce qui vit en face

La cible est produite par le dépôt **`homelab_emeriss`**, et rien ici ne peut le vérifier :

| Ce qui produit la cible | Où |
| --- | --- |
| `node-exporter` | pile **`node-exporter/`** — pile à part, elle survit à la forge |
| son `basic_auth` | `/etc/node-exporter/web-config.yml` (hachage bcrypt) |
| `forgejo_backup_*` | `forgejo/bin/forgejo-ctl`, fonction `publier_metriques` → `/var/lib/node_exporter/textfile` |
| le router | `node-exporter/traefik/node-exporter-emeriss.yml` — copie de référence, le fichier servi vit dans `homelab_proxmox` |

## Opérations

- **Sceller le `basicAuth`** (à faire une fois ; sans lui la cible reste en 401, et les trois
  alertes de sauvegarde de `forgejo-monitoring` sont aveugles) :
  ```bash
  cp cluster/app/hosts-monitoring/manifests/node-exporters.secret.example.yaml \
     cluster/app/hosts-monitoring/manifests/node-exporters.secret.yaml
  openssl rand -base64 24        # à reporter dans `password`
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
    < cluster/app/hosts-monitoring/manifests/node-exporters.secret.yaml \
    > cluster/app/hosts-monitoring/manifests/node-exporters.sealed.yaml
  rm cluster/app/hosts-monitoring/manifests/node-exporters.secret.yaml
  ```
  puis **décommenter** la ligne `node-exporters.sealed.yaml` de `kustomization.yaml` dans le
  **même commit**, et poser le hachage bcrypt du même mot de passe dans
  `/etc/node-exporter/web-config.yml` sur la machine.
- **Vérifier la cible et les règles** :
  ```bash
  kubectl -n monitoring get scrapeconfig,prometheusrule
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
  curl -s 'localhost:19090/api/v1/targets?state=active' | grep -o 'external-node[^,]*' | head
  curl -s 'localhost:19090/api/v1/rules?type=alert' | grep -o 'ExternalNode[A-Za-z]*' | sort -u
  ```
  ⚠️ Pas de `kubectl exec` dans le conteneur `prometheus` : son image n'a **ni shell ni `wget`**.
  Le seul accès à l'API passe par un port-forward.
- **Distinguer une machine morte d'un scrape cassé** :
  ```bash
  # 1. le message d'erreur exact de la cible (401 = secret, timeout = réseau, 404 = proxy)
  curl -s 'localhost:19090/api/v1/targets?state=active' | python3 -m json.tool | grep -A2 lastError
  # 2. l'endpoint depuis le LAN
  curl -sI -u prometheus:<motdepasse> https://node-exporter-emeriss.lan.wittner.tech/metrics | head -1
  # 3. le service que porte la machine — s'il répond, c'est la supervision qui est morte
  curl -sI https://forgejo.wittner.tech/ | head -1
  ```
- **Ajouter une machine** : un `scrapeconfig-<machine>.yaml` (mêmes `job`, `basicAuth` et
  relabelings, seul `instance` et le hostname changent), sa ligne dans `kustomization.yaml`, le
  même hachage bcrypt sur son hôte. **Aucune règle à toucher.**
