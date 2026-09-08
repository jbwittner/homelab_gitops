# PRA Forgejo — plan de reprise

## Rôle

Remonter [`forgejo`](../cluster/app/forgejo/README.md) après un sinistre : quoi restaurer, dans
quel ordre, et à quel instant. Cette page est le **plan**. L'[exercice](forgejo-pra-exercice.md)
en est l'épreuve — un plan jamais joué n'est pas un plan, c'est une intention.

Ce que ce document n'est pas : un mode d'emploi de velero ou de barman-cloud. Les deux outils ont
leurs scripts ([`velero-script.sh`](../script/velero-script.sh),
[`cnpg-barman-plugin-script.sh`](../script/cnpg-barman-plugin-script.sh)) et leurs README. Ici on
traite ce qu'aucun des deux ne sait : **les faire converger sur le même instant**.

---

## 1. La seule chose à comprendre avant de restaurer

**La forge a deux domaines de données, deux chaînes de sauvegarde, et aucune des deux ne couvre ce
que couvre l'autre.**

| Donnée | Chaîne | Cohérence | Heure | Rétention |
| --- | --- | --- | --- | --- |
| PVC `forgejo-data` — dépôts Git, LFS, paquets, artefacts Actions, **`app.ini`** | velero / kopia | **crash** | 03:00 | 30 j (`ttl: 720h`) |
| Base `forgejo-db` — issues, PR, comptes, sessions, droits | barman-cloud (CNPG natif) | **transaction** + PITR | 02:00 + WAL continu | 30 j (`retentionPolicy`) |

> [!CAUTION]
> **Les deux moitiés ne sont jamais cohérentes entre elles.** Le contenu d'un dépôt vit sur le
> PVC, la ligne qui le décrit vit en base. Restaurer la sauvegarde de base de 02:00 avec le PVC de
> 03:00 donne une heure de dépôts présents sur le disque et **absents de l'interface** — ou
> l'inverse pour ce qui a été supprimé entre les deux.
>
> **C'est le PITR qui résout ça, et c'est la règle centrale de ce plan :**
>
> > **La cible de restauration de la base est l'heure de fin de la sauvegarde velero retenue.**
>
> Le PVC ne se déplace pas dans le temps — il n'existe qu'aux instants où kopia a copié. La base,
> si : on l'amène **à** l'instant du PVC, jamais l'inverse.

---

## 2. RPO — mesuré, pas promis

| Chaîne | RPO nominal | RPO réel | Pourquoi l'écart |
| --- | --- | --- | --- |
| PVC `forgejo-data` | 24 h | **24 h** | une seule copie par nuit, pas de journal |
| Base `forgejo-db` | 5 min | **5 min *sous activité*, jusqu'à 24 h au repos** | voir ci-dessous |

> [!WARNING]
> **`archive_timeout = 300` ne veut pas dire « un WAL toutes les 5 minutes ».** PostgreSQL ne
> force un changement de segment sur ce délai **que s'il y a eu de l'activité WAL** depuis le
> précédent. Une base au repos n'archive **rien**, indéfiniment — relevé **144 221 s, soit 40
> heures**, sur `forgejo-db` en bonne santé.
>
> Conséquence directe sur le RPO : sur une forge peu écrite, le dernier point restaurable n'est
> pas « il y a 5 minutes » mais **la dernière sauvegarde de base**, à 02:00. C'est aussi la raison
> pour laquelle la surveillance porte sur le **backlog** (`CNPGWalArchivingBacklog`) et non sur
> l'âge du dernier archivage — cf.
> [cnpg-monitoring](../cluster/app/cnpg-monitoring/README.md).

**RPO combiné du composant : 24 h.** Il est borné par la chaîne la plus lente, et la règle du §1
aligne de toute façon la base sur elle.

**RTO : non mesuré.** C'est l'objet de l'[exercice](forgejo-pra-exercice.md), dont le tableau de
relevé est à remplir à chaque passage.

---

## 3. Ce que les sauvegardes contiennent — et ce qu'elles ne contiennent pas

### Ce que velero emporte, et qui change tout

La sauvegarde velero du namespace `forgejo` ne contient pas que le volume. Relevé sur
`velero-daily-20260908030037` :

| Type | Nombre | Ce qui compte |
| --- | --- | --- |
| `v1/Secret` | 10 | `forgejo-admin`, `forgejo-secrets`, `forgejo-smtp`, `forgejo-db-app`, `forgejo-db-ca`, `forgejo-db-server`, `forgejo-db-replication`, `forgejo-init`, `forgejo-inline-config`, `forgejo` |
| `v1/Pod` | 2 | **porteurs de la donnée fs-backup** — cf. §5 |
| `v1/PersistentVolumeClaim` | 2 | `forgejo-data`, `forgejo-db-1` |
| `postgresql.cnpg.io/v1/Cluster` | 1 | de quoi **recréer** la base (le natif la **remplit**) |
| `gateway.networking.k8s.io/v1/HTTPRoute` | 1 | ⚠️ porte le hostname **public** — cf. §5 |
| `bitnami.com/v1alpha1/SealedSecret` | 3 | inutilisables si la clé du contrôleur a changé |

> [!IMPORTANT]
> **Les `Secret` sont sauvegardés en clair — c'est ce qui rend une reprise possible, et c'est
> aussi une propriété de sécurité du bucket.**
>
> Deux conséquences opposées, toutes deux load-bearing :
> - **En reprise, on ne dépend pas de sealed-secrets.** Un `sealed-secrets` réinstallé à neuf ne
>   sait plus déchiffrer les trois `SealedSecret` de Git — le pod resterait en
>   `CreateContainerConfigError`. Les `Secret` **matérialisés** de la sauvegarde velero ferment ce
>   trou : ce sont eux qu'on restaure.
> - **Le bucket velero est un magasin de secrets.** Il se traite comme tel : accès IAM, pas de
>   copie locale qui traîne, pas de partage.

### Ce que rien ne contient

- **`forgejo-db-gcs`** — le credential GCS de la chaîne barman. **Absent de la sauvegarde du
  2026-09-08 03:00**, vérifié : il a été créé le même jour vers 14:51, après le passage de velero.
  Les sauvegardes suivantes le contiennent. ⚠️ Une reprise depuis une sauvegarde antérieure au
  2026-09-08 après-midi ne trouvera pas ce Secret et **ne pourra pas lire le bucket barman** sans
  réémettre une clé de compte de service.
- **Les couplages hors dépôt** (§7) : routeur Traefik, tunnel Cloudflare, DNS. Rien de tout cela
  n'est dans un bucket.
- **Une lifecycle rule GCS posée par erreur** sur l'un des deux buckets. Les deux outils font leur
  propre GC ; aucune métrique du cluster ne verrait un bucket purgé sous eux.

---

## 4. Les scénarios

| # | Sinistre | Ce qui est perdu | Ce qu'on restaure | Ordre |
| --- | --- | --- | --- | --- |
| **A** | Base corrompue ou supprimée, PVC intact | métadonnées | base seule, par `bootstrap.recovery` | § 6.B |
| **B** | PVC perdu, base intacte | dépôts, LFS, paquets, **`app.ini`** | PVC seul, par velero | § 6.A |
| **C** | Nœud `vert-ysondre` perdu | **les deux** (les volumes y sont co-localisés) | les deux | § 6, dans l'ordre |
| **D** | Cluster entier perdu | tout | bootstrap ArgoCD, puis les deux | § 6, après bootstrap |
| **E** | Erreur humaine (dépôt supprimé, force-push) | un objet précis | **PITR ciblé** avant l'erreur | § 6, `--target-time` |

> [!CAUTION]
> **Le scénario B n'est pas « une instance dégradée ».** Au premier démarrage, l'init-container
> écrit quatre secrets — `security.SECRET_KEY`, `security.INTERNAL_TOKEN`, `oauth2.JWT_SECRET`,
> `server.LFS_JWT_SECRET` — dans `/data/gitea/conf/app.ini`, **sur le volume**. Repartir d'un PVC
> vide en gardant la base ne donne pas une forge amputée de ses dépôts : elle donne une forge dont
> **les sessions, les jetons d'API et les objets LFS déjà en base ne sont plus déchiffrables**.
>
> Le câblage `additionalConfigFromEnvs` de `helm-values.yaml` sort ces quatre valeurs du volume
> vers un `SealedSecret` (`forgejo-secrets`) — et c'est précisément à quoi il sert. ⚠️ Il est
> **inerte tant que ce Secret n'est pas scellé** (`optional: true` sur les quatre `secretKeyRef`),
> et le scellement doit reprendre les valeurs **déjà présentes dans l'`app.ini` du volume**, pas
> des valeurs neuves. Tant que ce geste n'est pas fait, le scénario B reste destructeur.
> Procédure : [`forgejo/README.md`](../cluster/app/forgejo/README.md) §Sceller les secrets
> cryptographiques.

> [!NOTE]
> **Le scénario C est le scénario nominal, pas le pire.** La base et l'applicatif sont
> **volontairement contraints sur le même nœud** (`affinity.additionalPodAffinity` du `Cluster`) :
> le stockage est node-local et non répliqué, réunir les deux volumes borne la casse à une seule
> machine au lieu de deux. Perdre le nœud, c'est donc perdre les deux volumes **par
> construction** — c'est l'arbitrage assumé, documenté dans
> [`forgejo/README.md`](../cluster/app/forgejo/README.md) §Placement.

---

## 5. Les cinq pièges

Chacun produit une restauration qui **passe au vert** et qui est fausse.

### 1. Restaurer le PVC seul ne restaure pas les données

La copie de volume velero est en mode **fs-backup (kopia)**. La donnée n'est pas attachée au PVC
mais au **Pod** : c'est le `PodVolumeRestore`, déclenché par la restauration du Pod, qui écrit dans
le volume avant que les conteneurs applicatifs ne démarrent.

C'est pour cette raison que les deux Pods sont dans la sauvegarde (§3). Un `Restore` limité à
`persistentvolumeclaims` crée un PVC **vide**, sans un message d'erreur.

### 2. Le `HTTPRoute` de la sauvegarde porte le hostname public

Il est dans le périmètre (§3), avec `hostnames: [forgejo.wittner.tech]` et
`sectionName: https-public`. Le restaurer dans un **autre** namespace pose une seconde route sur
le même hostname et le même listener : le trafic de production se met à se répartir entre deux
backends, dont un de test.

⚠️ **Toute restauration vers un namespace autre que `forgejo` doit exclure
`httproutes.gateway.networking.k8s.io`.** C'est la ligne la plus importante de l'exercice.

### 3. Un cluster restauré qui archive écrase sa propre source

`serverName` vaut le nom du `Cluster` quand il est omis. Un `Cluster` de reprise nommé comme
l'original — ou renommé pour prendre sa place — archive ses WAL **par-dessus** ceux dont il vient,
et détruit la sauvegarde qui l'a produit.

`cnpg-barman-plugin-script.sh restore` écrit toujours un `serverName` explicite **des deux côtés**
(`externalClusters` en lecture seule, `spec.plugins` en écriture) exactement pour ça. Pour un
clone de validation, `--no-archive` supprime `spec.plugins` et ferme la question.

### 4. `passwordMode: keepUpdated` réaligne le mot de passe admin à chaque démarrage

Sur l'instance de production c'est voulu — le `SealedSecret` de Git est la source de vérité. Sur
une instance de reprise, cela veut dire que **le mot de passe admin de la copie est celui du
Secret restauré**, pas celui qu'on croit avoir noté. Et sur un clone de validation, cela réécrit
le compte du dump restauré au premier démarrage.

### 5. Une copie de la forge parle au monde extérieur

Une instance restaurée démarre avec la configuration de production : mailer Brevo actif,
webhooks autorisés vers `external`, miroirs de dépôts. Une copie qui tourne quelques minutes
suffit à **envoyer des mails réels**, **livrer des webhooks réels** et, pour un push-mirror,
**pousser sur un dépôt distant réel**.

Les neutralisations sont listées dans l'[exercice](forgejo-pra-exercice.md) §Garde-fous. Elles ne
sont pas optionnelles.

---

## 6. Ordre des opérations

> [!IMPORTANT]
> **L'ordre n'est pas commutatif, et l'inversion ne produit pas une erreur mais une attente
> indéfinie.** L'affinité du `Cluster` CNPG est en **sens unique** : la base suit Forgejo. Un pod
> CNPG posé avant que le pod Forgejo n'existe reste `Pending` — sans message, en attendant une
> cible qui n'est pas là.
>
> **Forgejo d'abord (avec son PVC), la base ensuite.**

### Étape 0 — choisir l'instant

```bash
script/velero-script.sh list                          # sauvegardes du PVC
script/cnpg-barman-plugin-script.sh list              # fenêtre PITR de la base
```

Retenir **une** sauvegarde velero, et relever son heure de fin :

```bash
kubectl -n velero get backups.velero.io <backup> \
  -o jsonpath='{.status.completionTimestamp}{"\n"}'
```

C'est la **cible PITR** de la base (§1). Vérifier qu'elle tombe dans la fenêtre affichée par
`cnpg-barman-plugin-script.sh list` (colonnes `DEBUT-FENETRE` → `DERNIER-BACKUP`) : une cible
en dehors fait s'arrêter le rejeu où il peut, et le cluster démarre sur un état antérieur
**sans erreur** — la perte est muette.

### Étape A — le PVC et l'applicatif

```bash
script/velero-script.sh show <backup>                 # combien de volumes, quelle taille
script/velero-script.sh restore <backup> -n forgejo
```

⚠️ `velero-script.sh restore` **prévient** des Applications ArgoCD dont le `selfHeal` va reposer
ce que Git déclare, en concurrence de la restauration. Sur une reprise réelle, suspendre
l'auto-sync de `forgejo` le temps du restore, comme le script l'indique.

Point de contrôle : le nombre de volumes réellement repris, affiché par le script. Une
restauration `Completed` avec **zéro** volume signifie objets restaurés, **données absentes**.

### Étape B — la base

```bash
script/cnpg-barman-plugin-script.sh restore forgejo-db \
    --name forgejo-db-restore \
    --target-time <completionTimestamp de l'étape 0>
```

La commande **imprime un manifeste** et n'applique rien : une restauration CNPG est un `Cluster`
neuf en `bootstrap.recovery`, donc un **état désiré**, donc du Git. Le manifeste est dérivé de ce
qu'ArgoCD déclare réellement (lu dans `.metadata.managedFields`), pas du `.spec` défauté servi par
l'API.

Sur une reprise **réelle** — celle qui doit reprendre la place de la production — deux gestes
suivent, et ils sont indissociables :

1. committer le manifeste sous `cluster/app/forgejo/manifests/`, l'ajouter au `kustomization.yaml` ;
2. faire suivre `gitea.config.database.HOST` (`<nouveau>-rw:5432`) et le `secretKeyRef` de
   `FORGEJO__DATABASE__PASSWD` (`<nouveau>-app`) dans `helm-values.yaml`.

⚠️ Sans le second, Forgejo continue de parler à la base d'origine — celle qu'on vient de
remplacer — **sans rien signaler**.

### Étape C — vérifier

Voir la checklist de l'[exercice](forgejo-pra-exercice.md) §Vérifications. Elle vaut aussi en
reprise réelle, à ceci près qu'on la joue sur le hostname public.

---

## 7. Points de couplage hors cluster

Rien de tout cela n'est sauvegardé, et chacun casse en silence :

| Couplage | Où | Symptôme s'il manque |
| --- | --- | --- |
| Routeur Traefik `192.168.1.50` | LXC, hors dépôt | **404**, malgré un HTTPRoute sain |
| `serversTransport` avec SNI | idem | le Gateway Cilium ne trouve aucun listener |
| Tunnel Cloudflare + `originRequest.originServerName` | Cloudflare, hors dépôt | idem, depuis Internet |
| Enregistrement DNS **Proxied** | Cloudflare | un Tunnel en DNS-only ne crée pas un chemin direct : il **tue** le nom |
| Bucket GCS + compte de service | dépôt Terraform | archivage WAL en échec, `CNPGWalArchivingBacklog` |

> [!WARNING]
> **Depuis le LAN, le DNS interne renvoie `192.168.1.50` pour tout `*.wittner.tech`.** Un test
> local ne prouve donc **rien** sur le chemin externe. C'est le piège de diagnostic principal du
> composant, et il a déjà coûté plusieurs fausses pistes.

---

## 8. Ce que ce plan ne couvre pas

- **La reprise du cluster lui-même** (scénario D, avant l'étape A) : Talos, ArgoCD, sealed-secrets,
  cert-manager. Un autre plan, qui n'existe pas encore.
- **La perte simultanée des deux buckets GCS.** Ils sont distincts et ont chacun leur GC, mais ils
  vivent dans le même projet et sous le même compte.
- **La preuve que le contenu restauré est correct.** Une restauration qui monte n'est pas une
  restauration juste : un dépôt peut être présent et son historique tronqué. C'est ce que
  l'[exercice](forgejo-pra-exercice.md) vérifie en clonant réellement depuis la copie.
