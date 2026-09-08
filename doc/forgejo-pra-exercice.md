# Éprouver le PRA Forgejo

## Rôle

Prouver que les sauvegardes de la forge sont **réellement restaurables**, en les remontant dans une
préprod jetable — `forgejo-preprod`, exposée sur `forgejo-preprod.lan.wittner.tech` — puis en la
détruisant.

Le plan est dans [`forgejo-pra.md`](forgejo-pra.md). Cette page est son **épreuve**. Elle existe
parce que ce composant a deux chaînes indépendantes et **six façons documentées d'obtenir une
restauration verte et fausse** : la présence d'objets dans deux buckets ne prouve ni que le PVC
porte encore ses dépôts, ni que la base est cohérente avec lui, ni que les deux se rejoignent au
même instant. Seule une restauration le prouve.

> [!IMPORTANT]
> **Ce que l'exercice prouve**
> - la sauvegarde velero contient réellement les données du PVC, pas seulement des objets ;
> - les dépôts Git restaurés sont intègres (`git fsck`) et lisibles ;
> - la chaîne barman-cloud reconstruit une base démarrable, en `bootstrap.recovery` depuis le
>   bucket seul ;
> - la base et le disque décrivent **le même ensemble de dépôts** — l'alignement du §1 du plan ;
> - Forgejo lui-même se déclare cohérent (`forgejo doctor`).
>
> **Ce qu'il ne prouve pas**
> - le RTO à volumétrie réelle : l'instance de test pèse 1,6 Mio ;
> - la reprise du cluster lui-même (Talos, ArgoCD, sealed-secrets) ;
> - la restauration **en place**, dans `forgejo` — l'exercice restaure toujours à côté ;
> - la chaîne d'exposition publique (tunnel Cloudflare, edge) : la préprod est sur le LAN.

## Le script fait tout ça

Cette page décrit ce qui se passe et pourquoi. Au quotidien, **deux scripts**, et la séparation
est le point de conception principal :

```bash
script/forgejo-pra-prepare-script.sh check   # l exercice peut-il partir ?  (ne crée rien)
script/forgejo-pra-prepare-script.sh run     # rendre les deux chaînes alignables
script/forgejo-pra-script.sh drill           # l exercice : up + verify + down
```

| Script | Rôle | Écrit où |
| --- | --- | --- |
| [`forgejo-pra-prepare-script.sh`](../script/forgejo-pra-prepare-script.sh) | établit la **condition** de l'exercice | crée deux **sauvegardes** de production |
| [`forgejo-pra-script.sh`](../script/forgejo-pra-script.sh) | joue l'exercice | uniquement dans `forgejo-preprod` |

> [!IMPORTANT]
> **L'exercice ne prépare pas sa propre condition, et c'est délibéré.** S'il n'existe aucune
> sauvegarde velero dans la fenêtre PITR, `forgejo-pra-script.sh` **refuse de partir** et renvoie
> au script de préparation. Un exercice qui fabrique lui-même ce qu'il doit éprouver devient le
> juge de sa propre condition d'exécution : il passerait au vert même le jour où la chaîne
> d'archivage est morte depuis une semaine, parce qu'il aurait relancé une sauvegarde juste avant
> de se tester.
>
> C'est aussi ce qui rend le refus **informatif** : « aucune sauvegarde alignable » est un état du
> système, pas une panne du script.

Le détail des sous-commandes de l'exercice :

```bash
script/forgejo-pra-script.sh up        # monte la préprod
script/forgejo-pra-script.sh verify    # la checklist — c'est ELLE, le test
script/forgejo-pra-script.sh status    # ce qui tourne, et ce que ça immobilise
script/forgejo-pra-script.sh down      # détruit tout
script/forgejo-pra-script.sh drill     # up + verify + down, code de sortie parlant
```

**Deux contrats distincts, et c'est la seule chose à retenir :**

| Commande | La préprod après la commande |
| --- | --- |
| `drill` | **détruite** — c'est un test, il ne laisse rien, même si `verify` échoue |
| `up` | **laissée en vie** — pour fouiller la forge d'hier |

`up` sert quand on ne veut pas seulement une réponse oui/non : comparer un dépôt à celui de la
prod, récupérer un fichier écrasé, voir ce qui a changé entre deux nuits. `drill` est la forme
pour un contrôle périodique — il sort en **2** si un contrôle échoue, et démonte quand même.

## Garde-fous

Ils ne sont pas des précautions générales : chacun ferme un mode de panne observé.

> [!CAUTION]
> **1. Le `HTTPRoute` de la sauvegarde porte le hostname public.** Il est dans le périmètre velero
> avec `hostnames: [forgejo.wittner.tech]` et `sectionName: https-public`. Restauré dans un autre
> namespace, il pose une **seconde route sur le hostname de production** : le trafic se répartit
> entre deux backends, dont celui de test.
>
> `httproutes.gateway.networking.k8s.io` est donc dans `excludedResources` du `Restore`. **C'est
> la ligne la plus importante de tout l'exercice.**

> [!CAUTION]
> **2. Une copie de la forge parle au monde extérieur.** Le pod restauré repart **tout seul** dès
> que la base apparaît, avec la configuration de production : mailer Brevo armé, webhooks vers
> `external`, miroirs de dépôts actifs. Quelques minutes suffisent à envoyer de vrais mails,
> livrer de vrais webhooks, et pousser sur un dépôt distant réel.
>
> `up` neutralise cinq réglages dans `forgejo-inline-config` — `[mailer] ENABLED`,
> `[mirror] ENABLED`, `[mirror] ENABLE_PUSH_MIRROR`, `[cron] ENABLED`,
> `[webhook] ALLOWED_HOST_LIST` — et pose une `CiliumNetworkPolicy` qui ne laisse sortir que le
> DNS et la base. `verify` les recontrôle **section par section** : un
> `grep "^ENABLED = false"` matcherait indifféremment `[mailer]`, `[mirror]` et `[cron]`, et les
> trois se valideraient mutuellement.

> [!CAUTION]
> **3. La préprod n'archive jamais.** Un cluster restauré qui archive sous le `serverName` de sa
> source **écrase les WAL de la production**. `--no-archive` est câblé en dur dans le script, non
> désactivable.
>
> Vérifié : cela n'empêche pas la reprise. Le sidecar `plugin-barman-cloud` est injecté dans le pod
> de recovery à partir de `externalClusters[].plugin` **seul** — l'init-container était présent et
> sorti en `exit 0` sans aucun `spec.plugins`.

> [!WARNING]
> **4. La production n'est jamais touchée.** Le script lit `forgejo` et n'y écrit rien. C'est le
> seul script du dépôt qui écrit dans le cluster : trois bornes le tiennent — un seul namespace,
> qu'ArgoCD ne gère pas ; aucune écriture dans `forgejo` ; `down` fait partie de la procédure.

## Prérequis

| Quoi | Pourquoi |
| --- | --- |
| `kubectl`, `jq`, `curl` | tout passe par eux |
| Une sauvegarde velero **dans la fenêtre PITR de barman** | sans recouvrement, les deux moitiés ne peuvent pas être alignées — voir ci-dessous |
| Le Secret `forgejo-db-gcs` **vivant dans `forgejo`** | absent des sauvegardes antérieures au 2026-09-08 après-midi, et son `SealedSecret` est chiffré pour le couple (nom, namespace) : il ne se déchiffre pas ailleurs |
| ~110 Gi libres dans le groupe de volumes | `thinProvision: "no"` — le LV est réservé en entier. Relevé : 838 à 942 Gi libres par nœud |

> [!WARNING]
> **Les deux chaînes ne se recouvrent pas toujours, et c'est le cas normal.** `up` sans argument
> choisit la dernière sauvegarde velero dont l'instant de fin tombe **dans** la fenêtre
> `firstRecoverabilityPoint → lastSuccessfulBackupTime` de l'`ObjectStore`. S'il n'y en a aucune,
> il refuse et explique.
>
> Deux causes, toutes deux normales :
> - la chaîne barman est plus **jeune** que la dernière sauvegarde velero (relevé le 2026-09-08 :
>   sauvegarde velero à 03:00, fenêtre barman ouverte à 15:02 — aucun recouvrement) ;
> - aucun WAL n'a été archivé **après** l'instant du PVC. Sur une base au repos, aucun ne l'est :
>   `archive_timeout` ne force un basculement que s'il y a eu de l'activité.
>
> C'est le rôle du script de préparation :
> ```bash
> script/forgejo-pra-prepare-script.sh run
> ```
> Il enchaîne les deux sauvegardes **dans cet ordre** — copie velero du PVC, **puis** sauvegarde de
> base CNPG dont le `pg_backup_stop` force le basculement de WAL qui couvre cet instant — et
> relit l'état pour **prouver** le résultat au lieu de le supposer.
>
> ⚠️ **Inverser les deux ne produit aucune erreur et ne prépare rien** : la fenêtre s'arrêterait
> *avant* l'instant du PVC, et l'exercice refuserait de partir — ce qui ressemble à un bug alors
> que c'est l'ordre qui était faux.
>
> En régime établi, la sauvegarde de base de 02:00 fait ce second geste toute seule : une reprise
> alignée est disponible **au lendemain matin**, sans préparation.

## Ce que fait `up`, et pourquoi dans cet ordre

### 1 — Namespace jetable

`forgejo-preprod`, étiqueté `homelab.wittner.tech/drill=forgejo-pra`. Un seul à la fois : `up`
refuse si le namespace existe déjà, sans quoi on finit par lire la mauvaise instance.

### 2 — Credential GCS et `ObjectStore`

Les deux sont **recopiés** depuis `forgejo`, pas recréés. L'`ObjectStore` est une ressource
**namespacée** et le plugin n'en lit que dans le namespace du `Cluster` : il ne se mutualise pas.

⚠️ `del(.metadata.namespace)` sur la copie est load-bearing : sans lui, `kubectl -n` est ignoré et
l'objet repart dans `forgejo`.

### 3 — `Restore` velero vers `forgejo-preprod`

Avec `namespaceMapping` et les exclusions du garde-fou 1.

> [!IMPORTANT]
> **Restaurer le PVC seul ne restaure aucune donnée.** La copie est en fs-backup (kopia) : la
> donnée est attachée au **Pod**, pas au PVC. C'est le `PodVolumeRestore`, déclenché par la
> restauration du Pod, qui écrit le volume avant que les conteneurs applicatifs ne démarrent.
>
> C'est pour cela que la sauvegarde contient les Pods, et que le `Restore` ne filtre **pas** sur
> `includedResources` : un `Restore` limité à `persistentvolumeclaims` crée un PVC **vide**, sans
> un message.

C'est aussi ici que reviennent les **`Secret` matérialisés** (`forgejo-admin`, `forgejo-secrets`,
`forgejo-smtp`, `forgejo-db-app`…). Ils sont ce qui rend la reprise possible sans sealed-secrets —
et ce qui fait du bucket velero un magasin de secrets.

### 4 — Suppression des orphelins CNPG

> [!CAUTION]
> **`velero` efface les `ownerReferences`.** Vérifié : `pod/forgejo-db-1`, `pvc/forgejo-db-1` et
> `svc/forgejo-db-{r,ro,rw}` reviennent **sans owner**. Rien ne les ramasse, et le pod orphelin
> démarre — il était en `1/2 Running`.
>
> Le danger n'est pas le bruit, c'est le PVC : **un `forgejo-db-1` déjà présent est adopté par le
> `Cluster` de reprise, qui saute alors son `bootstrap.recovery`**. Selon la sauvegarde, on obtient
> une base qui ne démarre pas (volume vide depuis l'exclusion kopia du 2026-09-08) ou, pire, une
> copie **cohérente-crash silencieusement substituée** à la reprise transactionnelle qu'on croyait
> faire.

### 5 — La base, par `bootstrap.recovery`

Le manifeste est **dérivé** du `Cluster` de production par
[`cnpg-barman-plugin-script.sh restore`](../script/cnpg-barman-plugin-script.sh) — jamais retapé —
puis re-ciblé sur la préprod par `jq`.

Le nom `forgejo-db` est **conservé** dans le nouveau namespace, à dessein : le Deployment restauré
cherche `forgejo-db-rw` et le Secret `forgejo-db-app`. Le garder évite de reconfigurer quoi que ce
soit, donc d'introduire une divergence entre ce qu'on teste et ce qui tourne. Ce qui rend ce choix
sûr, c'est `--no-archive` : sans `spec.plugins`, la préprod ne peut rien écrire sous le
`serverName` de la production.

> [!WARNING]
> **Aucune cible PITR par défaut, et ce n'est pas un raccourci.** `recovery_target_time` exige un
> enregistrement de **commit** dont l'horodatage soit ≥ la cible. Sans écriture depuis la
> sauvegarde de base, il n'y en a aucun :
>
> ```
> redo done at 0/2B0001D0
> FATAL:  recovery ended before configured recovery target was reached
> ```
>
> Le `Cluster` reste alors bloqué en `Setting up primary`, avec des pods `*-full-recovery` en
> `Error` qui se relancent en boucle. Le rejeu **sans** cible s'arrête au dernier état commité —
> qui est le même, s'il n'y a rien eu depuis. `TARGET_TIME=<RFC3339>` force la cible quand on sait
> qu'il y a eu des écritures.

### 6 — Neutralisations

Garde-fou 2. Appliquées en patchant le Secret `forgejo-inline-config`, qui est la source de
configuration lue par l'init-container.

⚠️ **`app.ini` n'est jamais relu à chaud** : il est composé au démarrage. C'est le
`rollout restart` qui applique les neutralisations, pas le patch.

### 7 — Exposition LAN et filtrage réseau

`HTTPRoute` sur le listener **`https-internal`** (`*.lan.wittner.tech`), jamais `https-public`.
Plus une `CiliumNetworkPolicy` qui n'autorise en sortie que le DNS et le port 5432 de sa propre
base : les neutralisations refusent la fonctionnalité, la policy refuse le paquet.

## La checklist — `verify`

C'est elle, le test. Six familles, sortie **2** si l'une échoue.

| | Contrôle | Ce que son échec signifierait |
| --- | --- | --- |
| **A** | dépôts présents sur le disque | PVC restauré vide — la donnée kopia n'a pas suivi |
| **A** | les **4 secrets** dans `app.ini` | sessions, jetons d'API et objets LFS perdus |
| **B** | `git fsck` sur chaque dépôt | dépôts présents mais corrompus |
| **B** | commits lisibles | dépôts présents mais vides |
| **C** | comptes / dépôts / issues en base | base non reconstruite |
| **C** | **dépôts disque == dépôts base** | les deux moitiés viennent d'instants différents |
| **D** | `forgejo doctor` (`check-db-consistency`, `check-db-version`, `storages`) | incohérence que ni le disque ni la base ne montrent seuls |
| **E** | les cinq neutralisations, **par section** | la copie parle au monde extérieur |
| **E** | `ROOT_URL` pointe la préprod | la copie émet des liens vers la production |
| **F** | HTTP 200 en direct sur le Gateway | la chaîne d'exposition ne va pas au bout |
| **F** | HTTP via le reverse proxy LAN | *informatif* — voir §Exposer réellement |

Le contrôle **C « disque == base »** est celui qui distingue une restauration alignée d'une
restauration bancale. Les autres vérifient chaque moitié ; celui-ci vérifie qu'elles se
rejoignent.

## Relevé du 2026-09-08

Sauvegarde `manual-bdjbd` (fin `15:50:07Z`, 1 volume), fenêtre barman
`15:02:11Z → 15:50:41Z`.

```
==> Pré-requis
  ok   sauvegarde velero : manual-bdjbd (fin 2026-09-08T15:50:07Z, 1 volume(s))
  ok   fenêtre barman     : 2026-09-08T15:02:11Z → 2026-09-08T15:50:41Z
==> 3/7 Restauration velero → forgejo-preprod
  ok   restore pra-forgejo-8qppt : Completed, 1 volume(s) réellement repris
==> 5/7 Base par bootstrap.recovery
    cluster : Setting up primary
    cluster : Waiting for the instances to become active
    cluster : Primary instance is being restarted without a switchover
    cluster : Cluster in healthy state
```

```
==> A. La donnée du PVC est revenue
  ok   2 dépôt(s) sur le disque
  ok   les 4 secrets cryptographiques sont dans app.ini
==> B. Les dépôts sont intègres
  ok   git fsck : tous les dépôts sont intègres
  ok   3 commit(s) lisibles au total
==> C. La base est revenue, et elle est d'accord avec le disque
  ok   base : comptes=2 dépôts=2 issues=0
  ok   cohérence disque/base : 2 dépôt(s) des deux côtés
==> D. Forgejo se déclare cohérent
  ok   forgejo doctor : aucune anomalie (db-consistency, db-version, storages)
==> E. La copie est muette
  ok   mailer coupé · miroirs coupés · push-mirror coupé · cron coupé
  ok   webhooks confinés en loopback · ROOT_URL pointe la préprod
  note le mot de passe SMTP est en clair dans l'app.ini de la préprod
==> F. Elle répond
  ok   HTTP 200 en direct sur le Gateway (192.168.1.80)
  note HTTP 404 via le reverse proxy LAN (192.168.1.50)
```

**Durées** — instance de 1,6 Mio, ce sont des planchers, pas des promesses :

| Étape | Durée |
| --- | --- |
| Sauvegarde velero manuelle (102 objets, 1 volume) | 17 s |
| Sauvegarde de base CNPG manuelle | 11 s |
| `Restore` velero (45 objets, 1 volume repris) | ~45 s |
| `bootstrap.recovery` → `Cluster in healthy state` | ~60 s |
| `up` de bout en bout | ~3 min |

## Exposer réellement sur le LAN

Le `HTTPRoute` posé par `up` est `Accepted` / `ResolvedRefs`, et la préprod répond **200 en
attaquant directement le Gateway** (`192.168.1.80`). Elle répond **404 par le reverse proxy**
(`192.168.1.50`).

> [!IMPORTANT]
> **Ce 404 n'est pas un défaut de la restauration.** Tout hostname `*.lan.wittner.tech` doit être
> déclaré dans le routeur Traefik de `192.168.1.50`, qui vit **hors du dépôt**. Un HTTPRoute sain
> plus un 404 par le proxy est la signature exacte de cette déclaration manquante.
>
> `verify` le signale en `note`, jamais en `KO` : l'exercice ne dépend pas d'un composant hors
> dépôt. Mais **c'est le même geste qui manquerait à une reprise réelle sur un nouveau hostname**,
> et c'est pour cela qu'il est contrôlé.

Pour ouvrir réellement `https://forgejo-preprod.lan.wittner.tech` depuis un navigateur : déclarer
le routeur côté Traefik (règle `Host(...)`, entrypoint `websecure`, `serversTransport` avec
`serverName` — le Gateway Cilium ne sert rien sans SNI), puis relancer `verify`.

Sans cette déclaration, l'accès reste possible en court-circuitant le proxy :

```bash
curl -k --resolve forgejo-preprod.lan.wittner.tech:443:192.168.1.80 \
  https://forgejo-preprod.lan.wittner.tech/
```

## Démontage

**Non optionnel.** La préprod immobilise **110 Gi** de groupe de volumes — 100 pour `forgejo-data`,
10 pour la base — et la StorageClass est en `thinProvision: "no"` : le LV est réservé en entier dès
la création, utilisé ou non.

```bash
script/forgejo-pra-script.sh down     # confirmation par frappe du nom du namespace
```

> [!WARNING]
> La StorageClass est en `reclaimPolicy: Delete` : la suppression du namespace **détruit les LV**.
> C'est voulu ici — ce sont des données de drill — et c'est exactement la mécanique qui rend
> `argocd.argoproj.io/sync-options: Prune=false,Delete=false` load-bearing sur le PVC de
> production.

`down` ne supprime que les `Restore` étiquetés `homelab.wittner.tech/drill=forgejo-pra` : une
restauration réelle en cours n'est jamais balayée.

## Table des symptômes

| Symptôme | Cause | Correctif |
| --- | --- | --- |
| `up` refuse : aucune sauvegarde dans la fenêtre | les deux chaînes ne se recouvrent pas | `velero-script.sh backup` puis `cnpg-barman-plugin-script.sh backup` |
| `Cluster` bloqué en `Setting up primary`, pods `*-full-recovery` en `Error` | cible PITR inatteignable, `recovery ended before configured recovery target was reached` | retirer `TARGET_TIME` — rejeu complet |
| Base démarrée mais **vide** ou pod qui ne démarre pas | PVC `forgejo-db-1` orphelin adopté, `bootstrap.recovery` sauté | supprimer les orphelins CNPG **avant** de créer le `Cluster` (étape 4) |
| `verify` : « aucun dépôt sur le disque » | `Restore` sans les Pods : la donnée kopia n'a pas suivi | ne pas filtrer sur `includedResources` |
| `verify` : « INCOHÉRENCE : n dépôts disque, m en base » | les deux moitiés viennent d'instants différents | choisir une sauvegarde velero dans la fenêtre, cf. [plan §1](forgejo-pra.md) |
| Pod Forgejo en `Init:CrashLoopBackOff`, `Failed to initialize ORM engine … connection refused` | la base n'est pas encore là | **attendu** — le pod repart seul, le chart le prévoit |
| Pod CNPG `Pending` indéfiniment | affinité en sens unique : la base suit Forgejo | poser le pod Forgejo **d'abord** |
| `verify` : neutralisation « NON appliqué » | `app.ini` composé au démarrage, jamais relu à chaud | `kubectl -n forgejo-preprod rollout restart deploy/forgejo` |
| HTTP 200 en direct, **404** par `192.168.1.50` | hostname non déclaré dans Traefik | hors dépôt — cf. §Exposer réellement |
| Un `HTTPRoute` de préprod capte du trafic de production | `httproutes` non exclu du `Restore` | le remettre dans `excludedResources` |

## Ce que l'exercice ne couvre pas

- **La restauration en place**, dans `forgejo`. L'exercice restaure toujours à côté ; la procédure
  en place est au [§8 du plan](forgejo-pra.md). Le geste qui manque à l'épreuve est la
  concurrence avec `selfHeal` d'ArgoCD.
- **Le RTO à volumétrie réelle.** 1,6 Mio de PVC : aucun transfert significatif n'est mesuré.
- **La reprise à froid du cluster.** Elle commence par une clé de compte de service GCP réémise à
  la main — cf. [plan §4](forgejo-pra.md), le point de reprise unique.
- **Le contenu métier.** `git fsck` prouve l'intégrité des objets, pas que le dernier commit
  poussé y est. Le contrôle « disque == base » borne l'écart, il ne le supprime pas.
