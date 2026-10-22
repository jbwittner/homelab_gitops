# docker — l'hôte `vert-emeriss`

Les piles Docker Compose de la machine `vert-emeriss` (192.168.1.15), déployées par **Komodo** —
l'arbre jumeau de [`k8s/`](../k8s/), que lit ArgoCD. Une pile = un répertoire, avec son
`compose.yaml`, son `.env.example` et son `README.md`. Les données vivent sous `/srv/<service>/`
sur l'hôte, jamais ici. Les conventions sont dans [`CLAUDE.md`](CLAUDE.md).

> Jusqu'au 22 octobre 2026, cet arbre était un dépôt à part, `homelab_emeriss`, aujourd'hui archivé
> — son historique y reste lisible. La bascule est décrite dans
> [`komodo/README.md`](komodo/README.md#bascule-depuis-homelab_emeriss--2026-10-22).

- [`doc/bootstrap-debian.md`](doc/bootstrap-debian.md) — préparer un Debian neuf à recevoir ces piles. **À lire en
  premier sur une machine vierge.**
- [`node-exporter/`](node-exporter/README.md) — supervision de l'**hôte** (disque, mémoire, charge),
  scrutée depuis le cluster. Pile à part parce qu'elle doit **survivre aux piles applicatives** :
  rangée dans le compose de l'une d'elles, elle serait arrêtée par son `docker compose down`,
  c'est-à-dire pendant l'incident qu'on veut voir.
- [`cadvisor/`](cadvisor/README.md) — supervision des **conteneurs** (qui consomme quoi), même
  raison d'être une pile à part. ⚠️ **Deux conteneurs** : cAdvisor ne sait pas authentifier
  `/metrics`, un nginx local s'en charge et il est le seul à publier un port.
- [`komodo/`](komodo/README.md) — **gestionnaire des piles** : UI des conteneurs, et déploiement
  des deux piles ci-dessus depuis ce dépôt ([`komodo/sync/piles.toml`](komodo/sync/piles.toml)).
  ⚠️ Équivalent root par le navigateur (socket Docker, terminaux activés) : LAN seul.

## Redéployer

| Piles | Geste |
|---|---|
| `node-exporter`, `cadvisor` (déclarées dans `komodo/sync/`) | **aucun** — la procédure Komodo `deploiement-auto` joue la sync toutes les 15 min |
| `komodo` lui-même | `git pull && bin/redeploy komodo` sur l'hôte |

```bash
cd ~/homelab                      # lien vers /opt/homelab/homelab_gitops/docker
git pull && bin/redeploy          # toutes les piles NON pilotées par Komodo : pull + up -d
bin/redeploy --dry-run            # ce qui serait joué, sans rien toucher
```

`bin/redeploy` **refuse** les piles déclarées dans `komodo/sync/` : Komodo les lance depuis son
propre clone, et un second `up` depuis celui-ci recréerait les mêmes conteneurs avec l'autre copie
des fichiers montés. Komodo, à l'inverse, ne pilote pas sa propre pile — il s'arrêterait au milieu
de l'opération qu'il conduit.

⚠️ **Un merge sur `main` part en production**, comme sous `k8s/` : Renovate automerge les
correctifs et mineures ([`renovate.json`](../renovate.json) à la racine), et Komodo déploie dans le
quart d'heure. **Sauf `komodo/`**, à qui Renovate refuse l'automerge : rien ne la redéploie toute
seule, et une version mergée sans `bin/redeploy` serait une version que le dépôt déclare et que
l'hôte ne fait pas tourner. `bin/redeploy --help` porte le reste.

## Où vit ce dépôt

Sur GitHub, en dépôt **privé** : `git@github.com:jbwittner/homelab_gitops.git`, partagé avec le
cluster. Le clone de l'hôte (`/opt/homelab/homelab_gitops`) le lit par une clé de déploiement en
lecture seule ([§5.1 du bootstrap](doc/bootstrap-debian.md)) ; Komodo, par un jeton fine-grained
([`komodo/README.md`](komodo/README.md) §5). Tous deux ouvrent **tout** le dépôt, `k8s/` compris.
