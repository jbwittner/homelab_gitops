# forgejo

## Rôle

Forge Git auto-hébergée (dépôts, issues, PR, registre de paquets, Actions). Base de données
PostgreSQL dédiée, portée par un `Cluster` CNPG (opérateur fourni par
[`cnpg`](../cnpg/README.md)).

Deux chemins d'accès, volontairement dissociés :

- **Web / clone HTTPS** — `https://forgejo.wittner.tech`, via `shared-gw`, listener
  `https-public` (cf. [doc/reseau.md](../../../doc/reseau.md)).
- **Clone SSH** — `git@forgejo.lan.wittner.tech:<org>/<repo>.git`, via un Service LoadBalancer
  sur `192.168.1.85`, hors Gateway.

## Fichiers

- `forgejo.app.yaml` — Application (archétype (b) : chart + `$values` + `manifests/`).
  Le chart n'existe **qu'en OCI** : `repoURL` est écrit sans le préfixe `oci://`, seule forme
  qu'ArgoCD accepte (et que Renovate suit, via la datasource `docker`).
- `helm-values.yaml` — base externe CNPG, exposition déléguée aux manifestes, SSH en
  LoadBalancer, PVC protégé du prune, admin par `existingSecret`
- `manifests/namespace.yaml` — ns `forgejo` (wave -1)
- `manifests/forgejo-db.yaml` — `Cluster` CNPG (l'opérateur génère le service `forgejo-db-rw`
  et le secret `forgejo-db-app`), **co-localisé avec le pod Forgejo** par
  `affinity.additionalPodAffinity` — cf. §Placement
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
  applicatif — cf. §Exposition publique
- `manifests/forgejo-robots.yaml` — ConfigMap du `robots.txt`, monté sur `/data/gitea/robots.txt`
  par `extraVolumes` / `extraContainerVolumeMounts` — cf. §Exposition publique
- `manifests/kustomization.yaml` — assemblage. La ligne `forgejo-admin.sealed.yaml` y est
  **commentée** tant que le scellement n'a pas eu lieu : un `resources:` pointant un fichier
  absent fait échouer le `kustomize build` entier, donc l'Application

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

- **`forgejo` n'est PAS dans le périmètre de sauvegarde velero.** La liste
  `includedNamespaces` de la schedule quotidienne est une **liste blanche** et ne contient
  aujourd'hui que `test-nginx` (cf. [`velero`](../../infra/velero/README.md)). Tant que
  `forgejo` n'y est pas ajouté, ni le PVC ni la base ne sont sauvegardés, et **rien ne le
  signale**. C'est la décision à prendre en premier après la mise en service — voir Opérations.
- Le mot de passe de la base n'est **pas** géré ici : il vient du secret auto-généré par CNPG
  (`forgejo-db-app`). Ne pas le sceller, ne pas le figer. Le **seul** secret scellé du composant
  est le compte d'administration.
- **Le `SealedSecret` est chiffré pour le couple (`forgejo-admin`, `forgejo`)** : le renommer ou
  le déplacer de namespace exige de le resceller. Il l'est aussi pour la clé du contrôleur du
  cluster — un `sealed-secrets` réinstallé à neuf ne sait plus le déchiffrer, et le seul signal
  est le pod qui reste en `CreateContainerConfigError`.
- Le composant `cnpg` doit tourner avant : sans la CRD `Cluster`, le manifeste DB échoue.
- **L'IP `192.168.1.85` est un contrat DNS**, pas un détail d'implémentation : elle est fixée par
  l'annotation `lbipam.cilium.io/ips` parce qu'un enregistrement `forgejo.lan.wittner.tech` la
  vise. La laisser à l'allocateur casserait tous les remotes `git@…` au premier recréage du
  Service, sans erreur visible côté cluster.
- **`gitea.config.server.PROTOCOL: http` avec `ROOT_URL: https://…` est voulu** : TLS est terminé
  au Gateway. Aligner `PROTOCOL` sur `https` ferait attendre à Forgejo un certificat qu'il n'a
  pas.
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

Deux hostnames pour un seul service, parce que le trafic n'arrive pas au même endroit :

| Nom | Cible | Chemin |
| --- | --- | --- |
| `forgejo.wittner.tech` | IP de `shared-gw` | HTTPRoute, listener `https-public`, TLS terminé au Gateway |
| `forgejo.lan.wittner.tech` | `192.168.1.85` | Service LoadBalancer `forgejo-ssh`, annonce L2 Cilium, port 22 → 2222 |

Le second est en `.lan` : il est annoncé en ARP sur le LAN et n'a aucun sens depuis Internet.
Le certificat wildcard `*.lan.wittner.tech` ne le concerne pas — SSH ne fait pas de TLS.

Le port 22 du Service pointe sur le port 2222 du conteneur : l'image rootless ne peut pas se
lier à un port privilégié. `SSH_PORT` (annoncé dans les URLs de clone) et `SSH_LISTEN_PORT`
(réellement écouté) sont donc deux réglages distincts, tous deux explicites dans
`helm-values.yaml`.

## Exposition publique

La forge est sur un hostname **public**. Cinq garde-fous se tiennent ensemble ; aucun ne remplace
les autres, et chacun a un mode de panne différent.

### Ce qui est fermé côté application (`gitea.config`)

| Réglage | Section | Effet |
| --- | --- | --- |
| `DISABLE_REGISTRATION: true` | `[service]` | personne ne crée de compte depuis l'extérieur |
| `INSTALL_LOCK: true` | `[security]` | `/install` ne réécrit plus la configuration (déjà forcé par le chart, explicité) |
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

### Ce qui est fermé côté réseau (`forgejo-netpol.yaml`)

Une seule `CiliumNetworkPolicy` sélectionne le pod applicatif, dans les deux directions — donc
tout ce qui n'y figure pas est refusé.

- **Ingress** : port 3000 depuis les entités `ingress` / `host` / `remote-node` seulement (le
  proxy du Gateway et les sondes du kubelet), port 2222 pour le SSH.
- **Egress** : DNS, la base CNPG, et `0.0.0.0/0` **moins** les plages privées. Le pod ne peut
  donc joindre ni l'API Kubernetes, ni un autre service du cluster, ni une machine du LAN — mais
  garde ce dont Forgejo a besoin : cloner un dépôt distant, livrer un webhook, joindre un relais
  SMTP externe.

Deux choses à savoir avant d'y toucher :

- **La restriction du SSH au LAN n'est pas dans la policy** mais dans
  `service.ssh.loadBalancerSourceRanges` (`192.168.1.0/24`), appliqué en eBPF sur le nœud
  d'entrée **avant** le DNAT. En `externalTrafficPolicy: Cluster`, un paquet relayé d'un nœud à
  l'autre est SNATé et se présente à la policy en `remote-node`, pas en `world` : un filtre par
  CIDR côté policy refuserait du trafic légitime, de façon intermittente.
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
- **`forgejo` n'est toujours pas sauvegardé** (cf. Contraintes).

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
sont câblés en `optional: true` dans `helm-values.yaml` et leur absence est un non-événement.

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

# 3. Jeter le clair, décommenter forgejo-admin.sealed.yaml dans kustomization.yaml, committer
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

### Mailer

Non configuré, et c'est un manque : sans mailer, Forgejo n'envoie **ni** réinitialisation de mot
de passe **ni** notification de connexion. Sur une instance publique à compte unique, la perte du
mot de passe admin ne se répare alors que par `kubectl exec` — donc en gardant un accès au
cluster, pas seulement à la forge.

Le blocage n'est pas technique : aucun relais n'est choisi. Celui d'Alertmanager est encore un
`REMPLACER` (cf. [`kube-prometheus-stack`](../kube-prometheus-stack/helm-values.yaml)). Les deux
composants peuvent partager le même relais, avec des identifiants distincts.

Trois gestes, dans cet ordre :

1. Remplir le **document 3** de `manifests/forgejo-admin.secret.yaml` (clé `PASSWD`) et re-sceller
   le fichier (§Câblage des secrets). Rien à décommenter dans le `kustomization.yaml` : la
   variable `FORGEJO__MAILER__PASSWD` est **déjà** câblée en `optional: true`.
2. Décommenter le bloc `mailer:` de `gitea.config` dans `helm-values.yaml` et y écrire
   `SMTP_ADDR`, `SMTP_PORT`, `FROM`, `USER`. Le mot de passe n'y va **pas** — ce fichier est dans
   Git.
3. Vérifier que le relais est **public** : la `CiliumNetworkPolicy` n'ouvre la sortie que vers des
   adresses non privées. Un relais sur le LAN demanderait une règle `toCIDR` explicite dans
   `manifests/forgejo-netpol.yaml`.

Activer `ENABLED: true` avec un `SMTP_ADDR` faux fait échouer chaque envoi **en silence**, dans
les logs seulement — d'où le bloc laissé commenté plutôt qu'à moitié rempli.

### Reste

- **Première connexion** : `https://forgejo.wittner.tech`, utilisateur `forgejo_admin`. Il n'y a
  pas d'écran d'installation — le chart force `security.INSTALL_LOCK = true`.

- **Rotation du mot de passe admin** : rejouer §Câblage des secrets (le clair a été détruit, il
  faut donc réécrire un template), committer le nouveau `.sealed.yaml`, puis
  `kubectl -n forgejo rollout restart deploy/forgejo`. En `passwordMode: keepUpdated`,
  l'init-container `configure-gitea` réaligne le compte sur la valeur du Secret à chaque
  démarrage — c'est le redémarrage qui applique la rotation, pas le commit.

- **Mettre la forge sous sauvegarde** (à décider explicitement, cf. Contraintes) : ajouter
  `forgejo` à `schedules.daily.template.includedNamespaces` dans
  [`velero/helm-values.yaml`](../../infra/velero/helm-values.yaml), puis vérifier au backup
  suivant la présence des `podvolumebackups` attendus — un pour `forgejo-data`, un pour le PVC
  du pod CNPG :
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

- **Vérifier l'exposition SSH** :
  ```bash
  kubectl -n forgejo get svc forgejo-ssh          # EXTERNAL-IP doit valoir 192.168.1.85
  ssh -T -p 22 git@forgejo.lan.wittner.tech       # doit répondre par un message Forgejo
  ```

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
