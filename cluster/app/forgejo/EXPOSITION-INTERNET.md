# Exposition de Forgejo sur Internet — état de la checklist

Audit du seul périmètre autorisé : `cluster/app/forgejo/`. Aucun logiciel n'a été ajouté, aucune
ressource n'a été créée hors de ce dossier.

> [!NOTE]
> **Modèle d'accès, depuis le 2026-09-06 : full HTTPS, SSH désactivé.** Le seul chemin Git est
> `https://forgejo.wittner.tech` avec un jeton d'accès personnel — depuis Internet par le tunnel
> Cloudflare, depuis le LAN par le DNS interne qui sert `192.168.1.50`. Côté application
> `DISABLE_SSH: true` et côté processus `START_SSH_SERVER: false` (`helm-values.yaml`,
> `gitea.config.server`) : les URLs de clone SSH ont disparu de l'UI et le serveur SSH interne ne
> démarre plus. Ont été retirés avec lui : la redirection **2222** de la box — seul port entrant de
> l'installation —, l'enregistrement A **`git-ssh.wittner.tech`** qui publiait l'IP d'origine, le
> routeur TCP Traefik et son entrypoint `ssh`, et la réservation de `192.168.1.81` sur le pool
> LB-IPAM. Ce qui reste : **aucun port ouvert**, tout entre par une connexion *sortante*.
> Contrepartie assumée : Cloudflare devient une dépendance dure pour tout accès externe, Git
> compris, et un `git push` de plus de 100 Mo passe par le LAN.

**Comment lire les cases.**

| Marque | Signification |
| --- | --- |
| `[x]` | constaté **dans le dépôt**, en lisant le fichier |
| `[x]` + **(posé ici)** | absent avant cette passe, écrit dans ce commit — donc **jamais synchronisé ni vérifié en cluster** |
| `[ ]` | non constaté : absent, hors du périmètre autorisé, ou invérifiable depuis le dépôt |

> [!IMPORTANT]
> Aucune case n'a été cochée sur la foi d'un comportement observé : le cluster n'a pas été
> interrogé. Tout ce qui demande un `kubectl` — une session anonyme, un webhook refusé, une
> restauration Velero — reste **non coché par construction**, y compris quand la configuration
> correspondante est en place. La liste « Vérifications après mise en ligne » est donc vide de
> bout en bout, et ce n'est pas un jugement sur la configuration.

---

## Avant le déploiement

- [x] **Choisir le namespace définitif** — `forgejo`, posé par `manifests/namespace.yaml`
  (sync-wave `-1`), repris par `namespace:` du `kustomization.yaml`, par
  `destination.namespace` de l'Application et par le `SealedSecret` admin, qui est chiffré pour
  le couple (`forgejo-admin`, `forgejo`).
- [ ] **Sceller `SECRET_KEY`, `INTERNAL_TOKEN`, `LFS_JWT_SECRET`, `OAUTH2_JWT_SECRET`, creds CNPG,
  creds SMTP** — partiellement préparé, **rien n'est scellé** :
  - les quatre secrets cryptographiques et le mot de passe SMTP : ajoutés **(posé ici)** comme
    documents 2 et 3 de `manifests/forgejo-admin.secret.yaml`, qui porte désormais les trois
    Secrets du composant — `kubeseal` lit un flux multi-documents, un seul scellement suffit.
    Câblage `additionalConfigFromEnvs` en `optional: true` **(posé ici)** : les deux sont inertes
    tant qu'ils ne sont pas scellés. Le scellement demande le contrôleur, donc le cluster ;
  - creds CNPG : **décision contraire, documentée** — le secret `forgejo-db-app` est auto-généré
    par l'opérateur et « vit et meurt avec la base » (`manifests/forgejo-db.yaml`). Le sceller
    reviendrait à figer une valeur que CNPG régénère.
- [ ] **Sauvegarder la clé privée du contrôleur sealed-secrets hors cluster** — la procédure
  existe (`infra/sealed-secrets/README.md` §Backup / restauration de la clé) et le motif
  `*sealed-secrets-key*.yaml` est au `.gitignore`. Que la sauvegarde ait été **faite** ne se lit
  nulle part dans le dépôt, par construction.
- [x] **Réserver une IP sur le pool LB-IPAM pour le service SSH** — **sans objet depuis le
  2026-09-06.** Le SSH est coupé, le Service `forgejo-ssh` est repassé en `ClusterIP` et
  `192.168.1.81` est rendue au pool `bleu-kalecgos-pool` (`infra/cilium/manifests/ip-pool.yaml`,
  bloc `192.168.1.80-89`). Ce composant ne réserve plus aucune IP de pool.
- [ ] **Enregistrement DNS + certificat cert-manager** — le certificat est là : `Certificate`
  wildcard `*.wittner.tech` (`letsencrypt-prod`, DNS-01), consommé par le listener
  `https-public` de `shared-gw`. Restent hors du dépôt, donc invérifiables : l'**enregistrement
  DNS** `forgejo.wittner.tech` (CNAME vers `<tunnel-id>.cfargotunnel.com`, **Proxied**),
  l'**ingress du tunnel** (`https://192.168.1.50` avec `originServerName`) et la **conf Traefik**
  (routeur HTTP vers `192.168.1.80`).
  ⚠️ **À supprimer s'ils traînent encore**, côté Cloudflare, box et Traefik : l'enregistrement A
  `git-ssh.wittner.tech`, la redirection 2222 et l'entrypoint `ssh` + son routeur TCP. Tant qu'ils
  existent, l'IP d'origine reste publiée et un port reste ouvert — alors que le dépôt, lui,
  n'expose plus rien en SSH.
- [ ] **Passer les repos candidats au scan de secrets avant de les rendre publics** — acte
  opératoire, hors dépôt. Atténué par `[repository] DEFAULT_PRIVATE: private` **(posé ici)** :
  rendre un dépôt public devient un geste explicite.

## Configuration Forgejo

### Comptes

- [x] **`DISABLE_REGISTRATION = true`** — `gitea.config.service`, déjà en place avant cette passe.
- [x] **`INSTALL_LOCK = true`** — `gitea.config.security` **(posé ici, explicité)**. Le chart le
  forçait déjà (`gitea.inline_configuration.defaults`) ; l'écrire rend sa disparition visible en
  revue lors d'un bump.
- [x] **`ENABLE_OPENID_SIGNIN = false`, `ENABLE_OPENID_SIGNUP = false`** — `gitea.config.openid`
  **(posé ici)**. ⚠️ Section `[openid]`, pas `[service]` : écrites ailleurs, ces clés n'auraient
  produit ni erreur ni effet. `ENABLE_OPENID_SIGNUP` valait déjà `false` par héritage
  (`!DISABLE_REGISTRATION`), mais elle *suivait* l'inscription libre — la rouvrir un jour aurait
  rouvert les deux.
- [x] **`DEFAULT_KEEP_EMAIL_PRIVATE = true` + `NO_REPLY_ADDRESS`** — `gitea.config.service`
  **(posé ici)**, `NO_REPLY_ADDRESS: noreply.forgejo.wittner.tech`, sous-domaine dédié sans MX.
  ⚠️ Ne vaut que pour les comptes créés **après** : le compte admin existant garde son choix.
- [x] **`SHOW_USER_EMAIL = false`** — `gitea.config.ui` **(posé ici)**.
- [ ] **2FA activée, codes de récupération stockés hors ligne** — acte dans l'UI, aucune clé
  d'`app.ini` ne l'impose côté serveur. Rien à poser dans ce dossier.

### Repos

- [x] **`DEFAULT_PRIVATE = private`** — `gitea.config.repository` **(posé ici)**, complété par
  `DEFAULT_PUSH_CREATE_PRIVATE: true` : le chemin « dépôt créé par un `git push` » ne contourne
  pas la règle.
- [x] **`REQUIRE_SIGNIN_VIEW = false`** — `gitea.config.service` **(posé ici)**. Valeur
  explicitement `false` et commentée comme telle : c'est ce qui laisse un anonyme voir les dépôts
  publics, ce n'est pas un oubli.

### Anti-SSRF

- [x] **`[migrations] ALLOW_LOCALNETWORKS = false`** — **(posé ici)**, explicité bien qu'étant le
  défaut amont, parce qu'il est load-bearing.
- [x] **`[migrations] BLOCKED_DOMAINS` ou `ALLOWED_DOMAINS`** — `ALLOWED_DOMAINS` **(posé ici)**,
  liste blanche : `github.com`, `*.github.com`, `gitlab.com`, `*.gitlab.com`, `codeberg.org`,
  `*.codeberg.org`, `git.sr.ht`. ⚠️ Le joker ne couvre qu'un niveau ; toute autre forge doit être
  ajoutée sous peine de `migrate from %s is not allowed`.
- [x] **`[webhook] ALLOWED_HOST_LIST` explicite, jamais `*`** — `external` **(posé ici)**,
  mot-clé Forgejo signifiant « toutes les adresses sauf loopback, privé et link-local ». C'est
  l'inverse exact du défaut amont `*`.

### Divulgation

- [x] **`SHOW_FOOTER_VERSION = false`** — `gitea.config.other` **(posé ici)**.
- [x] **`ENABLE_SWAGGER = false`** — `gitea.config.api` **(posé ici)**.
- [ ] **Mailer configuré (notifications de connexion, reset)** — **non configuré, et c'est le
  manque le plus gênant de la liste.** Le câblage est prêt (`FORGEJO__MAILER__PASSWD` en
  `optional: true`, template SMTP, bloc `mailer:` commenté avec sa procédure), mais **aucun relais
  n'est choisi** : celui d'Alertmanager est lui-même resté à `REMPLACER`. Conséquence à assumer
  telle quelle : la perte du mot de passe admin ne se répare que par `kubectl exec`.

## Kubernetes

- [x] **`CiliumNetworkPolicy` egress : deny plages privées sauf CNPG + DNS + SMTP** —
  `manifests/forgejo-netpol.yaml` **(posé ici)**. DNS (CoreDNS), CNPG (`cnpg.io/cluster:
  forgejo-db`, 5432), puis `toCIDRSet: 0.0.0.0/0` **except** `10/8`, `172.16/12`, `192.168/16`,
  `169.254/16`, `127/8`, `100.64/10`. ⚠️ `toEntities: [world]` aurait été un piège : en Cilium,
  `world` inclut les machines du LAN. Le SMTP externe est couvert par la règle publique ; un
  relais sur le LAN demanderait un `toCIDR` explicite.
- [x] **`CiliumNetworkPolicy` ingress : uniquement depuis l'ingress controller** — même fichier
  **(posé ici)**. Port 3000 depuis `ingress` / `host` / `remote-node` uniquement, et **plus rien
  d'autre** : la règle du port 2222 est partie avec le SSH le 2026-09-06. ⚠️ Réserve inchangée et
  écrite dans le fichier : `host`/`remote-node` sont nécessaires (sondes kubelet, et Envoy selon
  son mode de déploiement), ce qui laisse un pod en hostNetwork joindre ce port.
- [x] **`securityContext` : `runAsNonRoot`, capabilities droppées, seccomp `RuntimeDefault`** —
  `helm-values.yaml` **(posé ici)** : `containerSecurityContext` avec `runAsNonRoot`,
  `runAsUser/Group: 1000`, `drop: [ALL]`, `allowPrivilegeEscalation: false`, `privileged: false` ;
  `seccompProfile: RuntimeDefault` au niveau `podSecurityContext` pour couvrir aussi les trois
  init-containers. Ne tient qu'avec l'image rootless, déjà active. `readOnlyRootFilesystem` **non**
  posé : non vérifié conteneur par conteneur, le mode d'échec serait un CrashLoopBackOff.
- [x] **Requests/limits CPU et mémoire posées** — déjà en place : `requests` CPU 100m / mémoire
  512Mi, `limits` mémoire 2Gi. ⚠️ **Pas de limite CPU, volontairement** et c'est documenté : un
  `git gc` throttlé allonge la transaction sans rien protéger. La case est cochée pour ce qui est
  posé, pas pour une couverture complète des quatre champs.
- [x] **Service LoadBalancer dédié pour SSH, serveur SSH interne de Forgejo** — **annulé le
  2026-09-06.** Le serveur SSH ne démarre plus (`START_SSH_SERVER: false`) et l'application ne
  propose plus de clone SSH (`DISABLE_SSH: true`). Le Service `forgejo-ssh` subsiste en
  `ClusterIP` — le chart 17.1.5 rend `ssh-svc.yaml` et son `containerPort` **sans condition**, il
  n'existe pas de `service.ssh.enabled` — donc sans IP de pool, sans annonce L2 et sans endpoint.
  `loadBalancerSourceRanges` a été retiré : il n'a aucun sens hors d'un type `LoadBalancer`.
- [x] **Aucun port ouvert** — révision, le 2026-09-06, du montage hybride décidé le matin même.
  Tout entre désormais par le tunnel Cloudflare (`cloudflared`, LXC `192.168.1.56`, connexion
  *sortante*) : aucun port entrant, et le WAF / rate-limiting / absorption DDoS de l'edge ne sont
  contournables **par rien**.

  Ce que la coupure du SSH a supprimé :
  - la redirection **2222** de la box, qui était le seul port ouvert de l'installation ;
  - l'enregistrement **A `git-ssh.wittner.tech`**, qui **publiait l'IP d'origine** — fuite
    d'information d'autant plus durable que l'IP est fixe ;
  - le routeur TCP de Traefik et son entrypoint `ssh`.

  ⚠️ La règle **443 fermé** reste entière et devient la seule qui compte : c'est elle, désormais
  seule, qui garantit que l'edge n'est pas contournable.

  Ce que ça coûte, et qui est assumé : Cloudflare plafonne une requête à **100 Mo** sur le plan
  gratuit, or un `git push` est un seul POST — un push volumineux se prend un `413` que git
  n'explique pas, et chaque objet LFS compte pour une requête. L'échappatoire est le chemin LAN,
  où le DNS interne sert `192.168.1.50` et où le trafic ne traverse jamais l'edge : un import
  initial volumineux se fait depuis la maison, sans plafond.

  Ce qui tient en défense de fond, maintenant que tout passe en HTTPS authentifié :
  - `DISABLE_REGISTRATION: true` : aucun compte ne se crée depuis l'extérieur ;
  - `GLOBAL_TWO_FACTOR_REQUIREMENT: all` : sans second facteur, l'API répond `403` et le git en
    HTTP authentifié part en `302` vers la page d'enrôlement ;
  - les jetons d'accès personnels se **scopent, s'expirent et se révoquent un par un**, ce qu'une
    clé SSH de compte ne savait pas faire. ⚠️ En regard, un jeton est un secret **porteur**,
    transmis à chaque requête là où une clé privée ne quitte jamais le poste : à ranger dans un
    credential helper (trousseau macOS), jamais dans un `.git-credentials` en clair.

  ⚠️ Contrepartie, plus lourde qu'avant : **Cloudflare est maintenant une dépendance dure pour
  TOUT accès externe**, Git compris. Une panne de tunnel ne laisse plus que l'accès depuis le LAN
  (le DNS interne sert `192.168.1.50` pour tout `*.wittner.tech`). Auparavant le SSH survivait à
  cette panne ; c'est le prix direct de la simplification, et il est payé sciemment.

- [x] **`/metrics` non routé publiquement** — déjà en place : `gitea.metrics.enabled: false`,
  décision documentée (l'endpoint est servi sur le port HTTP applicatif, donc derrière la
  HTTPRoute publique ; sans `[metrics] TOKEN` il serait lisible depuis Internet).
- [ ] **Rate limiting ingress sur `/user/login`** — **plus « impossible », mais toujours hors
  dépôt : la limitation est posée à l'edge Cloudflare.** Règle *Rate limiting* `Forgejo rate
  limiting`, active, action **Block**, sur les chemins d'authentification :

  ```
  (http.request.uri.path wildcard r"/user/login*") or
  (http.request.uri.path wildcard r"/user/two_factor*") or
  (http.request.uri.path wildcard r"/user/webauthn*") or
  (http.request.uri.path wildcard r"/user/forgot_password*") or
  (http.request.uri.path wildcard r"/user/recover_account*") or
  (http.request.uri.path wildcard r"/user/activate*") or
  (http.request.uri.path wildcard r"/user/link_account*") or
  (http.request.uri.path wildcard r"/user/oauth2/*") or
  (http.request.uri.path wildcard r"/login/oauth/*") or
  (http.request.uri.path wildcard r"/user/sign_up*")
  ```

  Rien de tout cela ne se lit dans le dépôt — configuration de tableau de bord, donc `[ ]` par la
  convention de cette liste, pas par absence.

  Ce que chaque motif ferme, au-delà du formulaire de login : `two_factor` et `webauthn` (le second
  facteur, sinon on limite la première étape et pas la seconde) ; `forgot_password` puis
  `recover_account`, **qui est l'endroit où le jeton de réinitialisation est consommé**
  (`?code=…`) — c'est lui le vrai brute-forçable de la paire, il n'existe pas de
  `/user/reset_password` chez Forgejo ; `activate` et `activate_email`, mêmes codes à usage
  unique ; `link_account*` (`link_account_signin`, `link_account_signup`), chemin de connexion
  alternatif ; `oauth2/*`, le signin par provider externe et son callback ; **`/login/oauth/*`**,
  Forgejo *en tant que* fournisseur OAuth2 (`access_token`, `introspect`, `grant`) — endpoints à
  identifiants, et les seuls de la liste à vivre hors de `/user/` ; `sign_up*` enfin, redondant avec
  `DISABLE_REGISTRATION` mais qui coupe le sondage avant l'origine. `/user/login/openid` est déjà
  couvert par le joker de `/user/login*`.

  ⚠️ Trois réserves.
  - Le plan gratuit n'autorise **qu'une seule** règle de rate limiting (`1/1 rules`) et son
    compteur est **partagé** entre tous les motifs ci-dessus. C'est sans conséquence ici — ce sont
    tous des chemins à faible volume — mais cela interdit d'y ajouter `/api/v1/*` ou les endpoints
    Git HTTP (`*/git-upload-pack`, `*/git-receive-pack`) : un seuil calibré pour un formulaire de
    login casserait un `clone` légitime. Pour la même raison, **ne pas élargir en `/user/*`** :
    `/user/avatar/*` est servi à chaque page.
  - La force brute sur `/api/v1/*` n'est donc **pas** limitée. Ce qui la tient, c'est
    `GLOBAL_TWO_FACTOR_REQUIREMENT: all` (403 sans second facteur), pas l'edge.
  - La protection ne vaut que pour le chemin edge : un accès **depuis le LAN**, qui tape
    `192.168.1.50` sans traverser Cloudflare, n'est limité par rien.

  Côté cluster, le constat d'origine tient toujours : ni Forgejo ni le Gateway API de Cilium
  n'offrent de limitation de débit.
- [ ] **Rate limiting ingress sur `/archive/`, `/raw/`, `/blame/`, `/commits/`** — **non couvert**
  par la règle ci-dessus, qui ne vise que l'authentification, et le quota d'une règle sur le plan
  gratuit est déjà consommé. La limite de Gateway API reste entière : les `matches` ne connaissent
  que `Exact` et `PathPrefix`, incapables d'exprimer un segment au milieu de
  `/<owner>/<repo>/archive/` — un *wildcard* Cloudflare, lui, saurait l'écrire. Atténué — pas
  remplacé — par le `robots.txt`, qui ne s'adresse qu'aux robots qui le respectent.
- [ ] **Filtrage géographique à l'edge** — hors checklist d'origine, constaté sur le tableau de
  bord : règle personnalisée `Block not EU` (`Continent does not equal EU`), active, action
  **Block**. Coupe l'essentiel du bruit de fond automatisé avant qu'il n'atteigne l'origine.
  ⚠️ À assumer : un déplacement hors UE coupe l'accès à sa propre forge, et le filtre est
  contournable par un VPN européen — c'est une réduction de bruit, pas un contrôle d'accès.
  ⚠️ Aucune **Managed rule** (WAF managé) n'est configurée : elles demandent un plan payant.
- [x] **`robots.txt` restrictif** — `manifests/forgejo-robots.yaml` **(posé ici)**, ConfigMap monté
  sur `/data/gitea/robots.txt` (Forgejo n'a aucune clé d'`app.ini` pour ça). Ferme les quatre
  familles d'URL coûteuses ci-dessus plus `/user/`, `/api/`, `/explore/`, avec `Crawl-delay: 10`,
  et laisse les pages d'accueil de dépôts indexables. ⚠️ Le fichier n'est détecté **qu'au
  démarrage** : éditer le ConfigMap impose un `rollout restart`.
- [ ] **HSTS, TLS 1.2 minimum, headers de sécurité** — deux tiers faits, un tiers hors périmètre :
  - HSTS et en-têtes : **(posé ici)** dans `manifests/forgejo-httproute.yaml`, filtre
    `ResponseHeaderModifier` — `Strict-Transport-Security: max-age=31536000; includeSubDomains`
    (sans `preload`, volontairement), `X-Content-Type-Options: nosniff`,
    `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin` ;
  - **TLS 1.2 minimum : NON**, et impossible ici. La version minimale se règle sur le Gateway
    partagé (`infra/gateway-api/manifests/gateway.yaml`), hors du dossier autorisé.
- [ ] **Backup CNPG + Velero sur le namespace, incluant le PVC des données Git** — **non**, et le
  `README.md` du composant le signalait déjà : `schedules.daily.template.includedNamespaces` de
  Velero est une **liste blanche** qui ne contient pas `forgejo`. Le fichier à modifier est
  `infra/velero/helm-values.yaml`, hors périmètre. Un `spec.backup` sur le `Cluster` CNPG
  supposerait un bucket et des identifiants qui n'existent pas.

## Si tu actives les Actions

Aucun runner n'est déployé (`README.md` §Non retenu) : le moteur est actif côté serveur, mais rien
n'exécute de workflow. Les quatre cases portent sur un composant qui n'existe pas dans le dépôt.

- [ ] Runner dans un namespace séparé
- [ ] ServiceAccount sans droits sur l'API Kubernetes
- [ ] Aucun socket Docker monté
- [ ] NetworkPolicy stricte sur le runner

## Vérifications après mise en ligne

Aucune n'a été effectuée : elles demandent toutes une instance en service, et le cluster n'a pas
été interrogé. La configuration correspondante est indiquée entre parenthèses quand elle existe.

- [ ] Créer un compte depuis une session anonyme → doit échouer (`DISABLE_REGISTRATION`,
      `ENABLE_OPENID_SIGNUP`)
- [ ] Navigation anonyme : dépôts publics visibles, privés absents des listings et de la recherche
      (`REQUIRE_SIGNIN_VIEW: false` + `DEFAULT_PRIVATE: private`)
- [ ] Aucune adresse mail sur le profil public ni dans les commits (`SHOW_USER_EMAIL`,
      `DEFAULT_KEEP_EMAIL_PRIVATE`, `NO_REPLY_ADDRESS`) — ⚠️ à vérifier **en priorité** : le
      compte admin est antérieur au réglage et garde son choix
- [ ] Webhook vers une IP interne du cluster → doit être refusé (`ALLOWED_HOST_LIST: external`,
      puis la policy egress)
- [ ] Migration depuis une URL en `192.168.x.x` → doit être refusée (`ALLOW_LOCALNETWORKS: false`,
      `ALLOWED_DOMAINS`, puis la policy egress)
- [ ] Depuis un shell dans le pod : API Kubernetes et autres services du cluster injoignables
      (policy egress + `automountServiceAccountToken: false`)
- [ ] Depuis un réseau externe : **aucun port ouvert** sur l'IP publique — la redirection 2222 a
      été retirée le 2026-09-06, la 443 ne l'a jamais été (`nc -vz <ip-publique> 2222` doit
      échouer, et rester le seul port jamais testé positif)
- [ ] `git clone` / `git push` en HTTPS avec un jeton personnel → seul chemin Git restant
- [ ] Tentatives de login ratées en série → rate limiting — **testable depuis le 2026-09-06**,
      mais uniquement **depuis Internet** (règle Cloudflare `Forgejo rate limiting`, action
      `Block`). La même série lancée depuis le LAN doit, elle, passer sans être limitée : c'est
      le comportement attendu, pas un échec du test
- [ ] Token d'API sans 2FA : vérifier que ses scopes sont limités
- [ ] Redéploiement du chart : sessions et tokens survivent — **ne prouvera rien tant que
      `forgejo-secrets` n'est pas scellé** : aujourd'hui la stabilité vient du fichier `app.ini`
      sur le PVC, pas d'un secret versionné
- [ ] Restaurer la base et un PVC depuis Velero dans un namespace de test — **impossible** : le
      namespace n'est pas dans le périmètre de sauvegarde
- [x] **Renovate ou équivalent branché sur l'image et le chart** — constaté dans `renovate.json` :
  le manager `argocd` suit `*.app.yaml`, et le `repoURL` du chart est écrit **sans** le préfixe
  `oci://` précisément pour que Renovate le suive en datasource `docker` (commentaire dédié dans
  `forgejo.app.yaml`). `minimumReleaseAge: 7 days` et `internalChecksFilter: strict` s'appliquent.
  L'image, elle, est celle du chart : elle est suivie **par ricochet**, pas indépendamment.

---

## Conclusion — ce qui reste à faire

### 1. Bloquant avant d'ouvrir sur Internet

1. **Synchroniser et vérifier ce qui vient d'être posé.** Rien de ce commit n'a tourné. Trois
   changements peuvent empêcher le pod de démarrer ou le rendre injoignable, et leur mode d'échec
   est muet :
   - la `CiliumNetworkPolicy` (timeout, pas d'erreur) —
     `kubectl -n forgejo delete ciliumnetworkpolicy forgejo` pour un rollback immédiat ;
   - le montage du `robots.txt` (`extraContainerVolumeMounts`) ;
   - le `containerSecurityContext` (CrashLoopBackOff au démarrage si une hypothèse est fausse).

   ```bash
   kubectl -n forgejo rollout status deploy/forgejo
   kubectl -n forgejo logs deploy/forgejo -c configure-gitea
   curl -sI https://forgejo.wittner.tech/ | grep -i strict-transport
   curl -s  https://forgejo.wittner.tech/robots.txt
   ```

2. **Mettre `forgejo` sous sauvegarde.** C'est le seul point de la liste dont l'absence ne se
   rattrape pas après coup, et le `README` le signalait déjà avant cet audit. Ajouter `forgejo` à
   `schedules.daily.template.includedNamespaces` dans `infra/velero/helm-values.yaml`
   (**hors du périmètre autorisé**), puis vérifier deux `podvolumebackups` au backup suivant : le
   PVC `forgejo-data` **et** celui du pod CNPG.

3. **Supprimer `manifests/forgejo-admin.secret.yaml`.** Le fichier est encore présent dans l'arbre
   de travail, **en clair, avec un mot de passe admin réel**. Il est gitignoré, donc jamais
   poussé — mais la procédure du `README` prévoyait de le détruire après scellement, et le
   `SealedSecret` correspondant existe déjà. Je ne l'ai pas supprimé de moi-même : c'est peut-être
   la seule copie du mot de passe.

### 2. Important, dans la foulée

4. **Choisir un relais SMTP et activer le mailer** (§Mailer du `README`). Sans lui, pas de reset de
   mot de passe : la récupération passe obligatoirement par un accès au cluster. Le même relais que
   celui d'Alertmanager fera l'affaire — il reste à choisir, lui aussi.

5. **Sceller les quatre secrets cryptographiques** (§Sceller les secrets cryptographiques). Tant
   que ce n'est pas fait, le PVC reste irremplaçable : sessions, jetons d'API, jetons LFS et OAuth2
   ne sont déchiffrables que par lui. ⚠️ Sceller les valeurs **déjà en place**, jamais des valeurs
   neuves — et comme le scellement porte sur le fichier entier, remplir le mot de passe admin et le
   SMTP dans le même passage.

6. **Activer la 2FA sur le compte admin** et stocker les codes de récupération hors ligne. Aucune
   configuration ne peut le faire à votre place.

7. **Vérifier le profil du compte admin** : il a été créé avant `DEFAULT_KEEP_EMAIL_PRIVATE`, donc
   `jeanbaptiste.wittner@outlook.com` peut encore être visible. Paramètres → Compte.

### 3. Hors du périmètre autorisé — à traiter ailleurs

8. **TLS 1.2 minimum sur le Gateway** (`infra/gateway-api/manifests/gateway.yaml`).

9. **Limitation de débit** — **partiellement réglée à l'edge**, hors dépôt : la règle Cloudflare
   `Forgejo rate limiting` bloque les rafales sur `/user/login*`, `/user/two_factor*` et les autres
   chemins d'authentification ; la règle `Block not EU` coupe le bruit hors UE en amont. Reste
   ouvert : les endpoints coûteux (`/archive/`, `/raw/`, `/blame/`, `/commits/`) ne sont pas
   limités — le plan gratuit ne donne qu'**une** règle de rate limiting, déjà consommée — et le
   chemin LAN n'est limité par rien. Côté cluster, la contrainte « pas de logiciel supplémentaire »
   n'a pas bougé : ni Forgejo ni le Gateway API de Cilium n'en proposent. Le `robots.txt` ne couvre
   toujours que les robots polis.

### 4. Recommandations, non appliquées volontairement

Ces trois points ne figurent pas dans la checklist ; ils n'ont **pas** été modifiés pour ne pas
élargir la commande, mais ils comptent pour une instance publique.

- **Actions est actif côté serveur alors qu'aucun runner n'existe.** `gitea.config.actions.ENABLED:
  false` réduirait la surface et la rétention par défaut (artefacts 90 j, logs 365 j) sans rien
  casser aujourd'hui. Décision produit : c'est le moment de la prendre, avant que des workflows
  n'existent.
- **Le registre de paquets est actif par défaut**, sans quota (`[quota] ENABLED: false`), sur un
  volume qui ne borne rien. Le `README` le documente déjà (§Dimensionnement du volume) ; le risque
  change de nature une fois la forge publique.
- **`REVERSE_PROXY_TRUSTED_PROXIES` n'est pas réglé.** Derrière le Gateway, Forgejo journalise
  probablement l'IP du proxy au lieu de celle du client — ce qui rend toute analyse de tentatives de
  connexion peu exploitable. ⚠️ Le rate limiting Cloudflare, lui, n'en souffre pas : il s'applique à
  l'edge, sur l'IP réelle du client, bien avant l'origine. C'est en revanche exactement ce qui
  empêcherait un blocage **côté Forgejo** (ban d'IP, corrélation d'échecs) de viser la bonne
  adresse.
