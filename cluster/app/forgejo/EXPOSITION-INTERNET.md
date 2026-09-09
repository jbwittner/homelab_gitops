# Exposition de Forgejo sur Internet — état de la checklist

> [!IMPORTANT]
> **Audit daté du 2026-09-06. La majeure partie de sa liste a été soldée depuis.** Sont faits : le
> scellement des secrets, le mailer, la mise sous sauvegarde du namespace, la 2FA obligatoire, et
> toute la chaîne de sauvegarde CNPG qui n'existait pas à l'écriture. Les passages ci-dessous qui
> décrivent ces points comme « à faire » ou « non configuré » sont donc **périmés** ; ils sont
> corrigés sur place, mais la §Conclusion est la seule vue à jour.
>
> **L'état courant du composant est [`README.md`](README.md)**, pas cette page. Elle est conservée
> pour le raisonnement de sécurité — modèle d'accès, surface exposée, arbitrages — qui n'a pas
> vieilli.

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
- [x] **Sceller `SECRET_KEY`, `INTERNAL_TOKEN`, `LFS_JWT_SECRET`, `OAUTH2_JWT_SECRET`, creds CNPG,
  creds SMTP** — ✅ **fait depuis** : `manifests/forgejo-admin.sealed.yaml` porte les trois Secrets
  et sa ligne est active dans le `kustomization.yaml`. Le détail d'origine, encore exact sur le
  fond :
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
- [x] **2FA activée, codes de récupération stockés hors ligne** — ✅ **imposée côté serveur
  depuis** : `GLOBAL_TWO_FACTOR_REQUIREMENT: all` (`helm-values.yaml`, `gitea.config.security`).
  L'enrôlement et la mise à l'abri des codes de récupération restent un acte manuel dans l'UI.

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
- [x] **Mailer configuré (notifications de connexion, reset)** — ✅ **fait depuis** : relais
  `smtp-relay.brevo.com:587`, `mailer.ENABLED: true` (`helm-values.yaml`), mot de passe dans le
  Secret `forgejo-smtp`. Alertmanager utilise le même relais. La perte du mot de passe admin se
  répare donc par mail, sans `kubectl exec`.

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

- [x] **`/metrics` non routé publiquement** — **révisé le 2026-09-09** : les métriques sont
  désormais **activées** (`gitea.metrics.enabled: true`) pour le dashboard « Forge — forgejo », et
  la case reste cochée grâce à **trois** couches, pas une (cf. [README §Métriques](README.md#métriques)) :
  `[metrics] TOKEN` scellé (401 sans en-tête `Bearer`), règle `PathType: Exact` du HTTPRoute qui
  **redirige `/metrics` vers `/`** avant tout backend, et `CiliumNetworkPolicy` n'ouvrant le 3000
  qu'au pod Prometheus. ⚠️ La variable du token est câblée **sans** `optional: true` : sans le
  Secret, le pod refuse de démarrer plutôt que de servir un `/metrics` ouvert.
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
- [x] **Backup CNPG + Velero sur le namespace, incluant le PVC des données Git** — ✅ **les deux
  chaînes existent depuis** : `includedNamespaces` contient `forgejo` (velero, 03:00 UTC), et la
  base a sa propre chaîne barman-cloud (`ObjectStore` + `spec.plugins` + `ScheduledBackup`, 02:00
  UTC) — cf. [`README.md`](README.md) §Sauvegarde et
  [`doc/forgejo-pra.md`](../../../doc/forgejo-pra.md).

  ⚠️ **Un seul `podvolumebackup` est attendu, pas deux** : le PVC de la base est explicitement
  exclu de la copie kopia depuis le 2026-09-08 (`volume-policies.yaml`), sa sauvegarde relevant de
  barman. Deux `podvolumebackups` signaleraient au contraire une régression.

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

> **Révisée le 2026-09-09.** La liste d'origine comptait neuf points ; six sont soldés.

### Soldé depuis l'audit

1. ✅ **Sync et vérification** du commit d'origine (netpol, `robots.txt`, `containerSecurityContext`) —
   la forge tourne, est publique, et [forgejo-monitoring](../forgejo-monitoring/README.md) alerte
   désormais si elle cesse de répondre.
2. ✅ **`forgejo` sous sauvegarde** — deux chaînes, velero (PVC, 03:00 UTC) et barman-cloud (base,
   02:00 UTC). Le plan de reprise est écrit **et éprouvé** : dix passages consignés dans
   [`doc/forgejo-pra-exercice.md`](../../../doc/forgejo-pra-exercice.md).
3. ✅ **Mailer** — relais Brevo, `mailer.ENABLED: true`, mot de passe scellé.
4. ✅ **Quatre secrets cryptographiques scellés** — `forgejo-admin.sealed.yaml`, trois Secrets en un
   scellement.
5. ✅ **2FA imposée côté serveur** — `GLOBAL_TWO_FACTOR_REQUIREMENT: all`.
6. ✅ **Limitation de débit à l'edge** — règles Cloudflare `Forgejo rate limiting` et `Block not EU`.

### Ouvert

7. ⚠️ **Les templates en clair traînent encore dans l'arbre de travail** :
   `manifests/forgejo-admin.secret.yaml` (mot de passe admin réel) et
   `manifests/forgejo-db-gcs.secret.yaml` (clé de compte de service GCP). Ils sont gitignorés, donc
   jamais poussés, mais les deux `SealedSecret` correspondants existent : la procédure prévoit de
   les détruire après scellement. **Vérifier d'abord que le mot de passe admin est bien enregistré
   ailleurs** — c'est peut-être sa seule copie en clair.

8. **TLS 1.2 minimum sur le Gateway** — toujours pas réglé : les deux listeners de
   `infra/gateway-api/manifests/gateway.yaml` n'ont pas de bloc `options`. Hors du périmètre de
   l'audit d'origine, toujours à traiter.

9. **`REVERSE_PROXY_TRUSTED_PROXIES` n'est pas réglé.** Derrière le Gateway, Forgejo journalise
   l'IP du proxy et non celle du client, ce qui rend inexploitable toute corrélation d'échecs de
   connexion côté application. ⚠️ Le rate limiting Cloudflare n'en souffre pas — il s'applique à
   l'edge, sur l'IP réelle. C'est en revanche ce qui empêcherait un ban d'IP **côté Forgejo** de
   viser la bonne adresse.

10. **Actions est actif côté serveur alors qu'aucun runner n'existe.** `gitea.config.actions.ENABLED:
    false` réduirait la surface et la rétention par défaut (artefacts 90 j, logs 365 j) sans rien
    casser. Décision produit, à prendre avant que des workflows n'existent.

11. **Le registre de paquets est actif par défaut**, sans quota (`[quota] ENABLED: false`), sur un
    volume qui ne borne rien — cf. [`README.md`](README.md) §Dimensionnement du volume.

12. **Endpoints coûteux non limités** (`/archive/`, `/raw/`, `/blame/`, `/commits/`) : le plan
    Cloudflare gratuit ne donne qu'**une** règle de rate limiting, déjà consommée. Le chemin LAN
    n'est limité par rien. Ni Forgejo ni le Gateway API de Cilium n'offrent d'alternative sans
    ajouter un logiciel. Le `robots.txt` ne couvre que les robots polis.

13. **Vérifier le profil du compte admin** : créé avant `DEFAULT_KEEP_EMAIL_PRIVATE`, son adresse
    peut encore être visible. Paramètres → Compte.
