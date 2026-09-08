# doc

## Rôle

Les **procédures** du homelab : ce qui se fait à la main, sous stress ou une fois par an, et qui ne
tient ni dans un README de composant ni dans un script.

La frontière avec le reste du dépôt :

| Où | Quoi |
| --- | --- |
| `cluster/**/README.md` | ce que le composant **est**, et pourquoi il est réglé ainsi |
| `script/` | ce qui se **tape souvent**, automatisé |
| `doc/` | ce qui se **conduit**, en plusieurs étapes, avec des décisions entre les étapes |

Un README de composant décrit un état ; une procédure d'ici décrit un **enchaînement**, avec ses
points de contrôle et ses pièges d'ordre. C'est la seule raison d'être de ce dossier — sans quoi
ces pages iraient dans le README du composant concerné.

## Contenu

- [`openbao-restore-local.md`](openbao-restore-local.md) — remonter un snapshot OpenBao dans une
  instance jetable **hors cluster**, pour prouver qu'il est réellement restaurable. Ne touche
  rien du cluster. Automatisé par
  [`openbao-script.sh verify`](../archive/openbao/README.md).
- [`forgejo-pra.md`](forgejo-pra.md) — le **plan de reprise** de la forge : ce qui est perdu selon
  le sinistre, dans quel ordre remonter, et les cinq pièges qui rendent une restauration
  silencieusement fausse.
- [`forgejo-pra-exercice.md`](forgejo-pra-exercice.md) — **l'exercice** qui éprouve ce plan :
  restaurer les deux chaînes dans un namespace `forgejo-preprod`, l'exposer sur
  `forgejo-preprod.lan.wittner.tech`, vérifier, détruire.

## Contraintes

- **Une procédure d'ici a été exécutée au moins une fois.** Les valeurs et les messages d'erreur
  qu'elle contient sont relevés, pas supposés. Une étape jamais jouée est signalée comme telle.
- **Les commandes s'exécutent depuis la racine du dépôt** — les chemins sont écrits
  `script/<nom>.sh`, `cluster/app/<composant>/…`.
- **Une procédure qui écrit dans le cluster dit où elle écrit, et comment défaire.** Le démontage
  fait partie de la procédure, jamais des options : c'est l'étape qu'on saute quand tout s'est
  bien passé, et c'est celle qui laisse traîner un volume, un namespace ou un port.
- **La règle GitOps s'applique aussi ici.** Ce que ces pages appliquent à la main sont soit des
  **événements** (un `Backup`, un `Restore`), soit un **périmètre jetable et hors ArgoCD**, jamais
  un état durable de la production. Tout ce qui doit durer redevient un manifeste sous `cluster/`.
