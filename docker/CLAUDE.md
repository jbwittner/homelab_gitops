# docker/ — instructions de travail

Arbre Docker Compose de `homelab_gitops`, déployé par Komodo sur l'hôte `vert-emeriss` — l'arbre
jumeau de `k8s/` (ArgoCD), dont les règles sont dans `../doc/`. Une pile = un répertoire de
`docker/`, avec son `compose.yaml`, son `.env.example` et son `README.md`. Les données vivent sous
`/srv/<service>/` sur l'hôte, jamais dans le dépôt.

## Emplacement de la documentation

- **`README.md`** — à la racine de `docker/`, et un par pile. Rien d'autre à la racine de `docker/`.
- **`docker/doc/`** — ce qui concerne **plusieurs piles ou l'hôte** : `doc/bootstrap-debian.md`.
- **`<pile>/doc/`** — ce qui ne concerne **qu'une pile** : sa procédure de sauvegarde, par exemple.
- Kebab-case partout, même convention que `doc/` à la racine du dépôt — qui, lui, est propre à
  `k8s/` : un document Docker n'y va pas.

Critère de placement : **qui doit lire ce document pour faire son travail ?** Une procédure que
seul l'exploitant d'une pile joue vit dans `<pile>/doc/`. Un prérequis d'hôte que toute pile
suppose vit dans `doc/`. Dans le doute, le README de la pile porte le renvoi — un document qu'on
ne trouve pas n'existe pas.

Le README d'une pile reste le point d'entrée : il **renvoie** vers `<pile>/doc/`, il ne duplique
pas. Une procédure recopiée à deux endroits diverge, et c'est toujours la copie périmée qu'on
suit sous pression.

## Règle de maintenance — `doc/bootstrap-debian.md`

[`doc/bootstrap-debian.md`](doc/bootstrap-debian.md) décrit l'état qu'un Debian neuf doit atteindre
**avant** que les piles de ce dépôt puissent démarrer : paquets, Docker, arborescence `/srv`, règles
de pare-feu.

> [!IMPORTANT]
> **Toute addition d'un service ou d'un outil oblige à mettre à jour `doc/bootstrap-debian.md` dans
> le même changement.** Un prérequis d'hôte manquant ne produit pas d'erreur au
> `docker compose up` : il se découvre en production, sous la forme d'un répertoire absent, d'un
> port ouvert à tout le LAN, ou d'un paquet qui manque au moment où on en a besoin.

À mettre à jour, concrètement :

- **Tableau des services** (§« Rôle ») — nouvelle ligne : répertoire, chemins de données sur
  l'hôte, ports publiés, lien vers le README de la pile.
- **§5 Arborescence** — les `mkdir` des nouveaux chemins de données, et le propriétaire attendu
  s'il n'est pas `root`. Un répertoire portant des secrets se pose en `0700 root`, jamais moins.
- **§4 / §2** — tout paquet ou réglage de démon (`daemon.json`, `sysctl`) qu'exige le nouveau
  service. Un paquet absent d'`apt` se pose en binaire vérifié par somme de contrôle relevée sur
  la page de la release, **jamais recopiée dans le document** : elle y serait périmée dès la
  version suivante.
- **§6 Vérification** — la commande qui prouve que le prérequis est en place, pas celle qui prouve
  que le service tourne.
- **Ports publiés** — il n'y a plus de chapitre pare-feu : il a été retiré le 10 septembre 2026,
  le pare-feu de l'hôte étant désactivé par décision assumée. ⚠️ S'il revient, ce n'est **pas**
  par `DOCKER-USER` : sous Docker 28+ cette chaîne n'existe plus et Docker n'installe aucune règle
  netfilter. Les ports publiés le sont par `docker-proxy`, qui écoute sur l'IP de l'hôte — donc
  ils se filtrent dans la chaîne `input` de la table de l'hôte, comme n'importe quel service.

Un outil ajouté **au dépôt** (linter, générateur, script CI) et qui doit exister **sur l'hôte** suit
la même règle : il rejoint le §4, sinon il n'est installé nulle part.

## Conventions

- **Français** dans toute la documentation, les commentaires et les messages d'alerte.
- **Commentaires explicatifs, pas descriptifs.** Les `compose.yaml` de ce dépôt disent *pourquoi*
  une valeur est là et *ce qui casse* sans elle. Un commentaire qui paraphrase la ligne suivante
  est du bruit ; conserver ce niveau de détail sur les pièges et les valeurs par défaut.
- **Tags d'images en dur dans `compose.yaml`**, jamais via le `.env` : Renovate n'a pas de manager
  pour les fichiers `.env`. Un tag en variable est un tag que plus personne ne met à jour — c'est
  écrit dans `renovate.json` (racine du dépôt), dont le régime — cooldown de 7 jours, automerge des
  correctifs et mineures, donc déploiement automatique par Komodo — s'applique à toute nouvelle
  pile sans rien ajouter. Une image qui migre ses données sans retour arrière (base de données,
  application à schéma) y ajoute une règle `dependencyDashboardApproval`. Une pile que Komodo
  ne déploie pas (`komodo/` elle-même) y reçoit `automerge: false`, sinon le dépôt déclare des
  versions que l'hôte ne fait pas tourner.
- **Une pile pilotée par Komodo se déclare dans `komodo/sync/piles.toml`**, `run_directory`
  depuis la racine du dépôt (`docker/<pile>`). Sans cette déclaration, ni Komodo ni la procédure
  `deploiement-auto` ne la voient : elle ne se déploie que par `bin/redeploy`, à la main.
- **Variables obligatoires en `${VAR:?}`** quand une valeur vide serait destructrice — mieux vaut un
  refus de démarrer qu'un défaut silencieux.
- **`.env` jamais versionné**, `.env.example` toujours, sans aucune valeur réelle. Vérifier avec
  `git check-ignore -v <service>/.env` avant tout premier commit d'une pile.
- **Une valeur répétée à plusieurs endroits se signale des deux côtés.** L'IP LAN de l'hôte apparaît
  dans le `.env` de chaque pile et dans l'URL des services de `homelab_ysera/traefik/dynamic/` —
  **un autre dépôt** : chaque occurrence porte un renvoi vers les autres.
- **Aucune configuration Traefik dans ce dépôt.** Les règles du reverse-proxy vivent dans
  `homelab_ysera/traefik/dynamic/`, seul exemplaire, monté sur le CT 201 qui porte Traefik. Les
  « copies de référence » qui vivaient ici ont été retirées le 11 septembre 2026 : l'une d'elles
  avait divergé **dans les deux sens** — un routeur servi qu'elle ignorait, un autre qu'elle
  déclarait sans qu'il soit servi — et rien ne signalait l'écart, sinon d'interroger Traefik.
  ⚠️ Une pile nouvelle qui doit être exposée n'ajoute donc **pas** de `<pile>/traefik/` : elle
  ajoute un fichier là-bas, et son README d'ici y renvoie.
