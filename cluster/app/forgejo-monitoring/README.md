# forgejo-monitoring

## Rôle

Tout ce que ce cluster garde de la forge, qui n'y tourne plus (archivée le 2026-09-11 —
[archive/forgejo](../../../archive/forgejo/README.md), Forgejo est en Docker sur une machine
dédiée). **Deux** cibles hors cluster, scrutées à travers le reverse proxy `192.168.1.50` :

| Cible | Hostname | `job` | Ce qu'elle porte |
| --- | --- | --- | --- |
| la forge | `forgejo-metrics.lan.wittner.tech` | `forgejo` | jauges applicatives `gitea_*` |
| la base | `forgejo-db-metrics.lan.wittner.tech` | `forgejo-db` | `pg_up`, volumétrie, deadlocks |

Neuf alertes, en trois groupes. Le dashboard « Forge — forgejo » vit, lui, avec les autres dans
[kube-prometheus-stack](../kube-prometheus-stack/README.md).

> [!IMPORTANT]
> **La MACHINE qui porte la forge n'est pas surveillée ici** — elle l'est par
> [hosts-monitoring](../hosts-monitoring/README.md). Une machine précède le service qu'elle héberge
> et lui survit ; la mettre ici ferait disparaître sa supervision au `prune` du jour où on retire la
> forge. Même critère que la séparation des piles `node-exporter/` et `forgejo/` côté
> `homelab_emeriss`.
>
> ⚠️ **Ce composant en dépend tout de même, à sens unique.** Les trois alertes de
> `forgejo-backup.rules` ci-dessous lisent des séries qui arrivent par **le scrape de
> hosts-monitoring** : `forgejo-ctl backup` les dépose dans le collecteur `textfile` de
> node-exporter. Une panne là-bas les rend aveugles. Rien ne le vérifie, c'est écrit des deux
> côtés.

## Pourquoi il existe

Le 2026-09-09, pendant l'exercice de reprise en place, Forgejo est resté indisponible **~45
minutes** — PVC détruit, base détruite, Deployment supprimé — et **aucune alerte n'a sonné**.

`KubeDeploymentReplicasMismatch`, fournie par kube-prometheus-stack, aurait couvert un Deployment
en panne. Mais la procédure de reprise **supprimait** le Deployment : la série
`kube_deployment_status_replicas_available` disparaissait, et une expression qui la compare à zéro
ne se déclenche jamais. **Série absente ≠ série à zéro.** Le composant est né de là, et la leçon
gouverne encore les neuf règles : chaque valeur surveillée est doublée d'un `absent(...)`.

Le volet **base** et les alertes de **sauvegarde** ont été ajoutés le 2026-09-11. La bascule vers
Docker avait supprimé, sans la remplacer, la seule source qui parlait de la base — les métriques
CNPG de `forgejo-db` — et la sauvegarde n'avait, elle, jamais eu d'alerte : `forgejo-backup.service`
portait un `OnFailure=` en commentaire, jamais écrit.

## Fichiers

- `forgejo-monitoring.app.yaml` — Application, ns **`monitoring`**, wave `2`
- `manifests/scrapeconfig.yaml` — la **forge** (auth `Bearer`, 60 s)
- `manifests/scrapeconfig-db.yaml` — la **base** (auth `Basic`, 60 s)
- `manifests/prometheusrule.yaml` — neuf alertes, groupes `forgejo.rules`, `forgejo-backup.rules`,
  `forgejo-db.rules`
- `manifests/forgejo-metrics.secret.example.yaml` — template du token `Bearer` de la forge
- `manifests/forgejo-db-metrics.secret.example.yaml` — template du couple `basicAuth` du
  `postgres-exporter`. ⚠️ Son `SealedSecret` **n'est pas encore dans le repo** : ligne commentée
  dans `kustomization.yaml` — cf. *Opérations*

## Les neuf règles

### `forgejo.rules` — l'application

| Alerte | Expression | `for` |
| --- | --- | --- |
| `ForgejoDown` | `up{job="forgejo"} == 0` | 10 min |
| `ForgejoScrapeMissing` | `absent(up{job="forgejo"})` | 15 min |

### `forgejo-backup.rules` — les sauvegardes

⚠️ Ces trois-là lisent `forgejo_backup_*`, qui arrive par le scrape de
[hosts-monitoring](../hosts-monitoring/README.md), pas par ceux de ce composant.

| Alerte | Expression | `for` |
| --- | --- | --- |
| `ForgejoBackupTooOld` | `time() - ..._last_success_... > 30 h` | 30 min |
| `ForgejoBackupNoMetric` | `absent(..._last_success_...)` | 6 h |
| `ForgejoBackupFailed` | `..._last_run_success == 0` | 15 min |

### `forgejo-db.rules` — la base

| Alerte | Expression | `for` |
| --- | --- | --- |
| `ForgejoDbExporterDown` | `up{job="forgejo-db"} == 0` | 10 min |
| `ForgejoDbScrapeMissing` | `absent(up{job="forgejo-db"})` | 15 min |
| `ForgejoDbDown` | `pg_up == 0` | 5 min |
| `ForgejoDbDeadlocks` | `increase(...[1h]) > 0` | — |

## Contraintes

- **Un `ServiceMonitor` ne peut rien faire ici.** Il sélectionne des `Service` ; il n'y a plus ni
  Service ni pod. La `ScrapeConfig` est la seule forme qui accepte une cible statique hors cluster.
  ⚠️ Elle exige le label `release: kube-prometheus-stack`, faute de quoi elle est ignorée **sans
  erreur** — premier point à vérifier si une cible n'apparaît pas dans `/targets`.
- **Les deux `job` sont les seuls points de couplage** entre les ScrapeConfigs, les règles et le
  dashboard. Ils sont posés par `relabeling` ; sans lui, une ScrapeConfig nomme son job
  `scrapeConfig/monitoring/<nom>`. Les changer casse tout, silencieusement.
- **⚠️ Les trois alertes de sauvegarde ne lisent AUCUNE des deux cibles de ce composant.**
  `forgejo_backup_*` arrive par le scrape de [hosts-monitoring](../hosts-monitoring/README.md) :
  `forgejo-ctl backup` dépose un `.prom` dans le collecteur `textfile` de node-exporter.
  Conséquence non intuitive : `ExternalNodeDown`, `ExternalNodeScrapeMissing` et
  `ExternalNodeTextfileCollectorFailing` — trois alertes d'un **autre** composant — rendent
  `forgejo-backup.rules` aveugle. C'est pourquoi elles sont citées dans l'ordre de lecture
  ci-dessous.
  ⚠️ Elles sélectionnent `job="external-node"` : ce job appartient à l'autre composant, et le
  changer là-bas casse des règles **ici**.
- **Deux secrets, deux mécanismes.** La forge s'authentifie par `Bearer` (son `[metrics] TOKEN`),
  le `postgres-exporter` par `Basic` (`forgejo-db-metrics`). Le `node-exporter` de la même machine
  a **un troisième** Secret, dans l'autre composant : ce n'est pas une isolation cryptographique —
  même hôte, même `docker inspect` — c'est une indépendance de cycle de vie.
- **Aucun des deux secrets n'est partagé avec ce qu'il surveille — ils en sont des COPIES.** La
  référence vit sur la machine Docker (`app.ini` pour l'un, deux `web-config.yml` pour l'autre).
  Une divergence se manifeste en **401**, donc en `up == 0`, donc en alerte de disponibilité :
  **un secret mal tourné allume une alerte de panne**. Assumé — un scrape muet n'est pas
  distinguable d'une cible morte.
  ⚠️ **Ordre de rotation du `basicAuth` : le cluster D'ABORD, l'hôte ensuite.** `exporter-toolkit`
  relit son fichier à chaque requête ; ce Secret demande un commit et une synchro ArgoCD.
- **La saturation des connexions PostgreSQL n'est volontairement pas alertée.** Le nom de la
  métrique (`pg_stat_activity_count`) a bougé entre versions de l'exportateur, et une règle bâtie
  dessus casserait en silence à la première PR Renovate. Une forge à un seul écrivain n'approche
  pas les 100 connexions par défaut. La série est même **écartée au scrape** (`metricRelabelings`)
  : ses sept étiquettes, dont `wait_event`, en font une bombe de cardinalité.
- **« La base est morte » était déjà alerté avant `forgejo-db.rules`**, par une chaîne indirecte :
  base injoignable → healthcheck de la forge en échec → `up{job="forgejo"} == 0` → `ForgejoDown`.
  Ce que le volet base ajoute est la capacité à **nommer** la cause (`pg_up`) au lieu de la
  déduire, plus les deadlocks et la volumétrie.
- **Ces alertes couvrent aussi, sans le dire, la source du GitOps.** La forge sert
  `homelab_gitops` : `ForgejoDown` signifie qu'ArgoCD ne se réconcilie plus.
- **Tout le chemin réseau des trois scrapes est hors du cluster** : DNS LAN, route vers
  `192.168.1.50`, déclaration des **trois** hostnames AU reverse proxy, certificat wildcard
  `*.lan.wittner.tech`. ⚠️ Un hostname non déclaré là-bas répond **404** alors que tout est sain
  ici (cf. [doc/reseau.md](../../../doc/reseau.md)).
- **Le TLS s'arrête au proxy.** Entre Traefik et la machine, le mot de passe de scrape passe en
  clair sur le LAN — conséquence assumée de ne pas gérer un certificat auto-signé, qui imposerait
  un `insecureSkipVerify` que ce dépôt refuse.

## Ce qui vit en face

Les trois cibles sont produites par le dépôt **`homelab_emeriss`**, et rien ici ne peut les
vérifier :

| Ce qui produit la cible | Où |
| --- | --- |
| `/metrics` de la forge | `forgejo/compose.yaml`, `[metrics] ENABLED` |
| `postgres-exporter` | `forgejo/compose.yaml` — même pile que la base, il meurt avec elle |
| les deux routers | `forgejo/traefik/forgejo.yml` — copie de référence, complétée le 2026-09-11 (elle porte désormais `forgejo-metrics` **et** `forgejo-db-metrics`). ⚠️ Le fichier réellement servi vit dans `homelab_proxmox` et **ne connaît pas encore `forgejo-db-metrics`** : tant qu'il n'y est pas déposé, la cible répond **404** sans que rien, ici, soit en faute |

Et une source qui n'appartient **pas** à ce composant, dont dépendent pourtant les trois alertes de
sauvegarde :

| | Où |
| --- | --- |
| `forgejo_backup_*` | `forgejo/bin/forgejo-ctl`, fonction `publier_metriques` → collecteur `textfile` de la pile **`node-exporter/`**, scruté par [hosts-monitoring](../hosts-monitoring/README.md) |

## Opérations

- **Sceller le `basicAuth` du `postgres-exporter`** (à faire une fois ; sans lui la cible base
  reste en 401) :
  ```bash
  cp cluster/app/forgejo-monitoring/manifests/forgejo-db-metrics.secret.example.yaml \
     cluster/app/forgejo-monitoring/manifests/forgejo-db-metrics.secret.yaml
  openssl rand -base64 24        # à reporter dans `password`
  kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
    < cluster/app/forgejo-monitoring/manifests/forgejo-db-metrics.secret.yaml \
    > cluster/app/forgejo-monitoring/manifests/forgejo-db-metrics.sealed.yaml
  rm cluster/app/forgejo-monitoring/manifests/forgejo-db-metrics.secret.yaml
  ```
  puis **décommenter** la ligne `forgejo-db-metrics.sealed.yaml` de `kustomization.yaml` dans le
  **même commit**, et poser le hachage bcrypt de ce mot de passe dans
  `/etc/forgejo/metrics-web-config.yml` — ce fichier-là seulement.
  ⚠️ Le `node-exporter` de la même machine a **son propre** Secret, à sceller séparément dans
  [hosts-monitoring](../hosts-monitoring/README.md). Tant qu'il manque, les trois alertes de
  sauvegarde d'ici sont aveugles.
- **Sceller le token de la forge** — même procédure, fichier `forgejo-metrics.secret.example.yaml`.
- **Vérifier les cibles et les règles** :
  ```bash
  kubectl -n monitoring get scrapeconfig,prometheusrule
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
  curl -s 'localhost:19090/api/v1/targets?state=active' | grep -o 'forgejo[^,]*' | head
  curl -s 'localhost:19090/api/v1/rules?type=alert' | grep -o 'Forgejo[A-Za-z]*' | sort -u
  ```
  ⚠️ Pas de `kubectl exec` dans le conteneur `prometheus` : son image n'a **ni shell ni `wget`**
  (`exec: "sh": executable file not found in $PATH`). Le seul accès à l'API passe par un
  port-forward.
- **Distinguer une forge morte d'un scrape cassé**, dans cet ordre :
  ```bash
  # 1. le message d'erreur exact de la cible (401 = secret, timeout = réseau, 404 = proxy)
  curl -s 'localhost:19090/api/v1/targets?state=active' | python3 -m json.tool | grep -A2 lastError
  # 2. la forge elle-même, par son chemin normal
  curl -sI https://forgejo.wittner.tech/ | head -1
  # 3. les deux endpoints depuis le LAN
  curl -sI -H "Authorization: Bearer <token>" https://forgejo-metrics.lan.wittner.tech/metrics | head -1
  curl -sI -u prometheus:<motdepasse> https://forgejo-db-metrics.lan.wittner.tech/metrics | head -1
  ```
- **Lire les alertes dans le bon ordre.** Certaines rendent les autres aveugles et se traitent en
  premier :
  - `ForgejoDbExporterDown` / `ForgejoDbScrapeMissing` → `ForgejoDbDown` ne peut rien dire ;
  - ⚠️ `ExternalNodeScrapeMissing` et `ExternalNodeTextfileCollectorFailing`, **de
    [hosts-monitoring](../hosts-monitoring/README.md)** → `forgejo-backup.rules` ment. Tant que
    l'une des deux sonne, ne pas lire `ForgejoBackupNoMetric` comme « aucune sauvegarde » : la
    sauvegarde tourne peut-être très bien, c'est son canal de publication qui est coupé.
