# doc

## Rôle

Les **règles** et les **procédures** du homelab : ce qui vaut pour tout le dépôt, et ce qui se fait
à la main — sous stress ou une fois par an — sans tenir dans un README de composant ni dans un
script.

La frontière avec le reste du dépôt :

| Où | Quoi |
| --- | --- |
| `cluster/**/README.md` | ce que le composant **est**, et pourquoi il est réglé ainsi |
| `script/` | ce qui se **tape souvent**, automatisé |
| `doc/` | ce qui **vaut pour tout le dépôt** (règles, conventions, réseau), et ce qui se **conduit** en plusieurs étapes avec des décisions entre elles |

Un README de composant décrit un état ; une procédure d'ici décrit un **enchaînement**, avec ses
points de contrôle et ses pièges d'ordre. C'est la seule raison d'être de ce dossier — sans quoi
ces pages iraient dans le README du composant concerné.

## Contenu

### Règles et conventions — valables partout

- [`regles-gitops.md`](regles-gitops.md) — les règles **non négociables** : aucune donnée hors
  GitOps, les cinq gestes impératifs assumés, le canal de secrets (sealed-secrets, désormais le
  seul), et pourquoi le dépôt **s'écrit comme s'il était public** — réécriture d'historique plutôt
  que commit correctif, et la clé sealed-secrets comme point de fuite rétroactif.
- [`conventions.md`](conventions.md) — la forme d'un composant : arbre `cluster/`, suffixes
  `.app.yaml` / `.noapp.yaml`, archétypes, sync-waves, règle README.
- [`reseau.md`](reseau.md) — le `shared-gw`, ses trois listeners, ce qui est exposé, le DNS — et le
  **reverse proxy `192.168.1.50`**, sans lequel un `HTTPRoute` sain répond 404.

### Procédures

- [`runbook-bootstrap.md`](runbook-bootstrap.md) — **bootstrap et reprise à froid** du cluster, en
  huit étapes et quatre gestes manuels irréductibles. La valeur de cette page est l'ordre des
  dépendances, pas les commandes.

> [!NOTE]
> `openbao-restore-local.md` a été **supprimé** : il documentait la restauration d'un coffre qui
> n'est plus déployé. Son contenu reste dans l'historique git, et le composant lui-même dans
> [`archive/openbao/`](../archive/openbao/README.md).

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
