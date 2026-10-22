# script

## Rôle

Les **scripts utilitaires du repo**, tous ici et nulle part ailleurs. Un script rangé à côté du
composant qu'il pilote se cherche : il faut déjà savoir quel composant porte le geste pour trouver
la commande. Ici, `ls script/` suffit — et c'est aussi ce qui rend la règle vérifiable, un `.sh`
trouvé ailleurs que dans ce dossier est une exception à corriger.

> [!NOTE]
> **Une exception subsiste** : [`archive/openbao/openbao-script.sh`](../archive/openbao/openbao-script.sh),
> parti dans `archive/` avec son composant. Il n'est plus maintenu et ne pilote plus rien de
> déployé — la règle ne vaut que pour les scripts vivants.

## Contenu

- [`velero-script.sh`](velero-script.sh) — sauvegardes velero : `list`, `show`, `backup`,
  `restore`, `delete`. Le périmètre y est toujours **dérivé** (d'une Schedule pour un backup, du
  Backup source pour un restore) et jamais retapé. Ce n'est **pas** la CLI `velero` : tout passe
  par `kubectl` et `jq`. Documentation complète dans
  [`k8s/infra/velero/README.md`](../k8s/infra/velero/README.md), section Opérations
- [`cnpg-barman-plugin-script.sh`](cnpg-barman-plugin-script.sh) — sauvegardes **PostgreSQL
  barman-cloud** : `list`, `show`, `backup`, `restore`, `delete`. Même principe de dérivation (la
  spec d'une sauvegarde manuelle vient de la `ScheduledBackup`, celle d'une restauration du
  `Cluster` source). Ce n'est **pas** la CLI `cnpg` ni `barman-cloud-*`. Documentation complète
  dans [`k8s/app/cnpg-barman-plugin/README.md`](../k8s/app/cnpg-barman-plugin/README.md),
  section Opérations.

  > [!IMPORTANT]
  > Deux différences avec `velero-script.sh`, qui vont **à contre-sens de l'intuition** acquise
  > sur l'autre script :
  > - `delete` **ne touche pas au bucket**. Il n'y a pas de `DeleteBackupRequest` côté CNPG : les
  >   données ne relèvent que de la `retentionPolicy` de l'`ObjectStore`. Supprimer l'objet
  >   `Backup` ne perd que le catalogue Kubernetes, pas la sauvegarde.
  > - `restore` **n'envoie rien au cluster**, il **imprime un manifeste**. Une restauration CNPG
  >   n'est pas un événement mais un `Cluster` neuf en `bootstrap.recovery` — donc un état
  >   désiré, donc du Git. C'est la règle GitOps qui s'applique, pas une limitation du script.
  >   Redirigée, sa sortie ne contient **que** le manifeste : le récapitulatif part sur stderr.
- [`hermes-memory-script.sh`](hermes-memory-script.sh) — inspection de la **base mémoire
  d'Hermes** (provider `holographic`) : `profiles`, `list`, `show`, `search`, `entities`,
  `stats`, `schema`, `sql`, `dump`. La cible se choisit par `--profile` / `--db` — il y a une
  base **par profil**, et `profiles` montre laquelle chaque profil lit réellement. **Seul script du dossier qui n'écrit nulle part** : ni dans le cluster, ni dans
  la base — la mémoire de l'agent se modifie par l'agent (`fact_store`, `fact_feedback`), pas
  d'ici. Documentation du composant dans
  [`k8s/app/hermes/README.md`](../k8s/app/hermes/README.md), section Mémoire.

  > [!IMPORTANT]
  > Deux précautions que le script prend et qu'une commande tapée à la main oublie :
  > - il descend sur **l'uid 10000 avant d'ouvrir la base**. `kubectl exec` entre en root, et un
  >   `-wal` / `-shm` créé par root sur une base ouverte en écriture rend la base **inaccessible
  >   à la gateway**, qui tourne en 10000 ;
  > - il n'utilise **pas** `immutable=1`. Ce serait la façon évidente de « lire sans rien
  >   toucher », et elle fait ignorer le WAL — où vit l'essentiel des écritures récentes (4 Ko de
  >   `.db` pour 170 Ko de `-wal`). On lirait une base périmée sans la moindre erreur.
  >
  > Même raison pour `dump`, qui passe par `Connection.backup()` et non par un `cp` du `.db`.
  > Sa sortie contient la mémoire de l'agent en clair : elle n'a rien à faire dans un dépôt.

## Contraintes

- **Un script n'est pas une violation de la règle GitOps** — l'état désiré vit dans Git et ArgoCD
  l'applique ; ce que ces scripts fabriquent, ce sont des **événements** (un `Backup`, un
  `Restore`, un `DeleteBackupRequest`), pas des états désirés. Committés, ArgoCD les rejouerait
  sans fin après chaque expiration de TTL. Leur place est une commande. Tout ce qui décrit un
  **état** reste un manifeste sous `k8s/`, jamais un script.
- **Corollaire : un script qui produirait un état l'IMPRIME au lieu de l'appliquer.** C'est le cas
  de `cnpg-barman-plugin-script.sh restore`, dont la sortie est un manifeste à committer. La règle
  ne se contourne pas par commodité — elle change ce que le script rend.
- **S'exécutent depuis la racine du repo** — les chemins des messages d'aide et de la
  documentation sont écrits `script/<nom>.sh`.
- **Convention de nommage** : `<composant>-script.sh`, aiguillage par sous-commande
  (`script/velero-script.sh backup`), `--help` qui décrit chaque sous-commande.
- **La documentation du geste reste dans le README du composant** ; ce fichier n'est qu'un index.
