# homelab-gitops

Dépôt d'infrastructure du homelab. Il regroupe **deux environnements indépendants**, chacun avec
son modèle de déploiement et sa propre documentation détaillée :

| Environnement | Plateforme | Modèle de déploiement | Documentation |
|---|---|---|---|
| **neltharion** | Kubernetes (Talos 1.36), ingress Traefik | **GitOps** via un Argo CD central (hub/spoke). Push sur `main` → Argo reconcilie. | [`neltharion/README.md`](neltharion/README.md) |
| **onyxia** | Kubernetes | **GitOps** via son **propre Argo CD** (hub autonome). Push sur `main` → Argo reconcilie. Squelette minimal. | [`onyxia/README.md`](onyxia/README.md) |
| **taerar** | Docker | Stacks **Docker Compose** gérées via **Dokploy**. Un `compose.yaml` auto-contenu par stack. | [`taerar/README.md`](taerar/README.md) |

Chaque environnement vit dans son dossier racine (`neltharion/`, `taerar/`) et documente son
architecture, ses conventions et ses composants dans son propre `README.md` (puis un `README.md`
par composant / stack).

Les composants retirés sont conservés sous [`archive/`](archive/) (neltharion) et
[`taerar/archive/`](taerar/archive/).

> **Pour les agents** : [`CLAUDE.md`](CLAUDE.md) contient les règles de travail sur ce dépôt
> (mise à jour de la doc, génération des secrets) et renvoie vers la doc d'environnement.
