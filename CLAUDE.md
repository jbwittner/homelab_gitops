# CLAUDE.md

Instructions pour Claude Code (claude.ai/code) quand il travaille sur ce dépôt.

## Le dépôt en deux mots

Dépôt d'infrastructure du homelab, **deux environnements indépendants** :

- **neltharion/** — Kubernetes (Talos 1.36) en **GitOps** via un Argo CD central (hub/spoke).
  Toute l'architecture, l'arborescence, les sync-waves, le bootstrap et les pièges du
  self-management sont documentés dans [`neltharion/README.md`](neltharion/README.md) et les
  README par composant sous `neltharion/{infra,apps}/<name>/`.
- **taerar/** — stacks **Docker Compose** gérées via **Dokploy**. Conventions (nommage, `.env`,
  réseaux externes partagés) et liste des stacks dans [`taerar/README.md`](taerar/README.md),
  détail dans le README de chaque stack.

> **Avant de modifier quoi que ce soit, lire le README de l'environnement concerné** — il porte
> le contexte (architecture, ordre de déploiement, dépendances) que ce fichier ne duplique plus.

## Documentation upkeep (mandatory)

Toute intervention sur le dépôt **doit** garder la documentation à jour dans le même
changement — la doc fait partie de la définition de « terminé ». Concrètement :

- Si tu ajoutes/supprimes/déplaces un composant, manifeste ou fichier : mets à jour le
  `README.md` racine si la liste des environnements change, le `README.md` de l'environnement
  concerné ([`neltharion/README.md`](neltharion/README.md) — layout, tables sync-wave « deployed »
  vs « roadmap » ; [`taerar/README.md`](taerar/README.md) — tableau des stacks), **et** le
  `README.md` du composant/stack concerné.
- Quand un élément de la **Roadmap** neltharion est déployé, le déplacer dans la table « deployed ».
- Toute référence à un fichier/chemin dans la doc doit pointer vers un fichier qui existe
  réellement. Vérification rapide : `grep` les noms de fichiers cités et confronter à
  `find <dossier> -name '*.yaml'`.
- Ne jamais laisser la doc décrire un état « cible » comme s'il était en place : marquer
  explicitement *implémenté* vs *prévu*.

## Secrets — toujours documenter les commandes de génération

- **neltharion (SealedSecrets).** Tout composant qui introduit un `Secret`/`SealedSecret` doit
  fournir, dans son `README.md`, la procédure **complète et copiable** pour le (re)générer :
  type/scope du token attendu, remplissage du placeholder `*.secret.yaml` (gitignored), puis
  scellement. **Privilégier le scellement direct contre le contrôleur** (`kubeseal
  --controller-name=sealed-secrets --controller-namespace=sealed-secrets --format yaml <
  *.secret.yaml > *.sealed-secret.yaml`) plutôt que le cert local ; ne réserver
  `--fetch-cert`/`--cert pub-cert.pem` qu'au repli offline. Ne jamais se contenter de « sceller
  le secret » sans les commandes. Les SealedSecrets sont **par-cluster** (chiffrés contre la clé
  d'un contrôleur donné).
- **taerar (Docker).** Tout stack avec des secrets doit fournir un `example.env` (copié en `.env`
  gitignored) et documenter chaque variable dans son `README.md` ; les fichiers sensibles montés
  (clés, certs) passent par le bind-mount Dokploy « Files/Mounts » (`files/…`).
