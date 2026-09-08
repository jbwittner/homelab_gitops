# script

## Rôle

Les **scripts utilitaires du repo**, tous ici et nulle part ailleurs. Un script rangé à côté du
composant qu'il pilote se cherche : il faut déjà savoir quel composant porte le geste pour trouver
la commande. Ici, `ls script/` suffit — et c'est aussi ce qui rend la règle vérifiable, un `.sh`
trouvé ailleurs que dans ce dossier est une exception à corriger.

## Contenu

- [`velero-script.sh`](velero-script.sh) — sauvegardes velero : `list`, `show`, `backup`,
  `restore`, `delete`. Le périmètre y est toujours **dérivé** (d'une Schedule pour un backup, du
  Backup source pour un restore) et jamais retapé. Ce n'est **pas** la CLI `velero` : tout passe
  par `kubectl` et `jq`. Documentation complète dans
  [`cluster/infra/velero/README.md`](../cluster/infra/velero/README.md), section Opérations
- [`cnpg-barman-plugin-script.sh`](cnpg-barman-plugin-script.sh) — sauvegardes **PostgreSQL
  barman-cloud** : `list`, `show`, `backup`, `restore`, `delete`. Même principe de dérivation (la
  spec d'une sauvegarde manuelle vient de la `ScheduledBackup`, celle d'une restauration du
  `Cluster` source). Ce n'est **pas** la CLI `cnpg` ni `barman-cloud-*`. Documentation complète
  dans [`cluster/app/cnpg-barman-plugin/README.md`](../cluster/app/cnpg-barman-plugin/README.md),
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

## Contraintes

- **Un script n'est pas une violation de la règle GitOps** — l'état désiré vit dans Git et ArgoCD
  l'applique ; ce que ces scripts fabriquent, ce sont des **événements** (un `Backup`, un
  `Restore`, un `DeleteBackupRequest`), pas des états désirés. Committés, ArgoCD les rejouerait
  sans fin après chaque expiration de TTL. Leur place est une commande. Tout ce qui décrit un
  **état** reste un manifeste sous `cluster/`, jamais un script.
- **Corollaire : un script qui produirait un état l'IMPRIME au lieu de l'appliquer.** C'est le cas
  de `cnpg-barman-plugin-script.sh restore`, dont la sortie est un manifeste à committer. La règle
  ne se contourne pas par commodité — elle change ce que le script rend.
- **S'exécutent depuis la racine du repo** — les chemins des messages d'aide et de la
  documentation sont écrits `script/<nom>.sh`.
- **Convention de nommage** : `<composant>-script.sh`, aiguillage par sous-commande
  (`script/velero-script.sh backup`), `--help` qui décrit chaque sous-commande.
- **La documentation du geste reste dans le README du composant** ; ce fichier n'est qu'un index.
