# Exposition de Forgejo sur Internet — état de la checklist

Audit du seul périmètre autorisé : `cluster/app/forgejo/`. Aucun logiciel n'a été ajouté, aucune
ressource n'a été créée hors de ce dossier.

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
- [x] **Réserver une IP sur le pool LB-IPAM pour le service SSH** — `192.168.1.85` via
  `lbipam.cilium.io/ips`, dans le bloc `192.168.1.80-89` du `CiliumLoadBalancerIPPool`
  (`infra/cilium/manifests/ip-pool.yaml`). L'annotation moderne est utilisée, pas
  `spec.loadBalancerIP` ni `io.cilium/lb-ipam-ips`.
- [ ] **Enregistrement DNS + certificat cert-manager** — le certificat est là : `Certificate`
  wildcard `*.wittner.tech` (`letsencrypt-prod`, DNS-01), consommé par le listener
  `https-public` de `shared-gw`. Les **enregistrements DNS** (`forgejo.wittner.tech`,
  `forgejo.lan.wittner.tech` → `192.168.1.85`) sont hors du dépôt : invérifiables.
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
- [x] **`CiliumNetworkPolicy` ingress : uniquement depuis l'ingress controller et le service SSH**
  — même fichier **(posé ici)**. Port 3000 depuis `ingress` / `host` / `remote-node` uniquement,
  port 2222 pour le SSH. ⚠️ Deux réserves écrites dans le fichier : `host`/`remote-node` sont
  nécessaires (sondes kubelet, et Envoy selon son mode de déploiement), ce qui laisse un pod en
  hostNetwork joindre le port ; et le filtrage par source du SSH n'est **pas** dans la policy
  (SNAT en `externalTrafficPolicy: Cluster`) mais dans `loadBalancerSourceRanges`.
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
- [x] **Service LoadBalancer dédié pour SSH, serveur SSH interne de Forgejo** — déjà en place :
  Service `forgejo-ssh` type LoadBalancer sur `192.168.1.85` (hors Gateway, qui n'a que des
  listeners HTTPS), `START_SSH_SERVER: true` (serveur Go interne, pas OpenSSH), traduction
  22 → 2222 imposée par le rootless. **(posé ici)** en complément :
  `loadBalancerSourceRanges: [192.168.1.0/24]`, qui écrit noir sur blanc que le SSH reste un
  service de LAN.
- [x] **`/metrics` non routé publiquement** — déjà en place : `gitea.metrics.enabled: false`,
  décision documentée (l'endpoint est servi sur le port HTTP applicatif, donc derrière la
  HTTPRoute publique ; sans `[metrics] TOKEN` il serait lisible depuis Internet).
- [ ] **Rate limiting ingress sur `/user/login`** — **impossible dans le périmètre.** Ni Forgejo
  ni l'implémentation Gateway API de Cilium n'offrent de limitation de débit ; il faudrait un
  logiciel supplémentaire, explicitement exclu.
- [ ] **Rate limiting ingress sur `/archive/`, `/raw/`, `/blame/`, `/commits/`** — même blocage,
  plus une limite de Gateway API : les `matches` ne connaissent que `Exact` et `PathPrefix`,
  incapables d'exprimer un segment au milieu de `/<owner>/<repo>/archive/`. Atténué — pas
  remplacé — par le `robots.txt`, qui ne s'adresse qu'aux robots qui le respectent.
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
- [ ] Tentatives de login ratées en série → rate limiting — **échouera** : il n'y en a pas
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

9. **Limitation de débit** sur `/user/login` et les endpoints coûteux. Aucune solution ne tient
   dans la contrainte « pas de logiciel supplémentaire » : ni Forgejo ni le Gateway API de Cilium
   n'en proposent. À reprendre comme une décision d'infrastructure, en sachant que le `robots.txt`
   ne couvre que les robots polis.

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
  probablement l'IP du proxy au lieu de celle du client — ce qui rendra toute analyse de tentatives
  de connexion peu exploitable, et neutraliserait un futur rate limiting par IP.
