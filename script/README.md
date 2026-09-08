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

## Contraintes

- **Un script n'est pas une violation de la règle GitOps** — l'état désiré vit dans Git et ArgoCD
  l'applique ; ce que ces scripts fabriquent, ce sont des **événements** (un `Backup`, un
  `Restore`, un `DeleteBackupRequest`), pas des états désirés. Committés, ArgoCD les rejouerait
  sans fin après chaque expiration de TTL. Leur place est une commande. Tout ce qui décrit un
  **état** reste un manifeste sous `cluster/`, jamais un script.
- **S'exécutent depuis la racine du repo** — les chemins des messages d'aide et de la
  documentation sont écrits `script/<nom>.sh`.
- **Convention de nommage** : `<composant>-script.sh`, aiguillage par sous-commande
  (`script/velero-script.sh backup`), `--help` qui décrit chaque sous-commande.
- **La documentation du geste reste dans le README du composant** ; ce fichier n'est qu'un index.
