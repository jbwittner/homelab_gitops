# forgejo

## Rôle

Forge Git auto-hébergée (dépôts, issues, PR, registre de paquets, Actions). Base de données
PostgreSQL dédiée, portée par un `Cluster` CNPG (opérateur fourni par
[`cnpg`](../cnpg/README.md)).

**Un seul hostname, tout en HTTPS** — `https://forgejo.wittner.tech`, par un **tunnel
Cloudflare** (LXC `cloudflared`, 192.168.1.56), puis routeur HTTP de Traefik (192.168.1.50) vers
`shared-gw` (192.168.1.80), listener `https-public` (cf. [doc/reseau.md](../../../doc/reseau.md)).
Web, API, clone et push passent tous par là.

Le clone SSH a été **coupé le 2026-09-06** : plus de second hostname, plus de port ouvert sur la
box, plus d'IP d'origine publiée — cf. [§Réseau](#le-ssh-a-été-coupé).

## Fichiers

- `forgejo.app.yaml` — Application (archétype (b) : chart + `$values` + `manifests/`).
  Le chart n'existe **qu'en OCI** : `repoURL` est écrit sans le préfixe `oci://`, seule forme
  qu'ArgoCD accepte (et que Renovate suit, via la datasource `docker`).
- `helm-values.yaml` — base externe CNPG, exposition déléguée aux manifestes, SSH coupé
  (`DISABLE_SSH`), PVC protégé du prune, admin par `existingSecret`
- `manifests/namespace.yaml` — ns `forgejo` (wave -1)
- `manifests/forgejo-db.yaml` — `Cluster` CNPG (l'opérateur génère le service `forgejo-db-rw`
  et le secret `forgejo-db-app`), **co-localisé avec le pod Forgejo** par
  `affinity.additionalPodAffinity` — cf. §Placement. Porte aussi le `spec.plugins` qui met la base
  sous **archivage WAL continu** — cf. §Sauvegarde
- `manifests/forgejo-db-objectstore.yaml` — `ObjectStore` barman-cloud : bucket GCS, credentials,
  rétention 30 j — cf. §Sauvegarde
- `manifests/forgejo-db-scheduledbackup.yaml` — sauvegarde de base quotidienne à 02:00 **UTC**
  (⚠️ cron à **six** champs) — cf. §Sauvegarde
- `manifests/forgejo-db-gcs.secret.example.yaml` — template **versionné et vide** du credential
  GCS. Scellé **à part** du template multi-documents des trois autres Secrets, pour que tourner la
  clé GCP n'oblige pas à re-fournir le mot de passe admin et les quatre secrets cryptographiques —
  cf. §Câblage du credential GCS
- `manifests/forgejo-admin.secret.yaml` — template **en clair, gitignoré** (`*.secret.yaml`) des
  **trois** Secrets du composant, en trois documents YAML : `forgejo-admin`
  (`username` / `password`, requis au démarrage), `forgejo-secrets` (les quatre secrets
  cryptographiques) et `forgejo-smtp` (mot de passe du relais). `kubeseal` lisant un flux
  multi-documents, les trois se scellent d'un coup vers `manifests/forgejo-admin.sealed.yaml`,
  canal [sealed-secrets](../../infra/sealed-secrets/README.md) — cf. §Câblage des secrets
- `manifests/forgejo-httproute.yaml` — HTTPRoute → `shared-gw`, listener `https-public`,
  **plus les en-têtes de sécurité** (HSTS, `nosniff`, `Referrer-Policy`) posés par un filtre
  `ResponseHeaderModifier` — cf. §Exposition publique
- `manifests/forgejo-netpol.yaml` — `CiliumNetworkPolicy` ingress **et** egress du pod
  applicatif. Porte aussi l'ouverture du port 3000 au namespace `renovate` — cf. §Exposition
  publique
- `manifests/forgejo-robots.yaml` — ConfigMap du `robots.txt`, monté sur `/data/gitea/robots.txt`
  par `extraVolumes` / `extraContainerVolumeMounts` — cf. §Exposition publique
- `manifests/forgejo-admin.secret.example.yaml` — template de scellement **versionné et vide de
  toute valeur** : la copie de référence du clair `*.secret.yaml`, qui est gitignoré et supprimé
  après `kubeseal`. Il ne porte aucun secret et n'est **pas** dans le `kustomization.yaml` — il se
  recopie, il ne s'applique pas — cf. §Câblage des secrets
- `manifests/forgejo-admin.sealed.yaml` — les **trois** Secrets scellés d'un coup. Les trois
  portent `velero.io/exclude-from-backup` — cf. §Sauvegarde
- `manifests/forgejo-db-gcs.sealed.yaml` — credential GCS scellé, également exclu des sauvegardes
- `manifests/kustomization.yaml` — assemblage. Les lignes `forgejo-admin.sealed.yaml` et
  `forgejo-db-gcs.sealed.yaml` y sont **actives** : le scellement a eu lieu. Une ligne pointant un
  fichier absent ferait échouer le `kustomize build` entier, donc l'Application — c'est pourquoi
  on ne décommente que dans le commit qui produit le fichier

## Contraintes

> [!CAUTION]
> **Le PVC `forgejo-data` est la donnée critique du composant, avant la base.** Le `[storage]` de
> Forgejo est en `local` par défaut et enracine **huit** sous-systèmes sous `APP_DATA_PATH`
> (`/data`) : dépôts Git, LFS, **registre de paquets**, **artefacts et logs Actions**, pièces
> jointes, archives de dépôts, avatars, index bleve — plus `conf/app.ini`. Tout est sur ce volume,
> rien n'est en base sauf les métadonnées.
>
> Au premier démarrage, l'init-container génère quatre secrets — `security.SECRET_KEY`,
> `security.INTERNAL_TOKEN`, `oauth2.JWT_SECRET`, `server.LFS_JWT_SECRET` — et les écrit dans
> `/data/gitea/conf/app.ini`, **sur le volume**. Ils ne sont ni dans Git, ni scellés, ni dans
> un objet Kubernetes. Le script du chart les régénère à chaque démarrage puis les **jette** dès
> qu'un `app.ini` existe (`config_environment.sh`, section « safety to prevent rewrite of secret
> keys ») : c'est ce qui les rend stables, et c'est aussi ce qui rend le volume irremplaçable.
> Perdre le PVC en gardant la base ne donne pas une instance dégradée mais une instance dont les
> jetons, sessions et objets LFS déjà en base ne sont plus déchiffrables.
>
> D'où les deux garde-fous sur le PVC dans `helm-values.yaml` :
> `argocd.argoproj.io/sync-options: Prune=false,Delete=false`. La StorageClass
> `openebs-lvm-thin` étant en `reclaimPolicy: Delete`, une suppression de PVC détruit le LV dans
> la foulée — sans ces options, le chemin décrit dans
> [`argocd-cm`](../../infra/argocd/manifests/argocd-cm.yaml) s'applique ici tel quel.

- **La sauvegarde du composant passe par DEUX chaînes distinctes, et pas par une seule.** Le PVC
  `forgejo-data` est copié par kopia dans le périmètre velero ; la base `forgejo-db` a sa propre
  chaîne native barman-cloud et est **explicitement exclue** de kopia. Aucune des deux ne couvre ce
  que couvre l'autre — cf. §Sauvegarde.
- Le mot de passe de la base n'est **pas** géré ici : il vient du secret auto-généré par CNPG
  (`forgejo-db-app`). Ne pas le sceller, ne pas le figer. Le **seul** secret scellé du composant
  est le compte d'administration.
- **Le `SealedSecret` est chiffré pour le couple (`forgejo-admin`, `forgejo`)** : le renommer ou
  le déplacer de namespace exige de le resceller. Il l'est aussi pour la clé du contrôleur du
  cluster — un `sealed-secrets` réinstallé à neuf ne sait plus le déchiffrer, et le seul signal
  est le pod qui reste en `CreateContainerConfigError`.
- Le composant `cnpg` doit tourner avant : sans la CRD `Cluster`, le manifeste DB échoue.
- **Le Service `forgejo-ssh` existe encore, en `ClusterIP`, et c'est voulu.** Le chart 17.1.5 rend
  `ssh-svc.yaml` — et le `containerPort` correspondant — **sans aucune condition** : il n'y a pas
  de `service.ssh.enabled`, le seul levier est le type. L'objet est inerte : aucune IP prise sur
  le pool LB-IPAM, aucune annonce L2, aucun endpoint puisque le serveur SSH ne démarre plus.
  ⚠️ Ne pas le repasser en `LoadBalancer` en croyant nettoyer une incohérence — cela rouvrirait
  une exposition sans rien derrière.
- **`gitea.config.server.PROTOCOL` n'est PAS posé, et c'est voulu** : la valeur par défaut (`http`)
  est la bonne, TLS étant terminé au Gateway alors que `ROOT_URL` est en `https://`. La clé n'existe
  que sous forme de commentaire dans `helm-values.yaml` (§`server`), justement pour que personne ne
  l'« aligne » sur `https` — ce qui ferait attendre à Forgejo un certificat qu'il n'a pas.
- L'inscription libre est coupée (`service.DISABLE_REGISTRATION: true`) : l'instance est sur un
  hostname public.
- **Un seul replica.** Forgejo n'est pas HA-ready et le chart refuse plusieurs configurations
  au-delà de 1 (indexeur `bleve`, `accessModes: ReadWriteOnce`, GC par cron).

## Dimensionnement du volume

Les 100Gi de `forgejo-data` ne bornent **rien** aujourd'hui, et trois faits se combinent mal :

- **Le registre de paquets est actif par défaut** (`[packages] ENABLED = true`) : conteneurs,
  npm, maven, PyPI, Helm… Sur une instance au hostname public, c'est le poste qui grossit le plus
  vite et le moins visiblement — une image de conteneur pèse des centaines de Mo.
- **Actions est actif par défaut** (`[actions] ENABLED = true`), avec `ARTIFACT_RETENTION_DAYS =
  90` et `LOG_RETENTION_DAYS = 365`. Aucun runner n'est déployé aujourd'hui (§Non retenu), donc
  rien ne produit d'artefact — mais le jour où un runner arrive, la rétention par défaut est de
  trois mois.
- **Aucune limite applicative** : `[quota] ENABLED` reste à `false`, et la StorageClass est en
  `thinProvision: "no"`. Le LV est réservé en entier dans le VG dès la création (pas de
  surallocation possible), mais rien n'empêche de le **remplir**. Un volume plein ne dégrade pas,
  il fait échouer les écritures.

Les crons de ménage existent et tournent (`cron.cleanup_packages` toutes les nuits,
`cron.cleanup_actions` aussi) mais ils ne ramassent que le **non référencé** : un paquet qu'on a
publié et jamais supprimé reste, indéfiniment.

### Le choix retenu : surveillance, pas de plafond

Pas de quota applicatif. L'instance est **mono-utilisateur** : le mode de panne que le quota
protège — un compte tiers qui remplit le volume — n'existe pas ici, et le seul producteur de
données est aussi celui qui surveille. La contrepartie est explicite : **rien ne préviendra**, le
signal sera un `ENOSPC` sur une écriture (push refusé, upload de paquet en échec), pas une alerte.

À surveiller à la main, périodiquement :
```bash
kubectl -n forgejo exec deploy/forgejo -- df -h /data
kubectl -n forgejo exec deploy/forgejo -- sh -c 'du -sh /data/git /data/gitea/* | sort -h'
```

Le poste à regarder en premier est `/data/gitea/packages` : c'est le seul qui grossit sans qu'on
s'en rende compte, une image de conteneur pesant des centaines de Mo.

> [!NOTE]
> Ce choix se réexamine si un compte est ouvert à quelqu'un d'autre, ou si un runner Actions est
> déployé (§Non retenu) — les artefacts de builds sont alors produits par des workflows, pas par
> une action humaine, et la rétention par défaut est de 90 jours.

### Ce que la StorageClass impose

Deux propriétés d'`openebs-lvm-thin` tirent en sens inverse et fixent la méthode :

- **`thinProvision: "no"`** — le LV réserve ses 100Gi dans le VG **dès la création**, utilisés ou
  non. Ce qui est pris ici n'est pas disponible aux autres composants du nœud, et la base CNPG
  co-localisée en prend 10 de plus.
- **`allowVolumeExpansion: true`** — agrandir plus tard se fait **à chaud**, sans recréer le PVC ni
  redémarrer le pod (§Opérations).

Donc : sous-dimensionner se rattrape sans interruption, surdimensionner immobilise du VG tout de
suite. On ne **rétrécit jamais** un PVC — l'opération n'est pas symétrique. Vérifier la place
restante avant tout agrandissement :
```bash
kubectl -n openebs exec ds/lvmvg-bootstrap -- vgs lvmvg   # VSize / VFree
```

### Les leviers, si ça déborde

| Levier | Effet | Réversible |
| --- | --- | --- |
| `persistence.size` | agrandir à chaud (§Opérations) | oui, dans un seul sens (on ne rétrécit pas) |
| `gitea.config.quota.ENABLED: true` + `quota.default.TOTAL` | plafond **par utilisateur**, refus applicatif au lieu d'un `ENOSPC`. Quota « soft » et qualifié d'« early support » par Forgejo : une opération déjà lancée va au bout | oui |
| `gitea.config.packages.ENABLED: false` | coupe le registre de paquets | oui, mais les paquets déjà publiés deviennent inaccessibles |

Ces trois réglages passent par `gitea.config`, qui est un **passe-plat vers `app.ini`** et non une
liste fermée de paramètres du chart : toute section du
[Configuration Cheat Sheet](https://forgejo.org/docs/v15.0/admin/config-cheat-sheet/) s'y écrit en
bloc YAML minuscule à clés majuscules, qu'elle figure ou non dans la liste des paramètres du chart.

## Sauvegarde

**Deux chaînes, deux domaines de données, aucune redondance entre elles.**

| Donnée | Chaîne | Cohérence | Rétention | Bucket |
| --- | --- | --- | --- | --- |
| PVC `forgejo-data` (100Gi) — dépôts, LFS, paquets, `app.ini` | velero / kopia, 03:00 **UTC** | **étalée** ⚠️ | 30 j (`ttl: 720h`) | `homelab-velero-backups-*` |
| Base `forgejo-db` (10Gi) — issues, PR, comptes, sessions | barman-cloud (CNPG natif), 02:00 **UTC** + WAL continu | **transaction** + PITR | 30 j (`retentionPolicy`) | bucket CNPG dédié |

> [!WARNING]
> **« Étalée » et non « cohérente-crash », et l'écart n'est pas cosmétique.** La copie kopia est un
> **parcours du système de fichiers vivant** : aucun `hooks` sur la schedule, aucune annotation
> `pre.hook.backup.velero.io` sur le pod, `snapshotVolumes: false` et **aucune
> `VolumeSnapshotClass` déclarée** dans le cluster. Un crash donne un instantané *unique* de tout
> le volume ; un parcours donne le fichier A lu à t₀ et le fichier B à t₀+5 min — il n'existe
> aucun instant réel où le volume a ressemblé à sa copie.
>
> Le cas qui mord : un `git push` en vol, dont les `refs` sont copiées après leur mise à jour mais
> avant les objets qu'elles désignent. `git fsck` l'attrape, et c'est pour cela qu'il est dans la
> checklist de [`doc/forgejo-pra-exercice.md`](../../../doc/forgejo-pra-exercice.md).
>
> Le correctif structurel — `VolumeSnapshotClass` sur `openebs lvm-localpv`, puis
> `snapshotVolumes: true` avec le data mover — **n'est pas engagé**. C'est le principal levier
> d'amélioration identifié pour ce composant.
>
> La chaîne native de la base, elle, est bien à chaud au sens PostgreSQL : `pg_backup_start` /
> `pg_backup_stop` encadrent la copie et les WAL de la fenêtre la rendent cohérente-TRANSACTION.

> [!IMPORTANT]
> **Le PVC de la base est explicitement EXCLU de la copie kopia**
> ([`volume-policies.yaml`](../../infra/velero/manifests/volume-policies.yaml), règle `pvcLabels`),
> alors même que le namespace `forgejo` est dans `includedNamespaces`. Ce n'est pas un oubli : une
> copie kopia d'un volume PostgreSQL vivant vaut un `kill -9` suivi d'un redémarrage, quand la
> sauvegarde native encadre la copie par `pg_backup_start` / `pg_backup_stop`. Les **objets**
> Kubernetes du namespace (dont le `Cluster` et ses Secrets auto-générés) restent, eux, sauvegardés
> par velero — ce sont eux qui permettent de **recréer** la base ; le natif la **remplit**.

Trois fichiers, indissociables. En retirer un ne produit pas une erreur mais une chaîne inerte :

- `forgejo-db.yaml` → `spec.plugins` avec `isWALArchiver: true` — **c'est cette clé qui met la base
  sous sauvegarde**. Sans elle, rien n'archive. Sans `isWALArchiver`, les sauvegardes de base
  partent mais aucun WAL ne les complète : elles sont vertes et le PITR n'existe pas.
- `forgejo-db-objectstore.yaml` → où, avec quelles clés, pour combien de temps.
- `forgejo-db-scheduledbackup.yaml` → la sauvegarde de base quotidienne. ⚠️ Son `schedule` est un
  cron **à six champs** (les secondes en premier, robfig/cron de Go) : écrit à cinq champs, il est
  accepté et se décale silencieusement d'un cran.

> [!CAUTION]
> **Ce qui rend l'exclusion de kopia défendable, ce sont les alertes** de
> [cnpg-monitoring](../cnpg-monitoring/README.md) — `CNPGWalArchivingBacklog`,
> `CNPGBackupTooOld`, `CNPGNoBackupYet`. Les supprimer laisserait la base avec une chaîne unique
> **et** aucun moyen de la voir mourir. Les deux décisions se tiennent ensemble, exactement comme
> pour [openbao](../../infra/openbao/README.md).

Ce que ni l'une ni l'autre ne couvre : **une lifecycle rule GCS** posée par erreur sur l'un des deux
buckets. Les deux outils font leur propre GC, et aucune métrique du cluster ne verrait un bucket
purgé sous eux.

> [!IMPORTANT]
> **Deux sauvegardes ne font pas un plan de reprise.** Le PRA du composant — quoi restaurer selon
> le sinistre, dans quel ordre, à quel instant, et par quoi commencer quand il ne reste rien — vit
> dans [`doc/forgejo-pra.md`](../../../doc/forgejo-pra.md). Il est **éprouvé** par
> [`script/forgejo-pra-script.sh`](../../../script/forgejo-pra-script.sh), qui restaure les deux
> chaînes dans une préprod jetable et la vérifie
> ([`doc/forgejo-pra-exercice.md`](../../../doc/forgejo-pra-exercice.md)).
>
> Trois points de ce plan ne se déduisent d'aucun fichier de ce dossier :
> - **les deux moitiés ne sont jamais cohérentes entre elles** — le PVC est figé à 03:00 UTC, la base
>   se rejoue ; l'alignement se fait toujours en amenant la base à l'instant du PVC ;
> - **la base à 02:00 UTC et le PVC à 03:00 UTC, dans cet ordre** (les deux chaînes n'ont pas de
>   champ `timezone`), parce que la sauvegarde de base doit
>   précéder la copie du PVC — sinon le rejeu part de la veille ;
> - **le point de reprise unique est une clé GCP**, pas une sauvegarde : sur un cluster reconstruit
>   à neuf, le `SealedSecret` `velero-gcs` est indéchiffrable et plus rien ne se restaure.

### Les générations de `serverName`

`manifests/forgejo-db.yaml` porte, en plus de l'archivage, **la procédure de reprise écrite à
l'avance** : un bloc `bootstrap.recovery` + `externalClusters`. Il est **inerte tant que le
`Cluster` existe** — `bootstrap` n'est lu qu'à la création — et ne reprend un sens que le jour où on
supprime le `Cluster` pour le reconstruire depuis le bucket. Ce n'est donc pas un résidu à nettoyer.

Reprendre **sous le même nom** (`forgejo-db`) évite de suivre `forgejo-db-rw` et `forgejo-db-app`
dans `helm-values.yaml` à chaque sinistre. Ce sont donc **deux `serverName`** qui portent les
générations, et ils se déplacent ensemble :

| Rôle | Où | Valeur au 2026-09-09 |
|---|---|---|
| **lecture** — la génération qui porte les sauvegardes à rejouer | `externalClusters[0].plugin.parameters.serverName` | `forgejo-db-v4` |
| **écriture** — où le cluster repris archivera | `spec.plugins[].parameters.serverName` | `forgejo-db-v5` |

> [!CAUTION]
> **Toute reprise impose de bumper les deux (v5 → v6, et v4 → v5 en lecture), et le bump se fait
> APRÈS la destruction du `Cluster`, jamais avant.** Deux raisons, et ce n'est pas la plus intuitive
> qui contraint :
> 1. omis ou identique à la source, `serverName` vaudrait le nom du `Cluster` et le cluster repris
>    archiverait **par-dessus** les WAL dont il vient ;
> 2. surtout, `barman-cloud-check-wal-archive` refuse de démarrer sur un prefix **non vide**, quelle
>    que soit la filiation — « `Expected empty archive` ». La cible doit n'avoir **jamais servi**.
>
> Bumper pendant que le cluster vit le fait archiver dans la seconde sous la nouvelle génération,
> qui cesse d'être vide : elle est alors **brûlée définitivement**. C'est le sort de
> `forgejo-db-v2`, consommé par un `initdb` accidentel de quelques minutes.
>
> ⚠️ Juste après une reprise, la nouvelle génération n'a **aucune** sauvegarde de base : sa fenêtre
> PITR est vide. En prendre une immédiatement (`script/cnpg-barman-plugin-script.sh backup`) sans
> attendre la `ScheduledBackup`.

La procédure complète est en
[`doc/forgejo-pra.md`](../../../doc/forgejo-pra.md) §8 — étape B (reprise en place) et étape N
(perte du namespace entier).

## Placement

La base et l'applicatif sont **contraints sur le même nœud** (`affinity.additionalPodAffinity`
du `Cluster`, `topologyKey: kubernetes.io/hostname`).

Ce n'est pas une optimisation de latence, c'est une réduction du domaine de panne. Le stockage du
cluster est node-local et **non répliqué** (cf. [`openebs`](../../infra/openebs/README.md)) : le PV
colle son pod à un nœud par `nodeAffinity`, et perdre ce nœud rend le volume injoignable. Laisser
le scheduler séparer `forgejo-data` et le volume PostgreSQL ferait donc dépendre la forge de
**deux** nœuds au lieu d'un, sans rien gagner en disponibilité — ni l'un ni l'autre n'a de copie
ailleurs. L'aller-retour réseau économisé sur chaque requête SQL est un bonus, pas le motif.

Trois propriétés de cette règle méritent d'être connues avant d'y toucher :

- **Elle est en sens unique** : la base suit Forgejo, jamais l'inverse. Deux règles `required`
  symétriques se bloqueraient mutuellement — une affinité de pod exige que sa cible soit *déjà*
  schedulée, donc aucun des deux ne pourrait partir en premier.
- **Le pod CNPG reste `Pending` tant que le pod Forgejo n'existe pas**, au premier déploiement.
  C'est l'ordre attendu : Forgejo n'a aucune contrainte, il atterrit et lie son PVC
  (`WaitForFirstConsumer`), la base le rejoint. Entre les deux, l'init-container `configure-gitea`
  boucle sur `gitea migrate` faute de base — le chart le prévoit et le journalise.
- **Elle ne se pose pas après coup sur un déploiement dont les volumes sont déjà séparés** : les
  PV épinglant chacun leur pod, la contrainte deviendrait insatisfaisable et le pod CNPG resterait
  `Pending` indéfiniment. Il faudrait d'abord migrer un volume (sauvegarde, suppression du PVC,
  recréation).

`enablePodAntiAffinity` est à `false` pour la même raison : avec `instances: 1`, l'anti-affinité
générée par l'opérateur n'a aucun pair à écarter. **À remettre à `true` si `instances` passe à 2
ou plus**, sinon deux instances de la même base peuvent partager un nœud et la réplication ne
protège plus de rien.

## Réseau

**Un seul hostname, un seul chemin d'entrée.** Web, API, clone et push Git passent tous par
`https://forgejo.wittner.tech` et le tunnel Cloudflare.

```
client Internet
  → edge Cloudflare        (proxifié : WAF, rate-limiting, absorption DDoS)
  → tunnel, LXC cloudflared .56
  → 192.168.1.50   Traefik      (routeur HTTP, `serversTransport` avec SNI)
  → 192.168.1.80   shared-gw    (listener `https-public`, TLS terminé)
  → pod forgejo    :3000
```

| Hostname | Enregistrement DNS | Chemin | Routeur Traefik | Suite |
| --- | --- | --- | --- | --- |
| `forgejo.wittner.tech` | Tunnel, **Proxied** | edge → tunnel → `https://192.168.1.50` (`originServerName`) | HTTP, `Host(...)`, entrypoint `websecure` | `shared-gw` (192.168.1.80), HTTPRoute `https-public` |

⚠️ Depuis le LAN, le DNS interne renvoie `192.168.1.50` pour **tout** `*.wittner.tech` et
court-circuite les sauts amont. **Un test local ne prouve donc rien sur le chemin externe** —
c'est le piège de diagnostic principal de cette section, et il a coûté plusieurs fausses pistes.

### Le SSH a été coupé

Décision du **2026-09-06**. Le clone SSH vivait sur un second hostname `git-ssh.wittner.tech`, en
enregistrement A DNS-only vers l'IP publique, avec une redirection 2222 sur la box et un routeur
TCP Traefik vers un Service LoadBalancer. Tout ce chemin a été supprimé.

Ce que la suppression rend :

- **Plus aucun port entrant.** La redirection 2222 était le seul port ouvert de l'installation.
  Le web n'en a jamais eu besoin : le tunnel est une connexion **sortante**.
- **L'IP d'origine n'est plus publiée.** C'était le prix de l'enregistrement `git-ssh` — une fuite
  d'information, durable puisque l'IP est fixe. Elle disparaît avec lui.
- **Le WAF de l'edge cesse d'être contournable.** Toute la surface (UI, API, registre de paquets,
  Git) est derrière lui, sans exception.
- **Un seul nom à résoudre, donc un seul mode de panne DNS.** L'essentiel des incidents de cette
  section venait de ce que deux noms de la même zone n'avaient pas le même type d'enregistrement.

Ce qu'elle coûte :

- **Le plafond de 100 Mo par requête** du plan gratuit Cloudflare s'applique maintenant au Git. Un
  `git push` est un seul POST : au-delà, un `413` que git ne sait pas expliquer. Le LFS n'est pas
  mieux loti — chaque objet est une requête, un fichier de plus de 100 Mo échoue pareil.
  ⚠️ L'échappatoire est le DNS interne, et elle est réelle : **depuis le LAN**, le nom résout
  `192.168.1.50` et le trafic ne traverse jamais l'edge, donc aucun plafond. Un import initial
  volumineux se fait à la maison. Ce n'est pas un contournement, c'est le chemin normal du LAN.
- **L'authentification passe d'une clé à un jeton.** Un jeton est un secret porteur, transmis à
  chaque requête, là où une clé privée ne quitte jamais le poste. En contrepartie il se scope,
  s'expire et se révoque un par un — ce qu'une clé de compte ne sait pas faire. À ranger via un
  credential helper (trousseau macOS), jamais dans un `.git-credentials` en clair.
- **Les remotes existants sont à repointer** vers `https://forgejo.wittner.tech/<org>/<repo>.git`.

⚠️ Ce qui n'a **pas** motivé la décision : le SSH fonctionnait. Il a été vérifié depuis le LAN,
depuis Internet et depuis un VPN d'entreprise. Ce qui a pesé, c'est le rapport entre ce qu'il
coûtait — un port ouvert, une IP publiée, deux noms, un routeur TCP, et une section entière de
pièges de diagnostic — et ce qu'il apportait, le seul gain réel étant le contournement du plafond
de 100 Mo, que le chemin LAN offre déjà.

### Pourquoi le web ne peut pas se passer du tunnel

**Le SSH ne pouvait pas passer par le proxy Cloudflare**, et c'est ce qui imposait le montage à
deux noms. L'edge est un reverse proxy **HTTP** : il termine TLS et parse du HTTP, sur une liste
fixe de ports (80, 8080, 8880, 2052, 2082, 2086, 2095 en clair ; 443, 2053, 2083, 2087, 2096, 8443
en TLS). Du SSH brut ne le traverse **à aucun port** — vérifié sur les huit : la connexion TCP est
acceptée, puis fermée dès la poignée de main. La contrainte n'est pas le port, c'est le protocole.

`cloudflared access ssh` levait la contrainte en encapsulant le SSH dans du HTTPS, au prix d'un
`ProxyCommand` et d'un `cloudflared` installé sur **chaque** poste. Écarté à l'époque, sans objet
aujourd'hui.

**Le tout-HTTPS était écarté pour le plafond de 100 Mo** — c'est désormais assumé, cf. ci-dessus.

⚠️ Un enregistrement de type **Tunnel ne fonctionne qu'en Proxied** : `<uuid>.cfargotunnel.com`
n'est pas résoluble publiquement, c'est un pseudo-nom interne à l'edge. Le passer en DNS-only ne
crée pas un chemin direct, il **tue** le nom. Cloudflare le signale par un ⚠️ dans la liste des
enregistrements. À savoir avant d'y toucher.

**Le tunnel gagne aussi là où on ne l'attend pas** : il sort en 443 vers une destination CDN bien
catégorisée. C'est ce qui fait passer la forge depuis des réseaux d'entreprise filtrants, où un
port non standard vers une IP résidentielle est bloqué. Observé sur un VPN GlobalProtect : le web
passait, le SSH non.

### Points de couplage hors dépôt

Silencieux quand ils cassent :

- L'ingress HTTP du tunnel a besoin d'`originRequest.originServerName: forgejo.wittner.tech` : le
  backend est une IP, donc sans lui aucun SNI n'est envoyé et le Gateway Cilium ne trouve aucun
  listener. Même cause que le `serversTransport` du routeur HTTP de Traefik, qui l'exige pour la
  même raison.
- ⚠️ **La redirection 443 de la box doit rester fermée.** Elle ne l'a jamais été et il n'y a plus
  aucune raison de l'ouvrir : c'est ce qui garantit que le WAF, le rate-limiting et l'absorption
  DDoS de l'edge ne sont pas contournables.


## Exposition publique

La forge est sur un hostname **public**. Cinq garde-fous se tiennent ensemble ; aucun ne remplace
les autres, et chacun a un mode de panne différent.

### Ce qui est fermé côté application (`gitea.config`)

| Réglage | Section | Effet |
| --- | --- | --- |
| `DISABLE_REGISTRATION: true` | `[service]` | personne ne crée de compte depuis l'extérieur |
| `INSTALL_LOCK: true` | `[security]` | `/install` ne réécrit plus la configuration (déjà forcé par le chart, explicité) |
| `GLOBAL_TWO_FACTOR_REQUIREMENT: all` | `[security]` | un second facteur est **exigé** de tout compte — cf. §2FA obligatoire |
| `ENABLE_OPENID_SIGNIN/SIGNUP: false` | `[openid]` | pas de seconde porte d'authentification |
| `DEFAULT_KEEP_EMAIL_PRIVATE: true` + `NO_REPLY_ADDRESS` | `[service]` | pas d'adresse mail dans les commits faits depuis l'UI |
| `SHOW_USER_EMAIL: false` | `[ui]` | pas d'adresse mail sur les profils |
| `DEFAULT_PRIVATE: private` + `DEFAULT_PUSH_CREATE_PRIVATE: true` | `[repository]` | un dépôt créé naît fermé, y compris par `git push` |
| `REQUIRE_SIGNIN_VIEW: false` | `[service]` | **volontairement `false`** : c'est ce qui laisse voir les dépôts publics |
| `ALLOW_LOCALNETWORKS: false` + `ALLOWED_DOMAINS` | `[migrations]` | anti-SSRF sur les imports |
| `ALLOWED_HOST_LIST: external` | `[webhook]` | anti-SSRF sur les webhooks, **jamais `*`** |
| `ENABLE_SWAGGER: false` | `[api]` | la surface d'API n'est pas documentée publiquement |
| `SHOW_FOOTER_VERSION: false` | `[other]` | la version n'est pas affichée |

> [!WARNING]
> `DEFAULT_KEEP_EMAIL_PRIVATE` ne vaut que pour les comptes créés **après** ce réglage. Un compte
> déjà existant garde le choix enregistré dans son profil : à vérifier à la main dans
> Paramètres → Compte.

`ALLOWED_DOMAINS` est une **liste blanche** : toute forge dont on veut importer un dépôt doit y
figurer, sinon la migration échoue sur `migrate from %s is not allowed` — un message qui ne
désigne pas ce réglage.

### 2FA obligatoire

`[security] GLOBAL_TWO_FACTOR_REQUIREMENT` accepte `none` (défaut), `admin` ou `all`. Ici : `all`.
L'instance n'a qu'un compte, les deux valeurs non nulles y sont donc équivalentes **aujourd'hui** —
`all` est retenu parce que `admin` laisserait passer un futur compte non-admin en mot de passe
seul, sans que rien ne le signale.

> [!IMPORTANT]
> Le réglage impose **un second facteur**, pas le TOTP en particulier : une clé WebAuthn / passkey
> le satisfait aussi bien qu'une application TOTP. Forgejo n'offre pas de moyen d'exiger le TOTP
> à l'exclusion du reste.

Ce n'est **pas** un verrou de connexion. Un compte sans second facteur s'authentifie toujours par
mot de passe, puis est redirigé vers `/user/settings/security` et n'atteint rien d'autre tant qu'il
n'a pas enrôlé. Activer le réglage sur l'instance en service **n'enferme donc pas dehors**.

En revanche, entre le sync et l'enrôlement, tout le reste est déjà refusé :

| Accès | Comportement sans second facteur |
| --- | --- |
| UI web | redirection forcée vers `/user/settings/security` |
| API (jetons personnels compris) | `403`, message `must_enable_2fa` |
| git en HTTP authentifié | `302` vers la page d'enrôlement — que `git` suit, et qui casse la commande |
| LFS, registre de paquets | refusés (`IsAccessAllowed`) |
| clone **anonyme** d'un dépôt public | **inchangé** — le contrôle est sous `IsSigned`, cohérent avec `REQUIRE_SIGNIN_VIEW: false` |
| comptes techniques d'Actions | **exclus** explicitement (`IsActions()`), un runner ne se bloque pas |

Donc : enrôler juste après le sync, pas le lendemain.

> [!CAUTION]
> **Perte du téléphone = perte de l'accès.** Deux filets, à poser *avant* d'en avoir besoin : les
> **codes de secours** affichés à l'enrôlement — à ranger avec le mot de passe admin — et le
> `reset-mfa` en `kubectl exec` (§Reste), qui suppose de garder un accès au cluster et pas
> seulement à la forge.

### Ce qui est fermé côté réseau (`forgejo-netpol.yaml`)

Une seule `CiliumNetworkPolicy` sélectionne le pod applicatif, dans les deux directions — donc
tout ce qui n'y figure pas est refusé.

- **Ingress** : deux règles, toutes deux sur le port 3000. La première ouvre aux entités
  `ingress` / `host` / `remote-node` (le proxy du Gateway et les sondes du kubelet) ; la seconde
  aux pods du namespace `renovate` — le bot [renovate](../renovate/README.md) joint l'API **et**
  clone en interne par le Service `forgejo-http`, sans repasser par l'edge. C'est le seul pod du
  cluster à atteindre l'UI. ⚠️ Retirer cette seconde règle ne dégrade pas le bot, elle le coupe,
  en timeout muet. La règle du port 2222, elle, est partie avec le clone SSH.
- **Egress** : DNS, la base CNPG, et `0.0.0.0/0` **moins** les plages privées. Le pod ne peut
  donc joindre ni l'API Kubernetes, ni un autre service du cluster, ni une machine du LAN — mais
  garde ce dont Forgejo a besoin : cloner un dépôt distant, livrer un webhook, joindre un relais
  SMTP externe.

Deux choses à savoir avant d'y toucher :

- **Il n'y a plus de `loadBalancerSourceRanges` à tenir.** Le filtrage par source du SSH vivait
  là et non dans la policy, parce qu'en `externalTrafficPolicy: Cluster` un paquet relayé d'un
  nœud à l'autre est SNATé et se présente en `remote-node`, pas en `world` — un filtre par CIDR
  côté policy aurait refusé du trafic légitime de façon intermittente. Le raisonnement est
  conservé ici : il redeviendrait valable au premier Service LoadBalancer du namespace.
- **Le mode d'échec est un timeout**, jamais une erreur lisible :
  ```bash
  kubectl -n forgejo delete ciliumnetworkpolicy forgejo   # rollback ; ArgoCD la repose au sync suivant
  cilium monitor --type drop -n forgejo                   # ce qui est effectivement jeté
  ```

### Ce que le pod n'a plus

`serviceAccount.create: true` + `automountServiceAccountToken: false`. Sans ces deux valeurs, le
chart ne pose **aucun** `serviceAccountName` et le pod retombe sur le ServiceAccount `default` du
namespace, dont le jeton est monté dans les conteneurs. Forgejo ne parle jamais à l'API
Kubernetes : ce jeton n'était qu'une primitive offerte à qui obtiendrait une exécution de code
dans le pod. Aucun RBAC n'accompagne le SA dédié — il n'a strictement aucun droit.

`containerSecurityContext` complète : `runAsNonRoot`, `runAsUser/Group: 1000`, `drop: [ALL]`,
`allowPrivilegeEscalation: false`, et `seccompProfile: RuntimeDefault` posé au niveau du pod pour
couvrir aussi les init-containers.

> [!CAUTION]
> Ce bloc ne tient **qu'avec l'image rootless** (`image.rootless: true`) — le chart amont le dit
> lui-même. Repasser en rootful sans le retirer casse le démarrage. `SYS_CHROOT` n'est pas ajouté
> parce que le cluster est en containerd ; il le faudrait sur des nœuds en CRI-O.

### En-têtes et robots

Les en-têtes de sécurité sont posés **par le Gateway** (filtre `ResponseHeaderModifier` de la
HTTPRoute) et non par Forgejo : HSTS n'a de sens qu'au point où TLS est terminé, le backend
parlant en clair dans le cluster. `set` et non `add`, pour remplacer les en-têtes que Forgejo émet
déjà plutôt que de les dupliquer. HSTS est posé **sans `preload`** : `max-age` seul reste
réversible, l'inscription à la liste de préchargement des navigateurs ne l'est pas.

Le `robots.txt` vient d'un ConfigMap monté sur `/data/gitea/robots.txt` : Forgejo n'a **aucune
clé d'`app.ini`** pour ce fichier, il ne sert que ce qu'il trouve dans son `CUSTOM_PATH`. Il ferme
les quatre familles d'URL coûteuses (`archive/`, `raw/`, `blame/`, `commits/`) et laisse les pages
d'accueil de dépôts indexables.

> [!IMPORTANT]
> Forgejo teste la présence du fichier **une seule fois, au démarrage** (`setting.HasRobotsTxt`).
> Éditer le ConfigMap ne suffit pas :
> ```bash
> kubectl -n forgejo rollout restart deploy/forgejo
> ```
> Le montage est en `extraContainerVolumeMounts` et **non** `extraVolumeMounts` : il ne doit pas
> arriver dans les init-containers, sinon kubelet créerait `/data/gitea` en root dans le PVC et
> `configure-gitea`, qui tourne en 1000, ne pourrait plus y écrire l'`app.ini`.

### Ce qui reste ouvert

- **Aucune limitation de débit.** Ni Forgejo ni l'implémentation Gateway API de Cilium n'en
  proposent : `/user/login` et les endpoints coûteux sont servis sans plafond. Le `robots.txt`
  ne s'adresse qu'aux robots qui le respectent.
- **La version minimale de TLS est celle du Gateway**, pas de ce composant
  (`infra/gateway-api/manifests/gateway.yaml`).
- **Le PVC `forgejo-data` n'est copié qu'à chaud, sans aucun gel, donc de façon ÉTALÉE** — pas
  même cohérente-crash (cf. §Sauvegarde). Un `git push` en cours au moment du parcours kopia peut
  être capturé à moitié : `refs` mises à jour, objets pas encore copiés. Contrairement à la base,
  il n'existe pas de chaîne native pour ce volume, et le chemin CSI snapshot qui supprimerait
  l'étalement n'est pas câblé — aucune `VolumeSnapshotClass` n'est déclarée.
  La détection est dans le `git fsck` de
  [`doc/forgejo-pra-exercice.md`](../../../doc/forgejo-pra-exercice.md).

## Métriques

`gitea.metrics.enabled` reste à `false`, et c'est un choix : l'endpoint `/metrics` est servi sur
le **port HTTP applicatif**, donc derrière le HTTPRoute public. Sans `[metrics] TOKEN`, il serait
lisible depuis Internet (noms de dépôts, volumétrie, nombre de comptes).

L'activer demande deux choses, pas une :

1. un token scellé (même canal que le compte admin), injecté dans l'`app.ini` par un
   `gitea.additionalConfigSources` pointant un Secret dont la clé `metrics` contient `TOKEN=…` ;
2. un `ServiceMonitor` écrit à la main dans `manifests/` — celui du chart ne sait pas porter
   d'`authorization`, et il lui faudrait de toute façon le label `release: kube-prometheus-stack`
   attendu par le sélecteur de [`kube-prometheus-stack`](../kube-prometheus-stack/README.md)
   (voir [`velero-monitoring`](../../infra/velero-monitoring/README.md) pour le gabarit).

## Opérations

### Câblage des secrets

Canal **sealed-secrets** (cf. [sealed-secrets](../../infra/sealed-secrets/README.md)). Un seul
template en clair, gitignoré (`*.secret.yaml`), porte les **trois** Secrets du composant en trois
documents YAML — `kubeseal` lit un flux multi-documents et les scelle tous dans un seul
`forgejo-admin.sealed.yaml`, d'où l'unique ligne du `kustomization.yaml` :

| Document | Secret | Statut |
| --- | --- | --- |
| 1 | `forgejo-admin` (`username` / `password`) | **requis au démarrage** — sans lui, `CreateContainerConfigError` |
| 2 | `forgejo-secrets` (4 secrets cryptographiques) | optionnel — cf. §Sceller les secrets cryptographiques |
| 3 | `forgejo-smtp` (`PASSWD`) | optionnel — cf. §Mailer |

Seul le document 1 est nécessaire **avant la première synchronisation** : les documents 2 et 3
sont câblés en `optional: true` dans `helm-values.yaml` et leur absence ne bloque pas le
démarrage. ⚠️ Pour le document 3 ce n'est plus anodin depuis l'activation du mailer : sans lui le
pod démarre, mais **tous** les envois sont refusés par le relais (§Mailer).

Le template en clair est gitignoré **et** supprimé après scellement, et un `SealedSecret` ne
conserve que du chiffré : les commentaires qui expliquent chaque valeur ne survivraient nulle
part. Ils sont donc versionnés à part, sans aucune valeur réelle, dans
[`manifests/forgejo-admin.secret.example.yaml`](manifests/forgejo-admin.secret.example.yaml). Le
point de départ est toujours une copie de ce fichier :

```sh
cp cluster/app/forgejo/manifests/forgejo-admin.secret.example.yaml \
   cluster/app/forgejo/manifests/forgejo-admin.secret.yaml
```

> [!WARNING]
> Le nom de la copie est ce qui la protège : `*.secret.yaml` est le motif du `.gitignore`. Un
> fichier nommé autrement serait suivi par Git **en clair**. Et ne jamais renseigner le
> `.example.yaml` lui-même — son nom, précisément, ne correspond pas au motif.

> [!CAUTION]
> **Ne pas sceller ce fichier tant que le document 2 contient des `REMPLACER`.** Ces quatre
> valeurs chiffrent des données déjà en base : les sceller telles quelles rendrait illisibles
> toutes les sessions, tous les jetons d'API, LFS et OAuth2 existants. Soit on renseigne le
> document 2 d'abord (§Sceller les secrets cryptographiques), soit on le retire temporairement du
> fichier avant de sceller.

```bash
# 1. Remplir la valeur REMPLACER du document 1 (`password`) :
openssl rand -base64 24
#    `username` reste `forgejo_admin` — et surtout PAS `admin`, nom réservé par Forgejo.

# 2. Sceller (les trois documents d'un coup)
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/forgejo/manifests/forgejo-admin.secret.yaml \
  > cluster/app/forgejo/manifests/forgejo-admin.sealed.yaml

# 3. Jeter le clair, puis committer le scellé. La ligne est DÉJÀ décommentée dans
#    kustomization.yaml — il n'y a plus rien à y faire.
rm cluster/app/forgejo/manifests/forgejo-admin.secret.yaml
```

> [!WARNING]
> **Le fichier scellé remplace l'ancien.** Un `SealedSecret` ne se relit pas : re-sceller pour
> ajouter un document oblige à re-fournir *aussi* les valeurs des documents déjà scellés. D'où
> l'intérêt de tout renseigner en une fois — ou de garder ces valeurs dans un gestionnaire de
> mots de passe.

> [!NOTE]
> Le mot de passe n'est lisible nulle part après scellement — le clair est détruit et le
> `SealedSecret` n'est déchiffrable que par le contrôleur. Le garder de côté (gestionnaire de
> mots de passe) au moment de l'étape 1, ou le relire depuis le cluster une fois déployé :
> `kubectl -n forgejo get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d`.
> C'est la différence de fond avec un coffre à secrets : ici Git porte le chiffré, et rien ne
> permet de le relire côté repo.

### Sceller les secrets cryptographiques

Les quatre secrets (`[security] SECRET_KEY`, `[security] INTERNAL_TOKEN`, `[oauth2] JWT_SECRET`,
`[server] LFS_JWT_SECRET`) sont générés par le chart au premier démarrage et n'existent **que**
dans `/data/gitea/conf/app.ini`, sur le PVC (cf. Contraintes). Les sceller les met dans Git sous
forme chiffrée et rend le volume restaurable indépendamment.

Le câblage est **déjà posé** dans `helm-values.yaml`
(`additionalConfigFromEnvs`, `optional: true`) : tant que le Secret `forgejo-secrets` n'existe
pas, les variables ne sont pas posées et Forgejo garde les valeurs de son `app.ini`. Il n'y a donc
**rien à décommenter nulle part** — le document 2 du template partage le scellement du compte
admin (§Câblage des secrets), et `forgejo-admin.sealed.yaml` est déjà dans le `kustomization.yaml`.

> [!CAUTION]
> **Ne pas générer de valeurs neuves sur une instance déjà en service.** Ces quatre valeurs
> chiffrent ou signent des données **déjà en base** : sessions, jetons d'API, jetons LFS, jetons
> OAuth2. Les remplacer ne fait pas « repartir de zéro », cela rend illisible ce qui existe. Il
> faut sceller celles que le pod utilise en ce moment.

```bash
# 1. Extraire les valeurs VIVES
kubectl -n forgejo exec deploy/forgejo -- \
  sh -c 'grep -E "^(SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET|LFS_JWT_SECRET) " /data/gitea/conf/app.ini'

# 2. Les recopier dans le DOCUMENT 2 du template (gitignoré), en respectant la correspondance :
#      [security] SECRET_KEY      -> SECRET_KEY
#      [security] INTERNAL_TOKEN  -> INTERNAL_TOKEN
#      [oauth2]   JWT_SECRET      -> OAUTH2_JWT_SECRET
#      [server]   LFS_JWT_SECRET  -> LFS_JWT_SECRET
#    ⚠️ Le document 1 (mot de passe admin) doit être renseigné DANS LE MÊME PASSAGE : le
#    scellement porte sur le fichier entier et écrase forgejo-admin.sealed.yaml.

# 3. Sceller et jeter le clair — même commande qu'au §Câblage des secrets
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/forgejo/manifests/forgejo-admin.secret.yaml \
  > cluster/app/forgejo/manifests/forgejo-admin.sealed.yaml
rm cluster/app/forgejo/manifests/forgejo-admin.secret.yaml
```

> [!WARNING]
> Deux clés portent le **même nom** dans deux sections différentes de l'`app.ini` : `JWT_SECRET`
> est celle d'`[oauth2]`, `LFS_JWT_SECRET` celle de `[server]`. Les intervertir casse LFS et
> OAuth2 en même temps, et le seul signal est un jeton refusé à l'usage.

Vérification, une fois scellé et le pod redémarré : les sessions ouvertes et les jetons d'API
existants doivent **survivre**. C'est la preuve que les valeurs injectées sont bien celles qui
étaient déjà en place.

### Câblage du credential GCS

Canal **sealed-secrets**, mais **fichier scellé distinct** de `forgejo-admin.sealed.yaml`. Un
`SealedSecret` ne se relit pas : mélanger les deux obligerait, à chaque rotation de la clé GCP, à
re-fournir *aussi* le mot de passe admin et les quatre secrets cryptographiques — c'est-à-dire à
courir le risque décrit en capitales dans `forgejo-admin.secret.example.yaml`. Deux cycles de vie
différents, deux fichiers.

> [!IMPORTANT]
> **Le bucket et le compte de service ne sont pas déclarés ici : ils vivent dans le repo
> Terraform**, comme ceux de velero et d'openbao. Le contrat attendu :
> - un bucket **dédié** (distinct de `homelab-velero-backups-*` et du bucket de snapshots openbao —
>   les trois chaînes font chacune leur propre GC, et une lifecycle rule posée pour l'une casse les
>   restaurations des autres) ;
> - un compte de service lié à `roles/storage.objectAdmin` **sur ce bucket**.
>
> Rien côté `cluster/` ne vérifie ce contrat. La seule preuve que les deux repos s'accordent est
> une première sauvegarde qui aboutit.

```bash
# 1. Reporter le nom du bucket produit par Terraform dans l'ObjectStore (`destinationPath`)
$EDITOR cluster/app/forgejo/manifests/forgejo-db-objectstore.yaml
#    Déjà renseigné : gs://homelab-cnpg-backups-8b8ff253/forgejo/

# 2. Émettre une clé pour le compte de service — le seul geste manuel, une clé JSON ne se sort pas
#    d'un état Terraform sans l'y stocker en clair
gcloud iam service-accounts keys create ./cnpg-sa.json \
  --iam-account=<compte-de-service-cnpg>@homelab-499008.iam.gserviceaccount.com

# 3. Recopier le template versionné et y coller le JSON ENTIER, tel que téléchargé
cp cluster/app/forgejo/manifests/forgejo-db-gcs.secret.example.yaml \
   cluster/app/forgejo/manifests/forgejo-db-gcs.secret.yaml
$EDITOR cluster/app/forgejo/manifests/forgejo-db-gcs.secret.yaml

# 4. Sceller — le chiffré est lié au couple (forgejo-db-gcs, forgejo)
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < cluster/app/forgejo/manifests/forgejo-db-gcs.secret.yaml \
  > cluster/app/forgejo/manifests/forgejo-db-gcs.sealed.yaml

# 5. Committer le scellé, pousser. La ligne `forgejo-db-gcs.sealed.yaml` est DÉJÀ active dans
#    manifests/kustomization.yaml (elle a été décommentée lors du premier scellement).

# 6. Forcer ArgoCD à relire le dépôt sans attendre son cycle de polling (3 min par défaut).
#    `refresh=hard` et non `normal` : il invalide le CACHE DE MANIFESTES du repo-server. Ici le
#    changement porte sur le `kustomization.yaml` — une ligne décommentée qui ajoute une
#    ressource — et c'est exactement le cas où un refresh `normal` peut resservir le rendu
#    précédent. `--overwrite` est requis : l'annotation est consommée puis reposée à chaque
#    déclenchement.
kubectl -n argocd annotate app forgejo argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get app forgejo              # SYNC STATUS doit repasser Synced

# 7. Une fois l'archivage vérifié (ci-dessous), détruire les deux seules copies en clair
rm cluster/app/forgejo/manifests/forgejo-db-gcs.secret.yaml ./cnpg-sa.json
```

**Vérifier que la chaîne est vivante** — dans cet ordre, chaque étape conditionne la suivante :

```bash
# a. Le sidecar barman-cloud est bien injecté. ⚠️ Il est déclaré en INIT-CONTAINER (sidecar natif
#    Kubernetes, `restartPolicy: Always`) et non en conteneur ordinaire : le chercher dans
#    `.spec.containers` renvoie `postgres` seul et donne l'impression qu'il manque.
kubectl -n forgejo get pod forgejo-db-1 \
  -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}'   # attendu : plugin-barman-cloud
kubectl -n forgejo get cluster forgejo-db -o jsonpath='{.status.pluginStatus}' | jq

# b. L'archivage WAL ne prend pas de retard : `ready` doit rester à 0 et `archiver_failed_count`
#    ne pas monter. Un `ready` à 1 avec `failed_count` qui grimpe = destination ou credential
#    invalides — PostgreSQL retente indéfiniment, rien n'est perdu, mais rien n'arrive non plus.
kubectl get --raw "/api/v1/namespaces/forgejo/pods/forgejo-db-1:9187/proxy/metrics" \
  | grep -E "archive_status|archiver_failed|^barman_cloud"
kubectl -n forgejo logs forgejo-db-1 -c plugin-barman-cloud --tail=20

# c. Déclencher la première sauvegarde de base à la main — la ScheduledBackup n'a pas
#    `immediate: true` (cf. le commentaire du fichier), elle attendra 02:00 sinon
kubectl -n forgejo create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  generateName: forgejo-db-manual-
  namespace: forgejo
spec:
  cluster:
    name: forgejo-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

# d. ⚠️ NOM LONG obligatoire : `kubectl get backups` répond pour CNPG *ou* velero selon le
#    contexte, et la réponse « No resources found » ressemble à « rien n'a tourné »
kubectl -n forgejo get backups.postgresql.cnpg.io
```

Un `Backup` en `failed` juste après l'installation = credential absent, mal collé (JSON tronqué),
ou droits IAM insuffisants sur le bucket. Le symptôme côté base n'est pas un pod en erreur mais
`cnpg_pg_stat_archiver_failed_count` qui monte — ce que
[`CNPGWalArchivingFailing`](../cnpg-monitoring/README.md) attrape.

### Mailer

Configuré sur **Brevo** (`smtp-relay.brevo.com:587`, STARTTLS), bloc `mailer:` de `gitea.config`
dans `helm-values.yaml`. Sans mailer, Forgejo n'enverrait **ni** réinitialisation de mot de passe
**ni** notification de connexion, et la perte du mot de passe admin ne se réparerait que par
`kubectl exec` — donc en gardant un accès au cluster, pas seulement à la forge.

Le mot de passe (clé SMTP Brevo) n'est **pas** dans `helm-values.yaml` : il arrive par
`FORGEJO__MAILER__PASSWD`, depuis le **document 3** de `manifests/forgejo-admin.secret.yaml`
(Secret `forgejo-smtp`, clé `PASSWD`) — à remplir et re-sceller, cf. §Câblage des secrets. Rien à
décommenter dans le `kustomization.yaml` : `forgejo-admin.sealed.yaml` porte les trois Secrets.

⚠️ `optional: true` sur cette variable veut dire que le pod démarre **même sans** le Secret : le
mailer est alors actif sans mot de passe et le relais refuse l'authentification. L'absence de
scellement ne se voit pas au démarrage, seulement au premier envoi.

**Diagnostiquer un échec d'envoi** (bouton *Envoyer un email de test*, panneau d'admin) :

| Message | Cause |
|---|---|
| `lookup … : no such host` | Nom de relais faux. Une réponse DNS **négative** prouve que CoreDNS a été joint : ce n'est **pas** la NetworkPolicy. Brevo, c'est `smtp-relay.brevo.com` — `relay.brevo.com` n'existe pas. |
| `i/o timeout` / `connection timed out` | Là, c'est le réseau. La `CiliumNetworkPolicy` n'ouvre la sortie que vers des adresses **publiques** : un relais sur le LAN demande une règle `toCIDR` explicite dans `manifests/forgejo-netpol.yaml`. |
| Authentification refusée | Secret `forgejo-smtp` non scellé, ou `USER` renseigné avec l'adresse d'expédition au lieu de l'identifiant Brevo (`<id>@smtp-brevo.com`) — les deux diffèrent. |

**Alertmanager partage ce relais et ce credential** depuis le 2026-09-09
(cf. [`kube-prometheus-stack`](../kube-prometheus-stack/README.md) § Notification mail) : même
login Brevo, même clé, scellée une seconde fois dans `monitoring` — sealed-secrets chiffrant pour
le couple (nom, namespace), la valeur ne peut pas être mutualisée en un seul objet.

⚠️ **Conséquence sur la rotation** : changer la clé SMTP chez Brevo casse les **deux** envois, et
il faut resceller les deux fichiers (celui d'ici et
`cluster/app/kube-prometheus-stack/manifests/alertmanager-smtp.secret.example.yaml`). Un seul des
deux rescellé donne une forge qui envoie et un alerting muet — ou l'inverse, qui est pire.

### Reste

- **Première connexion** : `https://forgejo.wittner.tech`, utilisateur `forgejo_admin`. Il n'y a
  pas d'écran d'installation — le chart force `security.INSTALL_LOCK = true`.

- **Rotation du mot de passe admin** : rejouer §Câblage des secrets (le clair a été détruit, il
  faut donc réécrire un template), committer le nouveau `.sealed.yaml`, puis
  `kubectl -n forgejo rollout restart deploy/forgejo`. En `passwordMode: keepUpdated`,
  l'init-container `configure-gitea` réaligne le compte sur la valeur du Secret à chaque
  démarrage — c'est le redémarrage qui applique la rotation, pas le commit.

- **Vérifier la copie kopia du PVC** — depuis l'exclusion des volumes CNPG, la sauvegarde velero du
  namespace `forgejo` doit contenir **exactement un** `podvolumebackup` : celui de `forgejo-data`.
  Deux signifierait que la règle `pvcLabels` ne matche plus ; zéro, que node-agent est absent et
  que la sauvegarde est verte et vide.
  ```bash
  kubectl -n velero get podvolumebackups -l velero.io/backup-name=<backup>
  ```

- **Agrandir le volume sans le détruire** — le PVC est modifié **en place** : ni suppression, ni
  recréation, ni démontage, ni redémarrage du pod.

  Le chemin complet : bumper `persistence.size` → ArgoCD **patche** le PVC (`ServerSideApply`,
  jamais un delete/create) → `spec.resources.requests.storage` est l'un des rares champs mutables
  d'un PVC, l'API accepte l'augmentation → l'`external-resizer` déclenche
  `ControllerExpandVolume` → lvm-localpv fait un `lvextend -r`, qui étend le LV **et** le système
  de fichiers en ligne.

  ```bash
  # 1. Place restante dans le VG du nœud (LVM THICK : la réserve est immédiate)
  kubectl -n openebs exec ds/lvmvg-bootstrap -- vgs lvmvg

  # 2. Bumper `persistence.size` dans helm-values.yaml, committer, pousser. Rien d'impératif.

  # 3. Suivre
  kubectl -n forgejo get pvc forgejo-data -w          # CAPACITY suit la nouvelle valeur
  kubectl -n forgejo exec deploy/forgejo -- df -h /data
  ```

  Trois choses à savoir pendant l'opération :

  - **Le message `FileSystemResizePending` est trompeur.** Kubernetes affiche « Waiting for user to
    (re-)start a pod to finish file system resize » — c'est un texte générique. Avec lvm-localpv,
    l'agent du nœud fait le `resize2fs` tout seul ; la condition disparaît sans qu'on touche au
    pod. Ne PAS redémarrer Forgejo en réaction à ce message.
  - **Le pod doit référencer le volume pour que le système de fichiers grandisse.** Si le
    Deployment est à 0 replica, le LV est étendu mais le `df` reste à l'ancienne taille jusqu'à ce
    qu'un pod remonte le volume.
  - **Un champ immuable ferait échouer la sync, pas une recréation.** Si un bump de chart changeait
    autre chose que la taille dans le PVC rendu, l'apply serait rejeté (`spec is immutable after
    creation except resources.requests…`) et l'Application passerait en `SyncFailed`. ArgoCD ne
    recrée un objet que si on le lui demande explicitement (`Replace=true`), ce qui n'est le cas
    nulle part dans ce dépôt — et le PVC porte en plus `Prune=false,Delete=false`.

  > [!CAUTION]
  > **Sens unique.** Kubernetes refuse toute diminution de `spec.resources.requests.storage` : un
  > `persistence.size` revu à la baisse fait échouer la sync sur `field can not be less than
  > previous value`, et le seul retour en arrière est une recréation du PVC — donc une
  > sauvegarde/restauration complète des dépôts, paquets et de l'`app.ini`. Agrandir par paliers
  > coûte moins cher que viser trop large d'un coup.

- **Créer un compte** (l'inscription libre est coupée) : depuis l'UI d'admin, ou
  ```bash
  kubectl -n forgejo exec deploy/forgejo -- forgejo admin user create \
    --username <nom> --email <mail> --random-password
  ```
  ⚠️ Le compte créé devra enrôler un second facteur à sa première connexion (§2FA obligatoire) :
  tant qu'il ne l'a pas fait, il ne peut ni cloner ni utiliser l'API.

- **Second facteur perdu** — seul recours une fois les codes de secours épuisés ou perdus. Retire
  **toutes** les configurations 2FA du compte (TOTP *et* clés WebAuthn), qui redevient alors
  joignable par mot de passe seul et repart sur la redirection d'enrôlement :
  ```bash
  kubectl -n forgejo exec deploy/forgejo -- forgejo admin user reset-mfa --username forgejo_admin
  ```
  ⚠️ C'est aussi le contournement complet du 2FA pour qui a `exec` sur le namespace. Le second
  facteur protège la forge exposée sur Internet, pas contre un accès au cluster — ce sont deux
  périmètres distincts, et l'accès au cluster reste le plus privilégié des deux.

- **État de la base et placement** (read-only) — la colonne `NODE` doit être **identique** pour
  le pod Forgejo et le pod `forgejo-db-1` (cf. §Placement) :
  ```bash
  kubectl -n forgejo get cluster
  kubectl -n forgejo get pods -o wide
  kubectl -n forgejo get pvc
  ```
  Un pod `forgejo-db-1` en `Pending` durable se diagnostique par ses events — `didn't match pod
  affinity rules` désigne la règle de co-localisation, pas un manque de ressources :
  ```bash
  kubectl -n forgejo describe pod -l cnpg.io/cluster=forgejo-db | tail -20
  ```

- **Logs** : `kubectl -n forgejo logs deploy/forgejo`. Toute la configuration se joue dans les
  trois init-containers, à regarder dans cet ordre — c'est là que remontent un `app.ini`
  incohérent, une base injoignable ou un secret admin absent :
  ```bash
  kubectl -n forgejo logs deploy/forgejo -c init-directories   # arborescence /data
  kubectl -n forgejo logs deploy/forgejo -c init-app-ini       # génération de l'app.ini
  kubectl -n forgejo logs deploy/forgejo -c configure-gitea    # migrate + compte admin
  ```

- **Vérifier l'exposition** — un seul chemin à remonter depuis le 2026-09-06, mais **trois
  contextes de test qui ne prouvent rien l'un de l'autre** : le LAN (DNS interne, court-circuite
  l'edge), Internet, et **un VPN actif** (résolveur et routes qui lui sont propres).
  ```bash
  kubectl -n forgejo get httproute forgejo -o yaml   # Accepted + ResolvedRefs sur shared-gw
  curl -sI https://forgejo.wittner.tech | head -1    # 200, depuis chaque contexte
  dig +short forgejo.wittner.tech @1.1.1.1           # une IP Cloudflare = tunnel proxifié, normal
  ```
  ⚠️ Le Service `forgejo-ssh` apparaît toujours dans `get svc`, en `ClusterIP` et sans endpoint :
  c'est l'état attendu, le chart le rend sans condition (cf. Contraintes).

  Les deux faux négatifs classiques sont tous les deux en DNS, et se ressemblent :

  - **Le test depuis le LAN réussit et l'externe échoue** : le DNS interne pointe `192.168.1.50`
    en direct, donc le test local ne traverse ni la box, ni l'edge, ni le DNS public.
  - **Un VPN actif impose son propre résolveur**, prioritaire sur celui du LAN, et peut servir une
    réponse en cache antérieure à un changement DNS — avec un TTL que `dscacheutil` ne touche pas,
    puisque le cache est distant. Le symptôme est un timeout muet, **indiscernable** d'un
    filtrage de politique d'entreprise ou d'un port fermé.

  > [!IMPORTANT]
  > La résolution réellement servie n'est **pas récupérable après coup**. Quand le symptôme est
  > là, la capturer avant toute autre chose — sinon le diagnostic repart de zéro.

  ```bash
  scutil --dns | grep -B3 -A3 wittner                    # un résolveur dédié à la zone = split-DNS
  dscacheutil -q host -a name forgejo.wittner.tech       # ce que voit vraiment macOS
  dig +short forgejo.wittner.tech @1.1.1.1               # ce que voit Internet
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
  ```

  `dig` court-circuite `mDNSResponder` : il peut répondre autre chose que ce que le client utilise
  réellement. C'est `dscacheutil` qui fait foi sur macOS.


- **Upgrade** : bumper `targetRevision` dans `forgejo.app.yaml`. Le versionnage du chart ne suit
  **pas** celui de Forgejo (chart 17.x ⇒ Forgejo 15.x) ; lire la section `Upgrading` du README
  amont avant tout bump majeur.

## Non retenu

- **SSO OIDC via authentik** — le chart sait déclarer une source OAuth2
  (`gitea.oauth[]`, appliquée par `forgejo admin auth add-oauth`), mais
  [`authentik`](../authentik/README.md) n'est pas déployé aujourd'hui (son Application est en
  `.noapp.yaml`, et le bloc `oidc.config` d'ArgoCD est commenté pour la même raison). À rouvrir
  avec lui, pas avant.
- **Forgejo Actions** — le moteur est actif côté serveur, mais aucun `forgejo-runner` n'est
  déployé : sans runner enregistré, les workflows restent en attente. C'est un composant séparé,
  pas un réglage de celui-ci.
- **Cache / session externes** — Forgejo retombe sur les adaptateurs `memory` (session, cache) et
  `level` (queue), ce que le chart amont déconseille pour de la production. Le compromis est tenu
  ici par le mono-pod et la limite mémoire à 2Gi ; il ne tient plus dès qu'on vise plusieurs
  replicas, qui demanderaient de toute façon un stockage RWX que le cluster n'a pas.
