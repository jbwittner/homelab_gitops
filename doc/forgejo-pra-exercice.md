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
>   sauvegarde velero à 03:00 UTC, fenêtre barman ouverte à 15:02 UTC — aucun recouvrement) ;
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

## Ce que fait `up` — les commandes, une par une

Ce que le script enchaîne, avec la commande équivalente. C'est aussi le mode d'emploi si l'on veut
le faire **à la main** — pour comprendre, ou parce que quelque chose sort du cadre. Toutes les
commandes ci-dessous ont été jouées le 2026-09-08.

### 0 — Choisir la sauvegarde

D'abord la **fenêtre PITR** : c'est elle qui borne ce que la base sait rejouer.

```bash
kubectl -n forgejo get objectstore forgejo-db-store -o json | jq '.status.serverRecoveryWindow'
```

`firstRecoverabilityPoint` est l'instant le plus ancien atteignable, `lastSuccessfulBackupTime`
celui de la dernière sauvegarde de base. ⚠️ La fenêtre n'a pas la largeur de `retentionPolicy` :
elle démarre à la naissance de la chaîne et s'élargit une nuit à la fois.

Puis la sauvegarde velero dont l'instant de fin tombe **dedans** :

```bash
kubectl -n velero get backups.velero.io -o json | jq -r '
  [ .items[]
    | select((.spec.includedNamespaces // []) | index("forgejo"))
    | { nom: .metadata.name, phase: .status.phase, fin: .status.completionTimestamp } ]
  | sort_by(.fin) | reverse | .[0:6]'
```

Enfin, la vérification qui compte : **cette sauvegarde porte-t-elle des données ?** Sans
node-agent, une sauvegarde velero passe au vert en ne copiant que les objets Kubernetes.

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=<backup> -o json | jq -r '
  [ .items[] | { pod: .spec.pod.name, volume: .spec.volume, phase: .status.phase,
                 mio: ((.status.progress.totalBytes // 0) / 1048576 | floor) } ]'
```

### 1 — Namespace jetable

`forgejo-preprod`, étiqueté `homelab.wittner.tech/drill=forgejo-pra`. Un seul à la fois : `up`
refuse si le namespace existe déjà, sans quoi on finit par lire la mauvaise instance. Le label
n'est pas décoratif — c'est la seule chose que `down` regarde avant de supprimer.

```bash
kubectl create namespace forgejo-preprod && \
kubectl label ns forgejo-preprod homelab.wittner.tech/drill=forgejo-pra
```

### 2 — Credential GCS et `ObjectStore`

Les deux sont **recopiés** depuis `forgejo`, pas recréés. L'`ObjectStore` est une ressource
**namespacée** et le plugin n'en lit que dans le namespace du `Cluster` : il ne se mutualise pas.
Le `SealedSecret` de Git, lui, est chiffré pour le couple `(nom, forgejo)` et ne se déchiffre
nulle part ailleurs.

```bash
kubectl -n forgejo get secret forgejo-db-gcs -o json \
  | jq 'del(.status, .metadata.namespace, .metadata.uid, .metadata.resourceVersion,
            .metadata.creationTimestamp, .metadata.ownerReferences, .metadata.managedFields,
            .metadata.annotations, .metadata.labels)' \
  | kubectl -n forgejo-preprod apply -f -

kubectl -n forgejo get objectstore forgejo-db-store -o json \
  | jq 'del(.status, .metadata.namespace, .metadata.uid, .metadata.resourceVersion,
            .metadata.creationTimestamp, .metadata.generation, .metadata.ownerReferences,
            .metadata.managedFields, .metadata.annotations)' \
  | kubectl -n forgejo-preprod apply -f -
```

⚠️ Deux `del` sont load-bearing :
- `.metadata.namespace` — sans lui, `kubectl -n` est **ignoré** et l'objet repart dans `forgejo` ;
- `.metadata.annotations` — il retire `argocd.argoproj.io/tracking-id`. Copiée, ArgoCD croirait que
  l'objet appartient à l'Application `forgejo` et chercherait à le réconcilier, donc à le supprimer.

### 3 — `Restore` velero vers `forgejo-preprod`

```bash
kubectl create -f - <<'EOF'
apiVersion: velero.io/v1
kind: Restore
metadata:
  generateName: pra-manuel-
  namespace: velero
  labels:
    homelab.wittner.tech/drill: forgejo-pra
spec:
  backupName: <backup>
  includedNamespaces: [forgejo]
  namespaceMapping:
    forgejo: forgejo-preprod
  excludedResources:
    - httproutes.gateway.networking.k8s.io
    - ciliumnetworkpolicies.cilium.io
    - ciliumendpoints.cilium.io
    - clusters.postgresql.cnpg.io
    - sealedsecrets.bitnami.com
    - customresourcedefinitions.apiextensions.k8s.io
    - endpointslices.discovery.k8s.io
    - endpoints
    - leases.coordination.k8s.io
EOF
```

> [!IMPORTANT]
> **Restaurer le PVC seul ne restaure aucune donnée.** La copie est en fs-backup (kopia) : la
> donnée est attachée au **Pod**, pas au PVC. C'est le `PodVolumeRestore`, déclenché par la
> restauration du Pod, qui écrit le volume avant que les conteneurs applicatifs ne démarrent.
>
> C'est pour cela que la sauvegarde contient les Pods, et que le `Restore` ne filtre **pas** sur
> `includedResources` : un `Restore` limité à `persistentvolumeclaims` crée un PVC **vide**, sans
> un message.

Attendre, puis vérifier que des octets ont réellement été écrits — c'est ça, la preuve :

```bash
while :; do
  p="$(kubectl -n velero get restore <restore> -o jsonpath='{.status.phase}')"
  case "$p" in Completed|PartiallyFailed|Failed|FailedValidation) echo "=> $p"; break;; esac
  echo "phase=$p"; sleep 5
done
kubectl -n velero get podvolumerestores -l velero.io/restore-name=<restore> -o json \
  | jq -r '[.items[] | {pod:.spec.pod.name, volume:.spec.volume, phase:.status.phase, octets:.status.progress}]'
```

Relevé au drill : `bytesDone: 1072125` sur `totalBytes: 1072125`.

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

Le constater, puis nettoyer :

```bash
kubectl -n forgejo-preprod get pvc forgejo-db-1 -o jsonpath='{.metadata.ownerReferences}{"\n"}'   # vide

kubectl -n forgejo-preprod delete pod/forgejo-db-1 --wait=false && \
kubectl -n forgejo-preprod delete pvc/forgejo-db-1 && \
kubectl -n forgejo-preprod delete svc forgejo-db-r forgejo-db-ro forgejo-db-rw
```

### 5 — La base, par `bootstrap.recovery`

Le script **dérive** le manifeste du `Cluster` de production par
[`cnpg-barman-plugin-script.sh restore`](../script/cnpg-barman-plugin-script.sh) — jamais retapé —
puis le re-cible par `jq` :

```bash
script/cnpg-barman-plugin-script.sh restore forgejo-db --name forgejo-db-pra --no-archive 2>/dev/null \
  | jq '.metadata.namespace = "forgejo-preprod" | .metadata.name = "forgejo-db"' \
  | kubectl apply -f -
```

À la main, la forme minimale équivalente :

```bash
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: forgejo-db
  namespace: forgejo-preprod
spec:
  instances: 1
  storage:
    size: 10Gi
  monitoring:
    enablePodMonitor: false
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: forgejo-db-store
          serverName: forgejo-db
EOF
```

Trois choix portent tout le poids :

- **le nom `forgejo-db` est conservé** dans le nouveau namespace : le Deployment restauré cherche
  `forgejo-db-rw` et le Secret `forgejo-db-app`. Le garder évite de reconfigurer quoi que ce soit,
  donc d'introduire une divergence entre ce qu'on teste et ce qui tourne ;
- **il n'y a pas de `spec.plugins`** — c'est ce qui rend le point précédent sûr : sans lui la
  préprod n'archive rien, donc ne peut rien écrire sous le `serverName` de la production. Le
  sidecar barman est quand même injecté, à partir de `externalClusters[].plugin` seul ;
- **il n'y a pas de `recoveryTarget`** — voir l'encadré ci-dessous.

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

```bash
while :; do
  p="$(kubectl -n forgejo-preprod get cluster forgejo-db -o jsonpath='{.status.phase}')"
  echo "$p"
  case "$p" in "Cluster in healthy state") break;; esac
  sleep 10
done
```

Séquence attendue, ~1 min : `Setting up primary` → `Waiting for the instances to become active` →
`Primary instance is being restarted without a switchover` → `Cluster in healthy state`.

### 6 — Neutralisations

Garde-fou 2, et il y a **urgence** : le pod Forgejo repart tout seul dès que la base apparaît, avec
la configuration de production. On patche `forgejo-inline-config`, la source lue par
l'init-container.

```bash
kubectl -n forgejo-preprod patch secret forgejo-inline-config --type=merge -p "$(jq -n \
  --arg server "$(printf 'APP_DATA_PATH=/data\nDISABLE_SSH=true\nDOMAIN=forgejo-preprod.lan.wittner.tech\nENABLE_PPROF=false\nHTTP_PORT=3000\nPROTOCOL=http\nROOT_URL=https://forgejo-preprod.lan.wittner.tech/\nSSH_DOMAIN=forgejo-preprod.lan.wittner.tech\nSSH_LISTEN_PORT=2222\nSSH_PORT=22\nSTART_SSH_SERVER=false' | base64 | tr -d '\n')" \
  --arg mailer  "$(printf 'ENABLED=false' | base64 | tr -d '\n')" \
  --arg webhook "$(printf 'ALLOWED_HOST_LIST=loopback' | base64 | tr -d '\n')" \
  --arg mirror  "$(printf 'ENABLED=false\nENABLE_PUSH_MIRROR=false' | base64 | tr -d '\n')" \
  --arg cron    "$(printf 'ENABLED=false' | base64 | tr -d '\n')" \
  '{data:{server:$server, mailer:$mailer, webhook:$webhook, mirror:$mirror, cron:$cron}}')"
```

⚠️ **`app.ini` n'est jamais relu à chaud** : il est composé au démarrage. C'est le
`rollout restart` de l'étape 7 qui applique les neutralisations, pas le patch.

### 7 — Exposition LAN, filtrage réseau, redémarrage

La `CiliumNetworkPolicy` d'abord : les réglages d'`app.ini` n'agiront qu'au prochain démarrage, la
policy agit tout de suite.

```bash
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: forgejo-pra
  namespace: forgejo-preprod
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: forgejo
  ingress:
    - fromEntities: [ingress, host, remote-node]
      toPorts:
        - ports: [{ port: "3000", protocol: TCP }]
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: UDP }]
          rules:
            dns: [{ matchPattern: "*" }]
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: forgejo-preprod
            cnpg.io/cluster: forgejo-db
      toPorts:
        - ports: [{ port: "5432", protocol: TCP }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: forgejo-pra
  namespace: forgejo-preprod
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: shared-gw
      namespace: gateway
      sectionName: https-internal
  hostnames: [forgejo-preprod.lan.wittner.tech]
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - group: ""
          kind: Service
          name: forgejo-http
          port: 3000
          weight: 1
EOF

kubectl -n forgejo-preprod rollout restart deploy/forgejo && \
kubectl -n forgejo-preprod rollout status deploy/forgejo --timeout=300s
```

⚠️ Listener **`https-internal`** (`*.lan.wittner.tech`), **jamais `https-public`** : le hostname
public appartient à la production, et deux routes sur le même hostname se partagent le trafic.

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

### Les mêmes contrôles, à la main

```bash
POD=$(kubectl -n forgejo-preprod get pod -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}')
```

**A — la donnée du PVC est revenue.** Les dépôts sur le disque, et surtout les **quatre secrets
cryptographiques** : générés au premier démarrage et écrits *sur le volume*, sans eux les sessions,
les jetons d'API et les objets LFS déjà en base ne sont plus déchiffrables.

```bash
kubectl -n forgejo-preprod exec "$POD" -c forgejo -- sh -c '
  ls -d /data/git/gitea-repositories/*/*.git 2>/dev/null
  grep -cE "^(SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET|LFS_JWT_SECRET) =" /data/gitea/conf/app.ini'
```

**B — les dépôts sont intègres.** Le contrôle le plus important : la copie kopia est un parcours du
système de fichiers vivant, elle peut capturer les `refs` après leur mise à jour mais avant les
objets qu'elles désignent. `git fsck` est la seule chose qui attrape ça.

```bash
kubectl -n forgejo-preprod exec "$POD" -c forgejo -- sh -c '
  for r in /data/git/gitea-repositories/*/*.git; do
    printf "%s : " "$r"
    if git -C "$r" fsck --no-progress --no-dangling >/dev/null 2>&1; then
      echo "OK ($(git -C "$r" rev-list --all --count) commits, $(git -C "$r" for-each-ref | wc -l) refs)"
    else
      echo "CORROMPU"
    fi
  done'
```

**C — la base, et son accord avec le disque.** Le second bloc doit rendre exactement les dépôts vus
en A.

```bash
kubectl -n forgejo-preprod exec forgejo-db-1 -c postgres -- psql -U postgres -d app -c \
  'select (select count(*) from "user") as comptes, (select count(*) from repository) as depots, (select count(*) from issue) as issues;'
kubectl -n forgejo-preprod exec forgejo-db-1 -c postgres -- psql -U postgres -d app -c \
  'select owner_name, name from repository order by 1;'
```

⚠️ `-U postgres`, pas `-U app` : la connexion locale par socket passe en authentification `peer`,
et le conteneur tourne en `postgres`.

**D — Forgejo se déclare cohérent.** Attrape ce que ni le disque ni la base ne montrent seuls, par
exemple une ligne pointant un fichier absent.

```bash
kubectl -n forgejo-preprod exec "$POD" -c forgejo -- \
  gitea doctor check --run check-db-consistency,check-db-version,storages
```

⚠️ Le binaire s'appelle bien `gitea` dans l'image Forgejo — c'est historique.

**E — la copie est muette.** Lecture **section par section** : un `grep "^ENABLED = false"`
matcherait indifféremment `[mailer]`, `[mirror]` et `[cron]`, et les trois se valideraient
mutuellement.

```bash
kubectl -n forgejo-preprod exec "$POD" -c forgejo -- cat /data/gitea/conf/app.ini \
  | awk '/^\[/{s=$0} s ~ /^\[(mailer|mirror|cron|webhook|server)\]$/ && /^(ENABLED|ENABLE_PUSH_MIRROR|ALLOWED_HOST_LIST|ROOT_URL) =/ {print s, $0}'
```

Attendu, six lignes : mailer `false`, mirror `false` ×2, cron `false`, webhook `loopback`, et
`ROOT_URL` pointant la préprod.

**F — elle répond.**

```bash
curl -sk --resolve forgejo-preprod.lan.wittner.tech:443:192.168.1.80 \
  -o /dev/null -w 'gateway=%{http_code}\n' https://forgejo-preprod.lan.wittner.tech/
curl -sk --resolve forgejo-preprod.lan.wittner.tech:443:192.168.1.50 \
  -o /dev/null -w 'proxy=%{http_code}\n'   https://forgejo-preprod.lan.wittner.tech/
```

> [!TIP]
> **Le contrôle qui vaut tous les autres : se connecter à l'interface.** Il valide trois choses
> venues de trois sources différentes — le mot de passe par le hash de la **base** (barman), le
> cookie de session par le `SECRET_KEY` de l'**`app.ini`** (PVC), et la page par le `HTTPRoute`.
> Si les deux moitiés n'étaient pas cohérentes, le mot de passe passerait et la session boucherait
> indéfiniment. Aucun contrôle automatisé ne teste cela.

## Journal des exercices

**À compléter à chaque passage.** Un exercice non consigné ne prouve rien six mois plus tard : on
ne sait plus s'il a été joué, ni sur quelle volumétrie, ni jusqu'où.

### Les passages

| # | Date | Conduite | Sauvegarde consommée | Vérifications | Résultat |
| --- | --- | --- | --- | --- | --- |
| 1 | 2026-09-08 | manuelle, exploratoire | `manual-bdjbd` (15:50:07Z) | partielles — `git fsck` et `doctor` **non joués** | reprise OK, exercice interrompu avant la fin |
| 2 | 2026-09-08 | `up` + `verify` | `manual-bdjbd` | 6 familles / 6 | **OK** |
| 3 | 2026-09-08 | `drill --fresh` | `manual-fnmdv` (17:01:47Z), créée par le drill | 6 / 6 | **OK** |
| 4 | 2026-09-08 | `prepare run` + `drill` | `manual-qs7c7` (17:05:52Z) | 6 / 6 | **OK** |
| 5 | 2026-09-08 | manuelle, commande par commande | `manual-qs7c7` | 6 / 6 **+ connexion à l'interface** | **OK** |

Le passage **1** est celui qui a produit toutes les trouvailles du plan : le `FATAL` de
`recovery_target_time`, les `ownerReferences` effacées par velero, l'adoption du PVC orphelin. Les
suivants les vérifient.

Le passage **5** est le seul à avoir validé la chaîne **de bout en bout** : se connecter à
l'interface met d'accord le hash venu de la base (barman), le `SECRET_KEY` venu de l'`app.ini`
(PVC) et la route. Aucun contrôle automatisé ne fait ça.

> [!NOTE]
> `--fresh` (passage 3) a depuis été **retiré** : fabriquer sa propre condition d'exécution fait de
> l'exercice le juge de lui-même. La préparation vit maintenant dans
> [`forgejo-pra-prepare-script.sh`](../script/forgejo-pra-prepare-script.sh).

### L'instance éprouvée

Ces cinq passages ont tous tourné sur la **même** instance, quasi vide. C'est la limite de tout ce
qui précède.

| Grandeur | Valeur au 2026-09-08 |
| --- | --- |
| Comptes | 2 |
| Dépôts | 2 (`forgejo_admin/test_repo`, `jbwittner/test_repo`) |
| Issues | 0 |
| Commits, tous dépôts confondus | 3 |
| Occupation réelle de `/data` | **1,6 Mio** |
| Volume réellement copié par kopia | **1 072 125 octets** |
| PVC déclarés | 100 Gi (`forgejo-data`) + 10 Gi (base) |
| Groupe de volumes immobilisé pendant l'exercice | **110 Gi** (`thinProvision: "no"`) |
| Durée du parcours kopia | ~17 s |

### Durées mesurées

⚠️ **Des planchers, pas des promesses.** Aucun transfert significatif n'y figure : le PVC pesait
1,6 Mio. À volumétrie réelle, ce sont les temps de lecture du bucket GCS qui domineraient, et rien
ici ne les mesure.

| Étape | Durée |
| --- | --- |
| Sauvegarde velero manuelle | 15–17 s (79 à 102 objets, 1 volume) |
| Sauvegarde de base CNPG manuelle | 10–11 s |
| `Restore` velero | ~45 s (45 à 47 objets, 1 volume repris) |
| `bootstrap.recovery` → `Cluster in healthy state` | ~50–60 s |
| Redémarrage de Forgejo une fois la base là | immédiat |
| `up` de bout en bout | **~3 min** |

Le RTO **utile** — choisir la sauvegarde, vérifier la fenêtre, suspendre l'auto-sync, décider — n'a
jamais été chronométré.

### Sortie type

```
==> Pré-requis
  ok   sauvegarde velero : manual-qs7c7 (fin 2026-09-08T17:05:52Z, 1 volume(s))
  ok   fenêtre barman     : 2026-09-08T15:02:11Z → 2026-09-08T17:06:00Z
==> 3/7 Restauration velero → forgejo-preprod
  ok   restore pra-forgejo-xxxxx : Completed, 1 volume(s) réellement repris
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

## Quand le rejouer, et ce qu'on surveille entre deux

**Tous les trimestres, à la main.** Pas de cron, pas de CronJob, pas de RBAC privilégié : le
rapport valeur/effort est mauvais pour une forge mono-utilisateur, et l'automatisation coûterait
plus que le geste qu'elle remplace.

```bash
script/forgejo-pra-prepare-script.sh check   # l exercice peut-il partir ?
script/forgejo-pra-script.sh drill           # ~4 min, se démonte seul
```

### L'exercice EST la surveillance

Il n'y a rien à surveiller en continu du côté de l'étalement de la copie kopia (cf.
[plan §1](forgejo-pra.md)). Aucune métrique ne le voit : une copie étalée produit une sauvegarde
`Completed`, de taille normale, à l'heure. **Le seul détecteur est le `git fsck` de la checklist**,
et il ne parle qu'au moment où on le lance.

D'où la règle : on ne surveille pas le problème, **on rejoue l'exercice**.

### Les signaux qui font passer de « trimestriel » à « maintenant »

Relevés au 2026-09-08, avec la valeur du jour comme point de comparaison.

| Signal | Où le lire | Valeur actuelle | Seuil |
| --- | --- | --- | --- |
| Durée du parcours kopia | `startTimestamp` → `completionTimestamp` du `Backup` velero | **12 à 22 s** | au-delà de ~2 min |
| Occupation réelle du volume | `kubectl -n forgejo exec deploy/forgejo -c forgejo -- du -sh /data` | **1,6 Mio** | au-delà de ~1 Gio |
| `[cron.git_gc_repos]` | défaut amont, absent d'`app.ini` | **désactivé** | s'il passe à `true` — seul cron qui réécrit des `.pack` |
| Nombre d'utilisateurs | — | **1** | dès qu'un second pousse la nuit |
| Un `drill` qui sort en **2** sur `git fsck` | la checklist elle-même | jamais arrivé | **jamais toléré** — le symptôme est déjà là |

La durée du parcours est le signal le plus direct : **c'est exactement la fenêtre d'exposition**.
Une écriture qui ne la croise pas ne peut rien casser.

> [!NOTE]
> **Activer `renovate-forgejo` n'est PAS un déclencheur, et l'améliore même.** Sa `schedule` est
> `0 1 * * *` en **`Europe/Paris`** — soit 23:00 UTC l'été et 00:00 UTC l'hiver, donc 2 h à 3 h
> avant la copie velero de 03:00 UTC, pour ~40 s de run. Il écrirait dans la forge chaque nuit,
> donc du WAL serait produit et archivé : la fenêtre PITR cesserait d'être figée entre deux
> sauvegardes de base, et `--target-time` redeviendrait utilisable (cf.
> [plan §1](forgejo-pra.md), régime « forge écrite »).
>
> ⚠️ **Les deux chaînes de sauvegarde sont en UTC, les CronJobs renovate en heure locale.** Elles
> se décalent donc l'une par rapport à l'autre d'une heure au changement d'heure. La marge la plus
> étroite est 1 h, en hiver. Le déclencheur serait de replanifier renovate de façon à tomber sur
> 03:00 UTC — cf. [plan §2](forgejo-pra.md).

### Ce qu'on a décidé de ne pas faire

| | Pourquoi pas |
| --- | --- |
| Couper Forgejo pendant la copie | tranché au [plan §1](forgejo-pra.md) : les hooks velero ne savent pas scaler un Deployment, et l'orchestrateur externe qu'il faudrait peut laisser la forge à 0 replica |
| Snapshot CSI | **mesuré fermé** — `snapshot … is not of thin type` sur une StorageClass épaisse |
| Migrer la StorageClass en thin | chantier de stockage, à arbitrer pour lui-même et pas comme correctif de sauvegarde |
| Mettre le `drill` en cron | image, RBAC privilégié, et un CronJob qui teste la reprise du cluster depuis le cluster |

**Décision au 2026-09-08 : on reste ainsi.** Le risque résiduel est une écriture qui croise 17
secondes, sur une forge à un seul utilisateur. Il est connu, borné, et détecté par l'exercice.

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

À la main :

```bash
kubectl delete ns forgejo-preprod --wait=false && \
kubectl -n velero delete restore -l homelab.wittner.tech/drill=forgejo-pra
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
