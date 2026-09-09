# PRA Forgejo — plan de reprise

## Rôle

Remonter [`forgejo`](../cluster/app/forgejo/README.md) après un sinistre : quoi restaurer, dans
quel ordre, à quel instant, et avec quoi commencer quand il ne reste rien.

Cette page est le **plan**. L'[exercice](forgejo-pra-exercice.md) en est l'épreuve — un plan jamais
joué n'est pas un plan, c'est une intention. Tous les chiffres et tous les messages d'erreur d'ici
sont **relevés lors des cinq exercices du 2026-09-08**, pas supposés ; le détail de chaque passage
est dans le [journal](forgejo-pra-exercice.md#journal-des-exercices). Ce qui n'a **pas** été éprouvé
est signalé comme tel — et il en reste.

Ce document ne remplace ni [`velero-script.sh`](../script/velero-script.sh) ni
[`cnpg-barman-plugin-script.sh`](../script/cnpg-barman-plugin-script.sh) : chacun sait conduire sa
chaîne. Ici on traite ce qu'aucun des deux ne sait — **les faire converger**.

---

## 1. Les deux moitiés

**La forge a deux domaines de données, deux chaînes de sauvegarde, et aucune ne couvre ce que
couvre l'autre.**

| Donnée | Chaîne | Cohérence | Heure | Rétention |
| --- | --- | --- | --- | --- |
| PVC `forgejo-data` — dépôts Git, LFS, paquets, artefacts Actions, **`app.ini`** | velero / kopia | **étalée** — pire que crash, cf. ci-dessous | **03:00 UTC** | 30 j (`ttl: 720h`) |
| Base `forgejo-db` — issues, PR, comptes, sessions, droits | barman-cloud (CNPG natif) | **transaction** + PITR | **02:00 UTC** + WAL continu | 30 j (`retentionPolicy`) |

### Les deux sont « à chaud », et ce n'est pas le même « à chaud »

Les deux chaînes copient sans arrêter quoi que ce soit. La ressemblance s'arrête là, et c'est
l'écart qui justifie d'avoir deux chaînes plutôt qu'une.

| | CNPG / barman-cloud | velero / kopia |
| --- | --- | --- |
| Mécanisme | `pg_backup_start()` … `pg_backup_stop()` | **parcours du système de fichiers vivant** |
| Quiescing applicatif | oui | **aucun** — ni `hooks` sur la schedule, ni annotation `pre.hook.backup.velero.io` sur le pod |
| Snapshot bloc | non, et inutile | non — `snapshotVolumes: false`, et **aucune `VolumeSnapshotClass` n'est déclarée** |
| Marqueurs vérifiables | `online: true`, `beginWal → endWal`, `beginLSN → endLSN` | aucun |
| Résultat | **cohérent-transaction** | **fichiers lus à des instants différents** |

La copie barman du répertoire de données est *floue* — les fichiers bougent pendant la copie — mais
les WAL produits pendant la fenêtre sont rejoués à la restauration et la rendent cohérente. Relevé
sur `forgejo-db-manual-pljw7` : `online: true`, `beginLSN 0/2E000028 → endLSN 0/2E000158`.

> [!WARNING]
> **La copie du PVC est ÉTALÉE, ce qui est pire que cohérent-crash.** Un crash donne un instantané
> *unique* de tout le volume. Un parcours de système de fichiers donne le fichier A lu à t₀ et le
> fichier B à t₀+5 min : il n'existe aucun instant du monde réel où le volume a ressemblé à sa
> copie.
>
> Ce que cela peut produire sur cette forge :
> - **`git push` en vol pendant le parcours** : les `refs` copiées après leur mise à jour mais
>   avant les objets qu'elles désignent → référence pendante. `git fsck` l'attrape — c'est pour
>   cela qu'il est dans la checklist de l'[exercice](forgejo-pra-exercice.md), et pas par acquit
>   de conscience ;
> - **téléversement LFS ou paquet en cours** : ligne en base pointant un fichier absent.
>   `forgejo doctor --run storages` en attrape une partie ;
> - **index bleve** incohérent — reconstructible, non critique ;
> - `app.ini` est écrit une fois et stable : il ne court pas ce risque.
>
> **Ce que le drill ne prouve pas :** `git fsck` est passé le 2026-09-08, mais sur une forge **au
> repos**. Cela valide le mécanisme, pas le comportement sous charge d'écriture — le mode de panne
> ne se manifeste que si une écriture croise le parcours.
>
> **Le correctif structurel est FERMÉ, et ce n'est pas faute d'avoir essayé.** L'idée est bonne :
> un snapshot LVM est atomique, velero téléverserait depuis lui et l'étalement disparaîtrait. Le
> chemin a été câblé et mesuré le 2026-09-08 — il ne marche pas sur cette StorageClass.
>
> Le snapshot d'un LV **épais** se crée (`readyToUse: true` en moins de dix secondes,
> `snapSize` honoré à 20 %), mais en provisionner un volume est refusé :
>
> ```
> ProvisioningFailed: rpc error: code = InvalidArgument
> desc = snapshot snapshot-2041e0f8-… is not of thin type
> ```
>
> `lvm-localpv` n'accepte comme `dataSource` que des snapshots **thin**. Et le data mover de velero
> fait exactement cela : snapshot, puis PVC temporaire provisionné depuis le snapshot pour le
> téléverser. La seconde étape échoue. La `VolumeSnapshotClass` a donc été retirée plutôt que
> laissée en place — elle n'aurait produit que des snapshots verts et non restaurables.
>
> **Rouvrir ce chemin exige `thinProvision: "yes"`**, qui ne convertit pas les volumes existants :
> seconde StorageClass et migration volume par volume. Ce n'est plus un réglage, c'est un chantier.
>
> Les hooks velero, eux, ne servent à rien ici : Forgejo n'a pas de commande de gel.
>
> **Conclusion opérationnelle : l'étalement reste, et la détection reste le `git fsck` de
> l'[exercice](forgejo-pra-exercice.md).** C'est ce qui rend ce contrôle load-bearing plutôt que
> décoratif.

### Faut-il couper Forgejo pendant la copie ? Non

La question revient naturellement, et la réponse est non — mais pas pour la raison qu'on croit.
« Il n'y a qu'un utilisateur » ne suffit pas : ce qui compte est **qui écrit à 03:00 UTC**, humain ou
non. État vérifié le 2026-09-08 :

| Écrivain potentiel | Horaire | État réel |
| --- | --- | --- |
| `renovate-forgejo` — pousse des branches dans la forge | `0 1 * * *` **Europe/Paris** → 23:00 UTC l'été, 00:00 UTC l'hiver | **pas déployé** (ligne commentée dans `cluster/app/renovate/manifests/kustomization.yaml`). Une fois activé : 2 h de marge l'été, 1 h l'hiver, pour ~40 s de run |
| `renovate-github` | `0 2 * * *` **Europe/Paris** → 00:00 UTC l'été, 01:00 UTC l'hiver | actif, mais il pousse sur **GitHub**, pas ici |
| Crons internes de Forgejo | défauts amont | la section `[cron*]` d'`app.ini` est **vide** |
| L'humain | — | le seul écrivain réaliste à 03:00 UTC |

Et le parcours kopia dure **12 à 22 s** sur la volumétrie actuelle.

⚠️ La marge la plus étroite est **1 h, en hiver**, entre `renovate-github` (01:00 UTC) et la
sauvegarde de base (02:00 UTC). C'est elle qu'il faut regarder avant de toucher à un horaire.

Parmi les crons internes, ceux qui tournent la nuit **suppriment** des fichiers
(`cleanup_packages`, `archive_cleanup`) : une suppression qui croise le parcours donne un fichier
de cache présent ou absent, pas un dépôt corrompu. Le seul qui **réécrit des `.pack`** — donc le
seul réellement dangereux — est `git_gc_repos`, désactivé par défaut en amont.

> [!NOTE]
> C'est la seule donnée de cette section **non vérifiée dans le cluster** : Forgejo ne journalise
> pas l'enregistrement de ses tâches cron, et la valeur n'apparaît pas dans `app.ini` puisqu'elle
> est au défaut. L'affirmation repose sur le défaut amont, pas sur une mesure.

**Pourquoi couper serait pire que le mal :**

- interruption toutes les nuits, d'une durée qui croît avec le volume — exactement ce qu'on
  cherche à éviter sur 100Gi ;
- **les hooks velero ne savent pas le faire** : ils exécutent une commande *dans* le conteneur, ils
  ne peuvent pas passer un Deployment à 0. Il faudrait un orchestrateur externe (scale down →
  Backup → scale up) ;
- cet orchestrateur peut échouer **entre** les deux étapes et laisser Forgejo à 0 replica jusqu'à
  ce que quelqu'un s'en aperçoive. C'est un mode de panne pire que celui qu'il corrige.

**Les trois déclencheurs qui changeraient la réponse** — et dans les trois cas le correctif reste
le snapshot CSI, pas la coupure :

1. `renovate-forgejo` activé **et** replanifié de façon à tomber sur 03:00 UTC ;
2. `[cron.git_gc_repos] ENABLED = true` ;
3. la forge grossit assez pour que le parcours dure des minutes, auquel cas le risque devient la
   fenêtre 02:00–03:00 où renovate écrit.

### Et elles ne sont pas cohérentes entre elles

> [!CAUTION]
> **Les deux moitiés ne sont jamais cohérentes entre elles.** Le contenu d'un dépôt vit sur le
> PVC, la ligne qui le décrit vit en base. Prendre la base de 02:00 avec le PVC de 03:00 donne une
> heure de dépôts présents sur le disque et **absents de l'interface** — ou l'inverse pour ce qui a
> été supprimé entre les deux.

### La règle d'alignement

**Le PVC ne se déplace pas dans le temps.** Il n'existe qu'aux instants où kopia a copié. La base,
si — c'est tout l'objet du PITR. L'alignement se fait donc **toujours dans le même sens** : on
amène la base **à** l'instant du PVC, jamais l'inverse.

```
                02:00              03:00
base    ──●━━━━━━━━━━━━━━━━━━━━━━━━━▶ (rejeu WAL)
          └ sauvegarde de base       ▲
                                     │  cible = completionTimestamp du Backup velero
PVC     ─────────────────────────────●
                                       └ copie kopia (instant figé, non déplaçable)
```

> [!WARNING]
> **La cible n'est pas toujours atteignable, et l'échec est brutal.** Relevé au drill :
>
> ```
> redo done at 0/2B0001D0
> FATAL:  recovery ended before configured recovery target was reached
> ```
>
> `recovery_target_time` exige un **enregistrement de commit** dont l'horodatage soit ≥ la cible.
> Sur une base sans écriture entre la sauvegarde de base et la cible, il n'y en a aucun :
> PostgreSQL **échoue** au lieu de s'arrêter à l'état le plus proche, et le `Cluster` reste bloqué
> en `Setting up primary` avec des pods `full-recovery` en `Error` qui se relancent en boucle.
>
> **Conduite à tenir :**
>
> | Situation | Cible |
> | --- | --- |
> | La forge a été écrite entre la sauvegarde de base et l'instant du PVC | `--target-time <completionTimestamp>` |
> | Elle ne l'a pas été (cas courant sur cette instance) | **aucune cible** — rejeu complet |
>
> Sans cible, le rejeu va aussi loin que l'archive le permet et s'arrête au dernier état commité.
> S'il n'y a eu aucune écriture depuis l'instant du PVC, **c'est le même état** — l'alignement est
> obtenu sans la cible. Le `FATAL` ci-dessus est donc le signal « il n'y avait rien à rejouer »,
> pas une sauvegarde cassée.
>
> ⚠️ **Mais sans cible, on ne choisit pas où l'on atterrit.** barman reprend la **dernière**
> sauvegarde de base du bucket, puis rejoue tout le WAL disponible. Relevé au drill manuel du
> 2026-09-08 :
>
> ```
> 17:05:52  ← copie velero du PVC
> 17:05:56  sauvegarde de base    ┐ pg_backup_start
> 17:06:00  terminée              ┘ pg_backup_stop → bascule de WAL forcée
>              ▲ c'est CELLE-CI que barman a reprise
> ```
>
> La base restaurée était donc à 17:06:00 et le PVC à 17:05:52 : **la base était 8 secondes en
> AVANCE sur le disque** — le mauvais sens (§2). Rien n'a cassé parce que rien n'avait été écrit
> entre les deux, mais l'alignement venait de l'absence d'écritures, pas de la procédure.
>
> Les deux régimes sont complémentaires, et c'est ce qui rend l'ensemble tenable : le cas où la
> cible est nécessaire est exactement celui où elle est atteignable.
>
> | Forge | `--target-time` | Alignement |
> | --- | --- | --- |
> | **au repos** | impossible (`FATAL` — aucun commit à atteindre) | **gratuit**, rien n'a bougé |
> | **écrite** | nécessaire, et il **fonctionne** (des commits existent) | obtenu par la cible |

---

## 2. Pourquoi la base à 02:00 UTC et le PVC à 03:00 UTC

> [!IMPORTANT]
> **Tous les horaires de ce document sont en UTC**, et ils ne peuvent pas être autre chose : ni
> `Schedule` (velero) ni `ScheduledBackup` (CNPG) n'exposent de champ `timezone`. Seul un `CronJob`
> Kubernetes en a un — d'où le `Europe/Paris` des CronJobs renovate, qui sont les **seuls** objets
> du dépôt en heure locale.
>
> | | Été (CEST) | Hiver (CET) |
> | --- | --- | --- |
> | base CNPG · 02:00 UTC | 04:00 Paris | 03:00 Paris |
> | PVC velero · 03:00 UTC | 05:00 Paris | 04:00 Paris |
>
> ⚠️ **Ne pas « corriger » en décalant d'une heure.** Un cron UTC fixe ne peut viser une heure
> locale qu'à une saison, et le décalage créerait une **collision** : `renovate-github` tourne à
> 02:00 Europe/Paris, soit 01:00 UTC en hiver. Détail dans les deux fichiers de schedule.

L'ordre n'est pas un hasard d'ordonnancement. **La sauvegarde de base doit précéder la copie du
PVC, et le plus près possible.** Trois raisons indépendantes, toutes dans ce sens :

1. **Longueur du rejeu.** Pour atteindre 03:00, il faut une sauvegarde de base ≤ 03:00 : celle de
   02:00, **la même nuit**, plus une heure de WAL. Inversé (PVC 02:00, base 03:00), il faudrait la
   base de **la veille 03:00** — 23 heures de rejeu, et 23 heures de segments WAL dont chacun doit
   être intact.

2. **Le mode de panne quand on n'aligne pas.** Un dépôt poussé à 02:30 :

   | Ordre | Ce qu'on obtient sans PITR | Conséquence |
   | --- | --- | --- |
   | **actuel** (base 02:00, PVC 03:00) | dépôt **sur le disque**, absent de la base | inerte, ré-adoptable |
   | inversé (PVC 02:00, base 03:00) | dépôt **en base**, absent du disque | page de dépôt en 500, ligne à supprimer à la main |

   Du disque en avance sur la base se rattrape. De la base en avance sur le disque casse.

3. **Contention d'E/S.** Documentée dans `forgejo-db-scheduledbackup.yaml` : velero lit le PVC de
   100Gi à 03:00 UTC, sur le **même nœud** et le même stockage node-local que la base. L'heure d'écart
   n'est pas décorative.

---

## 3. RPO — mesuré, pas promis

| Chaîne | RPO nominal | RPO réel | Écart |
| --- | --- | --- | --- |
| PVC `forgejo-data` | 24 h | **24 h** | une copie par nuit, pas de journal |
| Base `forgejo-db` | 5 min | **5 min sous activité, jusqu'à 24 h au repos** | ci-dessous |

> [!WARNING]
> **`archive_timeout = 300` ne veut pas dire « un WAL toutes les 5 minutes ».** PostgreSQL ne
> force un changement de segment sur ce délai **que s'il y a eu de l'activité WAL** depuis le
> précédent. Une base au repos n'archive **rien**, indéfiniment — relevé **144 221 s, soit 40
> heures**, sur `forgejo-db` en bonne santé.

### Ce que ça change sur une perte totale

Le WAL **n'est pas dans le cluster** : `barman-cloud-wal-archive` pousse chaque segment dans le
bucket GCS au fil de l'eau, à côté des sauvegardes de base. Perdre le cluster ne perd rien de la
chaîne barman.

Ce qui est perdu, c'est le **segment courant, non encore archivé**. Et un segment ne part que
lorsqu'il est plein, ou lorsqu'un basculement est forcé — ce qui n'arrive qu'avec de l'activité, ou
au `pg_backup_stop` de la sauvegarde de base.

**Scénario concret :** écritures à 23:00, puis forge au repos. Le segment qui les porte n'est
archivé qu'au basculement forcé de **02:00**. Entre 23:00 et 02:00, ces écritures n'existent que
sur le PVC — détruit avec le cluster.

> **RPO de la base sur perte totale = la dernière sauvegarde de base, pas 5 minutes.**

C'est aussi pourquoi la surveillance porte sur le **backlog** (`CNPGWalArchivingBacklog`) et non
sur l'âge du dernier archivage — cf. [cnpg-monitoring](../cluster/app/cnpg-monitoring/README.md).

### RTO

**Non mesuré à volumétrie réelle, et c'est le point.** Les durées relevées lors des cinq exercices
du 2026-09-08 sont consignées dans le
[journal de l'exercice](forgejo-pra-exercice.md#journal-des-exercices), avec l'état de l'instance
sur laquelle elles ont été prises — **1,6 Mio, 2 dépôts, 2 comptes**. Repère : `up` de bout en bout
tourne en **~3 min**.

> [!IMPORTANT]
> **Ce sont des planchers, pas des promesses.** Elles ne contiennent aucun transfert réel. À
> volumétrie de production, ce sont les temps de lecture du bucket GCS qui dominent, et rien ici ne
> les mesure. Le RTO **utile** est celui du temps de décision — choisir la sauvegarde, vérifier la
> fenêtre, suspendre l'auto-sync — qui n'a jamais été chronométré non plus.

---

## 4. Le point de reprise unique

> [!CAUTION]
> **Tout le PRA passe par la clé maître de sealed-secrets, et elle n'est dans aucune sauvegarde du
> cluster.**
>
> Le credential que velero utilise pour lire son bucket (`velero-gcs`) est un `SealedSecret` de Git
> (`cluster/infra/velero/manifests/velero-gcs.sealed.yaml`). Un contrôleur sealed-secrets qui
> démarre sans sa clé en génère une **neuve** — et alors :
>
> ```
> pas de clé → velero-gcs reste chiffré → velero ne lit pas son bucket → aucune restauration
>            → donc pas de Secret matérialisé → donc pas de forgejo-db-gcs
>            → donc pas de lecture du bucket barman non plus
> ```
>
> **La clé est sauvegardée hors ligne, dans un gestionnaire de secrets.** C'est ce qui rend la
> reprise possible, et c'est la même posture que les parts de descellement d'openbao au coffre
> physique : les deux seuls points du homelab dont la reprise ne se lit pas *dans* le homelab.

### Le geste, dans l'ordre

```bash
# 1. cluster + contrôleur sealed-secrets déployés
kubectl -n sealed-secrets apply -f sealed-secrets-key-bleu-kalecgos.yaml
# ⚠️ SANS ce label, le contrôleur IGNORE la clé — sans erreur, sans trace :
#      sealedsecrets.bitnami.com/sealed-secrets-key: active
kubectl -n sealed-secrets rollout restart deploy/sealed-secrets

# 2. ArgoCD déchiffre les SealedSecret du dépôt, dont velero-gcs
# 3. velero lit son bucket → les étapes A et B deviennent possibles
```

Piège d'ordre : si le contrôleur démarre **avant** la restauration, il crée une clé neuve et la
marque `active`. Ce n'est pas bloquant — il déchiffre avec n'importe quelle clé présente — mais il
faut quand même poser l'ancienne **et** redémarrer.

### Ce qui rend cette sauvegarde suffisante, et qui pourrait cesser de l'être

Par défaut, le contrôleur **fait tourner sa clé tous les 30 jours** : l'ancienne continue de
déchiffrer, mais la nouvelle devient celle du chiffrement. Toute sauvegarde hors ligne antérieure à
une rotation devient alors partielle — et **rien ne le signale**, puisqu'en fonctionnement normal
le contrôleur détient toutes ses clés. L'écart n'apparaîtrait qu'ici, en reprise, sous la forme
d'un `no key could decrypt secret` sur les scellés récents et sur eux seuls.

C'est pourquoi la rotation est **coupée** (`keyrenewperiod: "0"`, cf.
[`sealed-secrets`](../cluster/infra/sealed-secrets/README.md)) : une clé, une sauvegarde, pas de
dérive silencieuse. Contrôle, qui doit rendre **une seule ligne** :

```bash
kubectl get secrets -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --sort-by=.metadata.creationTimestamp
```

⚠️ Plusieurs lignes = la rotation a repris, et la sauvegarde hors ligne n'est plus suffisante.

---

## 5. Ce que les sauvegardes contiennent

### Ce que velero emporte, et qui change tout

Relevé sur `velero-daily-20260908030037` (namespace `forgejo`, 102 objets) :

| Type | Nb | Ce qui compte |
| --- | --- | --- |
| `v1/Secret` | 10 | `forgejo-admin`, `forgejo-secrets`, `forgejo-smtp`, `forgejo-db-app`, `forgejo-db-ca`, `forgejo-db-server`, `forgejo-db-replication`, `forgejo-init`, `forgejo-inline-config`, `forgejo` |
| `v1/Pod` | 2 | **porteurs de la donnée fs-backup** — cf. §7 piège 1 |
| `v1/PersistentVolumeClaim` | 2 | `forgejo-data`, `forgejo-db-1` |
| `postgresql.cnpg.io/v1/Cluster` | 1 | de quoi **recréer** la base ; le natif la **remplit** |
| `gateway.networking.k8s.io/v1/HTTPRoute` | 1 | ⚠️ porte le hostname **public** — cf. §7 piège 2 |
| `bitnami.com/v1alpha1/SealedSecret` | 3 | inutilisables si la clé du contrôleur a changé |

> [!IMPORTANT]
> **Les `Secret` sont sauvegardés matérialisés — c'est ce qui rend une reprise possible, et c'est
> aussi une propriété de sécurité du bucket.** Deux conséquences opposées :
> - **En reprise, on ne dépend pas de sealed-secrets.** Un contrôleur réinstallé à neuf ne
>   déchiffre plus les trois `SealedSecret` de Git, et le pod resterait en
>   `CreateContainerConfigError`. Les `Secret` de la sauvegarde velero ferment ce trou.
> - **Le bucket velero est un magasin de secrets.** Accès IAM, pas de copie locale qui traîne, pas
>   de partage.

### Le PVC de la base n'est plus copié par kopia

Depuis le 2026-09-08, `volume-policies.yaml` exclut les PVC CNPG de la copie kopia. **Vérifié :**
la sauvegarde de 03:00 (avant la règle) portait **2 volumes** (`data` 1 Mio + `pgdata` 535 Mio) ; la
sauvegarde manuelle de 15:50 (après) n'en porte plus qu'**un**.

Conséquence pour la reprise : il n'existe **plus** de second chemin, même dégradé, vers les données
de la base. Une sauvegarde antérieure au 2026-09-08 03:00 en contient encore une copie
cohérente-crash — ce n'est pas le chemin nominal, mais c'est un filet qui expire avec sa rétention
de 30 jours, soit **le 2026-10-08**.

### Ce que rien ne contient

- **`forgejo-db-gcs`** — le credential du bucket barman. **Absent de la sauvegarde du 2026-09-08
  03:00** (vérifié : créé le même jour vers 14:51, après le passage de velero). Les suivantes le
  contiennent. Une reprise depuis une sauvegarde antérieure ne pourra pas lire le bucket barman
  sans réémettre une clé.
- **Les couplages hors dépôt** (§8) : routeur Traefik, tunnel Cloudflare, DNS.
- **Une lifecycle rule GCS posée par erreur** sur l'un des deux buckets. Les deux outils font leur
  propre GC ; aucune métrique du cluster ne verrait un bucket purgé sous eux.

---

## 6. Les scénarios

| # | Sinistre | Perdu | Restauré | Ordre |
| --- | --- | --- | --- | --- |
| **A** | Base corrompue ou supprimée, PVC intact | métadonnées | base seule, `bootstrap.recovery` | §8 étape B |
| **B** | PVC perdu, base intacte | dépôts, LFS, paquets, `app.ini` | PVC seul, velero | §8 étape A |
| **C** | Nœud `vert-ysondre` perdu | **les deux** — ils y sont co-localisés | les deux | §8, dans l'ordre |
| **D** | Cluster entier perdu | tout | §4 d'abord, puis les deux | §8, après bootstrap |
| **E** | Erreur humaine (dépôt supprimé, force-push) | un objet précis | PITR ciblé avant l'erreur | §8, `--target-time` |

> [!NOTE]
> **Le scénario C est le scénario nominal, pas le pire.** La base et l'applicatif sont
> **volontairement** contraints sur le même nœud : le stockage est node-local et non répliqué,
> réunir les deux volumes borne la casse à une machine au lieu de deux. Perdre le nœud, c'est donc
> perdre les deux volumes **par construction** — arbitrage assumé, documenté dans
> [`forgejo/README.md`](../cluster/app/forgejo/README.md) §Placement.

> [!NOTE]
> **Le scénario B est aujourd'hui couvert, et il ne l'a pas toujours été.** Les quatre secrets
> cryptographiques (`SECRET_KEY`, `INTERNAL_TOKEN`, `OAUTH2_JWT_SECRET`, `LFS_JWT_SECRET`) sont
> normalement générés au premier démarrage et écrits **sur le volume**, dans
> `/data/gitea/conf/app.ini` — perdre le PVC en gardant la base rendrait alors les sessions, les
> jetons d'API et les objets LFS déjà en base **indéchiffrables**.
>
> Le câblage `additionalConfigFromEnvs` de `helm-values.yaml` les sort du volume vers le
> `SealedSecret` `forgejo-secrets`, **et il est actif** : vérifié le 2026-09-08, le Secret existe
> avec ses quatre clés, et l'`app.ini` du pod restauré au drill les portait toutes les quatre.
>
> ⚠️ Le câblage est `optional: true` sur les quatre `secretKeyRef` : s'il venait à disparaître, le
> pod démarrerait **sans erreur** et le scénario B redeviendrait destructeur en silence. Contrôle :
> `kubectl -n forgejo get secret forgejo-secrets -o json | jq '.data | keys'` doit rendre quatre
> clés.

---

## 7. Les sept pièges

Chacun produit une restauration qui **passe au vert** et qui est fausse.

### 1. Restaurer le PVC seul ne restaure aucune donnée

La copie de volume est en **fs-backup (kopia)**. La donnée n'est pas attachée au PVC mais au
**Pod** : c'est le `PodVolumeRestore`, déclenché par la restauration du Pod, qui écrit dans le
volume avant que les conteneurs applicatifs ne démarrent. C'est pour cela que les deux Pods sont
dans la sauvegarde (§5).

**Vérifié au drill** : le `PodVolumeRestore` du pod `forgejo-747bd9b9f9-qnr5x` a rendu
`bytesDone: 1072125` sur `totalBytes: 1072125`, et les deux dépôts sont réapparus sur le disque. Un
`Restore` limité à `persistentvolumeclaims` aurait créé un PVC **vide**, sans un message.

### 2. Le `HTTPRoute` de la sauvegarde porte le hostname public

Il est dans le périmètre, avec `hostnames: [forgejo.wittner.tech]` et `sectionName: https-public`.
Le restaurer dans un **autre** namespace pose une seconde route sur le même hostname et le même
listener : le trafic de production se répartit entre deux backends, dont un de test.

⚠️ **Toute restauration vers un namespace autre que `forgejo` doit exclure
`httproutes.gateway.networking.k8s.io`.**

### 3. `velero` efface les `ownerReferences`

**Vérifié au drill** : les objets CNPG restaurés (`pod/forgejo-db-1`, `pvc/forgejo-db-1`,
`svc/forgejo-db-{r,ro,rw}`) reviennent **sans owner**. Ils ne sont donc jamais ramassés par le
garbage collector, et le pod orphelin démarre : il était en `1/2 Running`.

Le danger n'est pas le bruit, c'est le PVC : **un `forgejo-db-1` déjà présent est adopté par le
`Cluster` de reprise, et le `bootstrap.recovery` n'a pas lieu**. Comme le volume restauré est vide
depuis l'exclusion kopia (§5), on obtient une base qui ne démarre pas — ou, si la sauvegarde est
antérieure à l'exclusion, une base **cohérente-crash silencieusement substituée** à la reprise
transactionnelle qu'on croyait faire.

⚠️ **Supprimer `pod/forgejo-db-1`, `pvc/forgejo-db-1` et les trois Services `forgejo-db-*` AVANT
de créer le `Cluster` de reprise.**

### 4. `--target-time` échoue au lieu de dégrader

Voir §1. Sur une base sans commit après la cible : `FATAL: recovery ended before configured
recovery target was reached`, et le `Cluster` ne sort jamais de `Setting up primary`. Ce n'est pas
une sauvegarde cassée — c'est une cible inatteignable. Rejouer sans cible.

### 5. Un cluster restauré qui archive écrase sa propre source

`serverName` vaut le nom du `Cluster` quand il est omis. Un `Cluster` de reprise renommé pour
prendre la place de l'original archive ses WAL **par-dessus** ceux dont il vient.

`cnpg-barman-plugin-script.sh restore` écrit toujours un `serverName` explicite **des deux côtés**.

> **Bonne nouvelle vérifiée au drill :** `--no-archive` (qui supprime `spec.plugins`) **n'empêche
> pas la reprise**. Le sidecar `plugin-barman-cloud` est injecté dans le pod de recovery à partir
> de `externalClusters[].plugin` seul — l'init-container était présent et sorti en `exit 0`. Un
> clone de validation peut donc être totalement muet côté bucket.

### 6. `passwordMode: keepUpdated` réaligne le mot de passe admin à chaque démarrage

Sur la production c'est voulu — le `SealedSecret` est la source de vérité. Sur une instance de
reprise, cela veut dire que le mot de passe admin est celui du **Secret restauré**, pas celui qu'on
croit avoir noté.

### 7. Une copie de la forge parle au monde extérieur

Une instance restaurée démarre avec la configuration de production : mailer Brevo **actif**,
webhooks autorisés vers `external`, miroirs de dépôts. **Vérifié au drill** : le pod est reparti
tout seul dès l'apparition de la base, avec `ROOT_URL: https://forgejo.wittner.tech/` et le mailer
armé — le mot de passe SMTP est en clair dans l'`app.ini` du pod, injecté par
`additionalConfigFromEnvs`.

Neutralisations dans l'[exercice](forgejo-pra-exercice.md) §Garde-fous. Non optionnelles.

---

## 8. Procédure de reprise

> [!IMPORTANT]
> **L'ordre n'est pas commutatif, et l'inversion ne produit pas une erreur mais une attente
> indéfinie.** L'affinité du `Cluster` CNPG est en **sens unique** : la base suit Forgejo. Un pod
> CNPG posé avant que le pod Forgejo n'existe reste `Pending`, sans message.
>
> **Forgejo d'abord (avec son PVC), la base ensuite.**
>
> **Vérifié au drill** : le pod Forgejo restauré a bouclé en `Init:CrashLoopBackOff` sur
> `Failed to initialize ORM engine: [...] connection refused` pendant toute la reprise de la base,
> puis est reparti seul. C'est le comportement prévu par le chart, pas une panne.

### Étape 0 — choisir l'instant

```bash
script/velero-script.sh list                          # sauvegardes du PVC
script/cnpg-barman-plugin-script.sh list              # fenêtre PITR de la base
kubectl -n velero get backups.velero.io <backup> -o jsonpath='{.status.completionTimestamp}{"\n"}'
```

Vérifier que cet instant tombe dans la fenêtre affichée par `cnpg-barman-plugin-script.sh list`
(colonnes `DEBUT-FENETRE` → `DERNIER-BACKUP`).

> [!WARNING]
> **Les deux chaînes ne se recouvrent pas forcément.** Relevé le 2026-09-08 : la sauvegarde velero
> de 03:00 est **antérieure** au `firstRecoverabilityPoint` de barman (15:02), la chaîne native
> ayant été montée dans la journée. Aucun alignement n'était possible avec elle.
>
> Et même dans la fenêtre, il faut qu'un WAL ait été archivé **après** l'instant du PVC — sur une
> base au repos, ce n'est le cas qu'à la sauvegarde de base suivante. Une reprise alignée n'est
> donc réellement disponible **qu'au lendemain matin**. Pour la forcer tout de suite :
>
> ```bash
> script/cnpg-barman-plugin-script.sh backup     # pg_backup_stop force un basculement de WAL
> ```

### Étape N — perte du namespace entier

> [!IMPORTANT]
> **Jouée le 2026-09-09 : `kubectl delete namespace forgejo`, les deux volumes détruits avec.**
> Reprise complète en **7 min 14 s** (crash 12:36:23 → forge à 200 en 12:43:37), données identiques
> à l'empreinte. Ce scénario n'était PAS jouable le matin même : il a fallu le `bootstrap.recovery`
> permanent, le correctif IAM `storage.buckets.get` et les deux chaînes éprouvées séparément.
>
> **L'ORDRE EST TOUT, et il n'est pas celui des étapes A puis B.** Le namespace vide est le cas
> FACILE pour velero (celui du drill), donc on restaure d'abord et on répare ensuite.

```bash
# 1. Couper ArgoCD sur les TROIS niveaux (cf. étape A, piège d) — forgejo-monitoring compris.
for a in root app forgejo forgejo-monitoring; do
  kubectl -n argocd patch application $a --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# 2. Bumper les DEUX serverName, et SEULEMENT MAINTENANT — cf. encadre ci-dessous.
#    Committer, POUSSER, puis ATTENDRE qu ArgoCD ait vu la revision.

# 3. Restaurer velero. Il recree le Namespace lui-meme : rien a creer a la main.
script/velero-script.sh restore <backup> -n forgejo

# 4. ⚠️ PURGER LES ORPHELINS CNPG — piege n°3, observe en direct le 2026-09-09.
#    velero restaure l OBJET PVC forgejo-db-1 (10 Gi, VIDE : volume-policies exclut les volumes
#    CloudNativePG) et le Cluster tel qu il etait. CNPG adopte ce volume vide et demarre dessus,
#    donc bootstrap.recovery N A JAMAIS LIEU. Le pod part en CrashLoopBackOff — visible ici, mais
#    il aurait pu donner une base d apparence saine et vide.
kubectl -n forgejo delete cluster forgejo-db          # emporte le pod et le PVC
kubectl -n forgejo delete svc forgejo-db-r forgejo-db-ro forgejo-db-rw --ignore-not-found

# 5. Rendre la main a ArgoCD : il recree le Cluster depuis Git, en bootstrap.recovery.
#    Controle : le pod doit s appeler <cluster>-1-full-recovery-*, JAMAIS -1-initdb-*.

# 6. Sauvegarde de base IMMEDIATE sur la nouvelle generation, puis redemarrer la forge.
script/cnpg-barman-plugin-script.sh backup
kubectl -n forgejo delete pod -l app.kubernetes.io/name=forgejo
```

> [!WARNING]
> **Ce que la perte du namespace fait disparaître, et qui n'est pas la donnée.**
>
> **L'inventaire local, en entier.** Juste après le crash, `cnpg-barman-plugin-script.sh list`
> affiche « (aucune) » partout — bases, sauvegardes, schedules. C'est le corollaire du piège n°4 :
> le catalogue vit dans Kubernetes, les données vivent dans le bucket. Rien dans le cluster ne peut
> confirmer que les sauvegardes existent encore ; **la reprise est la seule preuve**. C'est
> exactement la situation d'un vrai sinistre, et le moment où l'on est le plus tenté de conclure au
> pire.
>
> **Les fenêtres des générations ANTÉRIEURES.** L'`ObjectStore` recréé ne publie dans
> `status.serverRecoveryWindow` que ce que le cluster courant archive — après la reprise du
> 2026-09-09, seule `forgejo-db-v4` y figurait, alors que `forgejo-db` et `-v3` sont toujours dans
> le bucket. Leurs données restent restaurables en nommant explicitement le `serverName` dans
> `externalClusters`, mais **plus aucun inventaire local ne dit qu'elles existent**. Seul
> `gcloud storage ls` le dirait. C'est un argument de poids contre les bumps de génération
> gratuits : chacun dégrade l'inventaire.

> [!CAUTION]
> **Le bump de `serverName` se fait APRÈS la destruction, jamais avant.** Appliqué à un cluster
> vivant, il le fait archiver immédiatement sous la nouvelle génération, qui cesse d'être vide — et
> la reprise échoue ensuite sur « Expected empty archive ». C'est le sort de `forgejo-db-v2` le
> 2026-09-09, brûlé par un `initdb` accidentel de quelques minutes.

### Étape A — le PVC et l'applicatif (scénarios B, C, D)

> [!CAUTION]
> **Jouée en place pour la première fois le 2026-09-09, sur la production.** Elle a fini par
> réussir, mais **pas telle qu'elle était écrite** : la version d'origine de cette procédure
> échouait, et de deux façons qui rendaient toutes deux un `Restore` d'apparence saine avec un PVC
> vide. Ce qui suit est la version corrigée, éprouvée. L'[exercice](forgejo-pra-exercice.md)
> restaure dans un namespace **vide**, où aucun de ces quatre pièges n'existe : le cas facile
> masque le mécanisme.
>
> **Piège α — `existingResourcePolicy` non renseigné saute les objets déjà présents.** C'est ici
> **voulu, et il ne faut PAS le corriger avec `--overwrite`.** Services, Secrets et ConfigMaps du
> namespace sont gérés par ArgoCD : leur source de vérité est Git, pas la sauvegarde. Le restore du
> 2026-09-09 a produit **55 avertissements `already exists`**, tous corrects. Ce qu'on vient
> chercher dans la sauvegarde, c'est le PVC et le Pod porteur de la donnée — et ceux-là sont
> absents, donc créés.
>
> **Piège β — `--overwrite` défait l'étape « libérer la place ».** `existingResourcePolicy=update`
> réécrit le Deployment avec celui de la sauvegarde, **`replicas: 1` compris**. Le ReplicaSet
> recrée aussitôt un pod, qui prend le PVC neuf (RWO) et démarre Forgejo **sur un volume vide** —
> observé le 2026-09-09 : 16 fichiers et 392 Kio au lieu de 97 fichiers et 1,6 Mio, et
> `gitea-repositories` absent. L'étape 4 annulait l'étape 2.
>
> **Piège γ — `scale --replicas=0` ne suffit pas : il DÉTRUIT la restauration.** Le Pod restauré
> par velero porte une `ownerReference` vers son ReplicaSet d'origine. Ce RS est à `desired=0`
> puisque le Deployment l'est : le contrôleur de ReplicaSet voit un pod qu'il possède et n'en veut
> aucun, donc **il le supprime dans la seconde**. Le `PodVolumeRestore` attend alors un pod que
> Kubernetes vient de détruire, et le `Restore` reste `InProgress` indéfiniment — 18 min observées
> avant abandon. La parade est de **supprimer le Deployment ET ses ReplicaSets**, ce qui reproduit
> en place les conditions du namespace vide. L'ordre de velero le permet : il restaure le Pod
> (item 26/70) **avant** le ReplicaSet (item 31/70), donc le pod naît sans propriétaire, puis le RS
> restauré à `desired=1` l'adopte.
>
> **Piège δ — couper `selfHeal` sur l'Application `forgejo` seule ne coupe rien.** La chaîne
> app-of-apps est `root` → `app` → `forgejo` : le parent réapplique le manifeste de l'enfant depuis
> Git en quelques secondes, `automated` revient, et avec lui le `replicas: 1`. Vérifié le
> 2026-09-09 — un pod était déjà reparti 20 s après le `scale --replicas=0`. Il faut couper les
> **trois**, de haut en bas.

```bash
# 0. Prendre l empreinte de ce qu on va detruire. Sans elle, une restauration verte ne prouve rien.
P=$(kubectl -n forgejo get pod -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}')
kubectl -n forgejo exec $P -c forgejo -- sh -c 'find /data -type f | wc -l; du -sh /data'
kubectl -n forgejo exec $P -c forgejo -- find /data/git/gitea-repositories -maxdepth 2 -name '*.git'
kubectl -n forgejo exec $P -c forgejo -- sha256sum /data/jwt/private.pem /data/gitea/conf/app.ini

# 1. Couper ArgoCD sur les TROIS niveaux, de haut en bas — cf. piege d.
#    Couper le seul « forgejo » ne tient pas : le parent le repose en quelques secondes.
for a in root app forgejo; do
  kubectl -n argocd patch application $a --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# 2. Reproduire les conditions du namespace vide — cf. piege g.
#    SUPPRIMER le Deployment et ses ReplicaSets, et non les mettre a zero : un RS a desired=0
#    supprime le Pod restaure avant que node-agent ait ecrit le moindre octet.
kubectl -n forgejo delete deploy/forgejo
kubectl -n forgejo delete rs --all

# 3. IRREVERSIBLE. reclaimPolicy: Delete -> la suppression du PVC DETRUIT le LV.
#    A ne faire que si le volume est deja perdu ou corrompu.
kubectl -n forgejo delete pvc forgejo-data

# 4. Restaurer. Pas de namespaceMapping : on revient chez soi.
#    SANS --overwrite — cf. pieges a et b. Les « already exists » attendus sont le comportement voulu.
script/velero-script.sh restore <backup> -n forgejo

# 5. Attendre que les octets soient ecrits — c est la preuve, pas la phase du Restore.
kubectl -n velero get podvolumerestores -l velero.io/restore-name=<restore> \
  -o custom-columns=POD:.spec.pod.name,PHASE:.status.phase,BYTES:.status.progress.bytesDone

# 6. Rendre la main a ArgoCD. Il adopte le Deployment restaure sans rolling update tant que le
#    hash de template correspond a Git ; le Pod restaure est alors conserve tel quel.
for a in root app forgejo; do
  kubectl -n argocd patch application $a --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done

# 7. Confronter a l empreinte du point 0. Les sommes doivent etre IDENTIQUES ; le nombre de
#    fichiers gagne exactement 1, le marqueur /data/.velero/<uid> ecrit par la restauration.
```

Point de contrôle : le **nombre de volumes réellement repris**. Une restauration `Completed` avec
**zéro** volume signifie objets restaurés, **données absentes**.

> [!WARNING]
> **Une restauration velero ESTAMPILLE les objets qu'elle touche, et ArgoCD ne le voit pas.**
> Chaque objet restauré reçoit `velero.io/backup-name` et `velero.io/restore-name`. Avec
> `--overwrite`, ce sont **tous** les objets existants qui sont marqués — 24 relevés dans `forgejo`
> le 2026-09-09, dont la plupart pointaient une restauration **ratée puis supprimée**. Ces labels
> appartenant au field manager de velero, `ServerSideApply` les rend invisibles au diff d'ArgoCD,
> qui reste `Synced` : rien ne les signale et rien ne les nettoie.
>
> Sans effet fonctionnel, mais ils **fuient dans les manifestes dérivés** — `cnpg-barman-plugin-script.sh
> restore` lit le `Cluster` vivant, donc son manifeste les embarquait. Les retirer avant de committer,
> et purger après un exercice :
>
> ```bash
> kubectl -n forgejo label <objet> velero.io/backup-name- velero.io/restore-name-
> ```

**Mesuré le 2026-09-09**, sur 1,6 Mio : `PodVolumeRestore` en **9 s** (1 072 125 / 1 072 125 octets),
`Restore` complet en **3 min 40 s** dont l'essentiel en `Finalizing`, 55 avertissements, 0 erreur.
Les trois sommes de contrôle et les deux dépôts sont revenus identiques, `git fsck` propre, et la
base connaissait les **mêmes** deux dépôts que le disque. Ce chiffre ne dit **rien** du RTO à
volumétrie réelle : à 1,6 Mio, la copie kopia est du bruit devant les temps fixes.

> [!WARNING]
> **Si un `Restore` reste bloqué, ne pas forcer la suppression de ses finalizers.** Retirer
> `restores.velero.io/external-resources-finalizer` et `velero.io/pod-volume-finalizer` à la main a
> laissé le contrôleur de restore **muet** : le `Restore` suivant est resté sans phase, sans une
> ligne de log, pendant plus de deux minutes. Il a fallu un `kubectl -n velero rollout restart
> deployment/velero` pour qu'il reprenne. Redémarrer le serveur AVANT d'en arriver aux finalizers.

### Étape B — la base (scénario A)

> [!IMPORTANT]
> **Jouée en place le 2026-09-09. La reprise se fait SOUS LE NOM D'ORIGINE, par Git.**
> `forgejo-db.yaml` porte désormais un bloc `bootstrap.recovery` permanent : supprimer le `Cluster`
> suffit, ArgoCD le recrée depuis le bucket, et `forgejo-db-rw` / `forgejo-db-app` ne changent
> jamais — donc `helm-values.yaml` n'a **rien** à suivre. Vérifié : après reprise complète,
> `HOST = forgejo-db-rw:5432` était inchangé.
>
> `bootstrap` n'étant lu qu'à la création, le bloc est inerte sur un cluster vivant. Ce n'est pas
> un résidu : c'est la procédure, écrite à l'avance.
>
> **Ce qui porte les générations, c'est le `serverName`**, explicite des deux côtés — lecture dans
> `externalClusters`, écriture dans `plugins`. Le bump d'écriture est LOAD-BEARING : sans lui, le
> cluster repris archiverait par-dessus les WAL de sa source et détruirait la sauvegarde dont il
> vient. C'est la seule raison pour laquelle `cnpg-barman-plugin-script.sh restore` REFUSE de
> générer un manifeste homonyme — il ne peut pas garantir ce bump.
>
> ⚠️ **La cible du bump doit n'avoir JAMAIS servi.** barman refuse de démarrer sur un prefix non
> vide : « WAL archive check failed for server `<nom>`: Expected empty archive ». Un `serverName`
> touché ne serait-ce qu'une fois est brûlé définitivement. Le 2026-09-09, `forgejo-db-v2` a été
> consommé par un `initdb` accidentel de quelques minutes, d'où le saut direct à `v3`.

**La variante « à côté » reste utile, et devrait être jouée régulièrement.** Un `Cluster` de
validation créé sous un autre nom avec `--no-archive` ne perturbe rien et n'écrit pas une ligne
dans le bucket — il prouve seulement, mais réellement, que le bucket rend une base démarrable avec
les bonnes données. Joué le 2026-09-09 : 2 users et 2 dépôts, identiques à la production.

```bash
script/cnpg-barman-plugin-script.sh restore forgejo-db --name forgejo-db-check --no-archive \
  > /tmp/check.json
# ⚠️ Retirer les labels velero.io/* que le manifeste herite du Cluster vivant (cf. encadre ci-dessous).
kubectl apply -f /tmp/check.json     # puis vérifier, puis : kubectl -n forgejo delete cluster forgejo-db-check
```

#### La reprise réelle, en place

```bash
# 1. Couper ArgoCD sur les TROIS niveaux (cf. étape A, piège d).
for a in root app forgejo; do
  kubectl -n argocd patch application $a --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done

# 2. Bumper les DEUX serverName dans cluster/app/forgejo/manifests/forgejo-db.yaml :
#    ecriture (plugins)          -> une generation JAMAIS UTILISEE
#    lecture  (externalClusters) -> la generation qui porte les sauvegardes
#    Committer ET POUSSER.

# 3. ⚠️ ATTENDRE qu ArgoCD ait vu la nouvelle revision AVANT de detruire quoi que ce soit.
#    Une sync forcee juste apres un push utilise la revision EN CACHE — c est ce qui a produit
#    un initdb sur une base vide le 2026-09-09.
kubectl -n argocd patch application forgejo --type=merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n argocd get app forgejo -o jsonpath='{.status.sync.revisions}'   # doit contenir le SHA pousse

# 4. Retablir ArgoCD, puis detruire. IRREVERSIBLE : le PVC de la base part avec.
for a in root app forgejo; do
  kubectl -n argocd patch application $a --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done
kubectl -n forgejo delete cluster forgejo-db

# 5. ArgoCD recree le Cluster en bootstrap.recovery. Controle : le pod doit s appeler
#    <cluster>-1-full-recovery-*, et NON <cluster>-1-initdb-*.
kubectl -n forgejo get pods | grep -E "full-recovery|initdb"

# 6. ⚠️ Si le Job de reprise echoue et qu on corrige la spec, SUPPRIMER LE JOB : le template d un
#    Job est IMMUABLE, ses pods de retry rejouent l ancienne valeur indefiniment.
kubectl -n forgejo delete job forgejo-db-1-full-recovery

# 7. ⚠️ SAUVEGARDE DE BASE IMMEDIATE. La nouvelle generation n a aucun point de reprise tant
#    qu elle n en a pas une : sa fenetre PITR est vide.
script/cnpg-barman-plugin-script.sh backup

# 8. Redemarrer Forgejo : le secret forgejo-db-app a ete regenere, le pod porte l ancien.
#    Symptome sinon : /api/healthz rend 424 indefiniment.
kubectl -n forgejo delete pod -l app.kubernetes.io/name=forgejo
```

Après reprise, les deux générations coexistent dans l'ObjectStore et l'ancienne reste restaurable :

```
forgejo-db     2026-09-08T15:02:11Z → 2026-09-09T10:44:44Z
forgejo-db-v3  2026-09-09T11:34:32Z → 2026-09-09T11:34:32Z
```

#### L'ancienne procédure, et pourquoi elle est abandonnée

```bash
# Si l étape A a précédé : nettoyer les orphelins CNPG qu elle a restaurés (piège 3),
# SINON le PVC forgejo-db-1 est adopté et le bootstrap.recovery n a pas lieu.
kubectl -n forgejo delete pod/forgejo-db-1 pvc/forgejo-db-1 --ignore-not-found
kubectl -n forgejo delete svc forgejo-db-r forgejo-db-ro forgejo-db-rw --ignore-not-found

script/cnpg-barman-plugin-script.sh restore forgejo-db --name forgejo-db-restore \
  > /tmp/forgejo-db-restore.json
```

La commande **imprime un manifeste** et n'applique rien : une restauration CNPG est un `Cluster`
neuf en `bootstrap.recovery`, donc un **état désiré**, donc du Git. Le manifeste est dérivé de ce
qu'ArgoCD déclare réellement (lu dans `.metadata.managedFields`), pas du `.spec` défauté servi par
l'API. Redirigée, la sortie ne contient **que** le manifeste ; le récapitulatif part sur stderr.

Ajouter `--target-time <completionTimestamp>` **seulement** si la forge a été écrite après la
sauvegarde de base (§1).

Puis, et les deux gestes sont indissociables :

1. committer le manifeste sous `cluster/app/forgejo/manifests/`, l'ajouter au `kustomization.yaml` ;
2. faire suivre dans `helm-values.yaml` : `gitea.config.database.HOST` (`<nouveau>-rw:5432`) **et**
   le `secretKeyRef` de `FORGEJO__DATABASE__PASSWD` (`<nouveau>-app`).

⚠️ Sans le second, Forgejo continue de parler à la base d'origine — celle qu'on vient de remplacer
— **sans rien signaler**.

C'est précisément ce double geste que la reprise sous le nom d'origine supprime. Le nom dérivait
aussi à chaque sinistre (`-restore`, puis `-restore-restore`), et surtout : cette procédure aurait
**échoué en vrai**. Elle crée un `serverName` neuf, donc elle butait sur le 403
`storage.buckets.get` corrigé le 2026-09-09 — un défaut qu'aucune sauvegarde courante ne pouvait
révéler, puisqu'il n'existait que sur le chemin de reprise.

### Étape C — vérifier

La checklist de l'[exercice](forgejo-pra-exercice.md) §Vérifications vaut telle quelle, jouée sur
le hostname public.

---

## 9. Points de couplage hors cluster

Rien n'est sauvegardé, et chacun casse en silence :

| Couplage | Où | Symptôme s'il manque |
| --- | --- | --- |
| Routeur Traefik `192.168.1.50` | LXC, hors dépôt | **404**, malgré un HTTPRoute `Accepted` |
| `serversTransport` avec SNI | idem | le Gateway Cilium ne trouve aucun listener |
| Tunnel Cloudflare + `originRequest.originServerName` | Cloudflare | idem, depuis Internet |
| Enregistrement DNS **Proxied** | Cloudflare | un Tunnel en DNS-only ne crée pas un chemin direct : il **tue** le nom |
| Bucket GCS + compte de service | dépôt Terraform | archivage WAL en échec, `CNPGWalArchivingBacklog` |

**Vérifié au drill**, sur `forgejo-preprod.lan.wittner.tech` : `200` en attaquant directement le
Gateway (`192.168.1.80`), `404` par le reverse proxy (`192.168.1.50`), pour un `HTTPRoute` par
ailleurs `Accepted`/`ResolvedRefs`. C'est la signature exacte d'un hostname non déclaré dans
Traefik.

> [!WARNING]
> **Depuis le LAN, le DNS interne renvoie `192.168.1.50` pour tout `*.wittner.tech`.** Un test
> local ne prouve donc **rien** sur le chemin externe.

---

## 10. Ce que ce plan ne couvre pas

- **La reprise du cluster lui-même** (scénario D, avant l'étape A) : Talos, ArgoCD, sealed-secrets,
  cert-manager, cilium. Un autre plan, qui n'existe pas encore. Le §4 en est le premier geste — et
  ce geste n'a **jamais été joué** : la restauration de la clé maître sur un cluster neuf n'est pas
  éprouvée, contrairement à la restauration des données, qui l'est à chaque exercice.
- **Le RTO à volumétrie réelle.** Les durées du §3 ont été relevées sur 1,6 Mio de données.
- **La perte simultanée des deux buckets GCS.** Distincts, GC séparés — mais même projet, même
  compte.
- ~~**La restauration EN PLACE, dans `forgejo`**~~ — **jouée le 2026-09-09 sur la production**,
  PVC détruit puis repris depuis le bucket, empreintes identiques et base alignée sur le disque
  (§8 étape A). L'exercice, lui, restaure toujours à côté : c'est le cas facile, et il a masqué
  quatre pièges que seule la reprise en place révèle. Deux d'entre eux tenaient à des gestes
  **écrits dans ce plan** — `--overwrite`, et `scale --replicas=0` — qui produisaient un `Restore`
  vert sur un volume vide. Les pièges déduits du mécanisme n'étaient pas les bons ; la procédure du
  §8 est désormais celle qui a réellement fonctionné. Reste non éprouvée : la reprise en place
  **à volumétrie réelle**, et l'étape B en place (répétable sans risque, et qui devrait l'être).
- **Le comportement sous charge d'écriture.** `git fsck` et `forgejo doctor` sont joués à chaque
  exercice et passent — mais sur une forge au repos. L'étalement de la copie kopia (§1) ne se
  manifeste que si une écriture croise le parcours, et rien ici ne le provoque.
- **Le chemin CSI snapshot**, qui supprimerait cet étalement : **mesuré fermé** le 2026-09-08
  (`snapshot … is not of thin type`). Le rouvrir demande de migrer la StorageClass en thin, ce qui
  est un chantier de stockage, pas un réglage de sauvegarde.

---

## 11. Le coût de ce plan, et les alternatives

**Ce plan est disproportionné, et c'est assumé.** Au 2026-09-08 : **2 852 lignes** de script et de
documentation pour **2 dépôts, 2 comptes, 1,6 Mio** de données. À relire avant d'ajouter quoi que
ce soit ici.

D'où vient cette complexité : le composant a **deux chaînes** parce que les PVC CNPG ont été sortis
du périmètre kopia le 2026-09-08 au profit de barman-cloud
([`volume-policies.yaml`](../cluster/infra/velero/manifests/volume-policies.yaml)). Bon arbitrage à
volumétrie réelle — cohérent-transaction plutôt que cohérent-crash — mais c'est lui qui impose tout
le reste : deux instants à aligner, une fenêtre PITR à recouvrir, un script de préparation.

> [!NOTE]
> **Un dépôt Git est déjà répliqué par construction.** Chaque `git clone` est une copie complète,
> historique inclus. Ce qui n'est répliqué nulle part, c'est : les issues, les PR, les comptes, et
> les quatre secrets d'`app.ini`. La partie réellement irremplaçable de cette forge pèse quelques
> kilo-octets.

| | Option | Complexité | Ce qu'on perd |
| --- | --- | --- | --- |
| **A** | **Statu quo** — deux chaînes | ●●●● | rien |
| **B** | Une seule chaîne : PVC CNPG remis dans kopia, barman supprimé | ●● | PITR, cohérence-transaction |
| **C** | `forgejo dump` nocturne vers le bucket | ●● | PITR, et la restauration est **manuelle** |
| **D** | Miroirs push des dépôts vers une forge tierce | ● | ne couvre **que** les dépôts |

- **B** annule la décision du 2026-09-08 : un outil, un instant, plus d'alignement ni de script de
  préparation — environ 60 % de la complexité en moins. La base repart en cohérence-crash, et
  PostgreSQL rejoue son WAL au démarrage. Ce qu'on perd vraiment est le PITR : sur deux dépôts, il
  ne sert qu'à rattraper une issue supprimée.
- **C** ⚠️ **il n'existe pas de `forgejo restore`** : on décompresse, on recharge la base à la
  main, on recopie les répertoires. Simple à produire, pas à remonter. Et cela n'allège qu'à
  condition de supprimer les autres chaînes en même temps.
- **D** quasi gratuit, hors cluster et hors GCP. Ne remplace rien, mais couvre hors site la partie
  qu'on regretterait vraiment. Meilleur rapport valeur/effort de la liste.

**Décision au 2026-09-08 : rester en A.** Ce qui existe fonctionne et est éprouvé ; le démonter
coûterait plus que le garder. Mais **ne rien ajouter** — ni drill en cron, ni migration de la
StorageClass en thin, ni snapshot CSI. Et si la complexité finit par gêner, le levier est le
**design** (passer en B), pas les scripts ni cette page.
