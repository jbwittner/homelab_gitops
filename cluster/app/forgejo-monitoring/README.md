# forgejo-monitoring

## Rôle

Volet observabilité de [forgejo](../forgejo/README.md) : deux alertes de **disponibilité**.
Séparé du composant principal pour la même raison que
[velero-monitoring](../../infra/velero-monitoring/README.md) et
[cnpg-monitoring](../cnpg-monitoring/README.md) — ce sont des CRs `monitoring.coreos.com`, dont les
CRDs n'existent pas au bootstrap à froid.

**Il n'y a pas de dashboard ici**, et pas non plus de métriques applicatives : la forge n'est
scrapée par personne (voir *Contraintes*).

## Pourquoi il existe

Le 2026-09-09, pendant l'exercice de reprise en place, Forgejo est resté indisponible **~45
minutes** — PVC détruit, base détruite, Deployment supprimé — et **aucune alerte n'a sonné**.

`KubeDeploymentReplicasMismatch`, fournie par kube-prometheus-stack, aurait couvert un Deployment
en panne. Mais la procédure de reprise **supprime** le Deployment : la série
`kube_deployment_status_replicas_available` disparaît, et une expression qui la compare à zéro ne
se déclenche jamais. **Série absente ≠ série à zéro.**

## Fichiers

- `forgejo-monitoring.app.yaml` — Application, ns `forgejo`, wave `2`
- `manifests/prometheusrule.yaml` — deux alertes, groupe `forgejo.rules`

## Les deux règles

| Alerte | Expression | `for` | Ce qu'elle voit |
| --- | --- | --- | --- |
| `ForgejoDown` | `kube_deployment_status_replicas_available{…} == 0` | 10 min | Le Deployment existe et ne sert plus rien |
| `ForgejoDeploymentMissing` | `absent(kube_deployment_status_replicas_available{…})` | 15 min | Le Deployment n'existe plus |

## Contraintes

- **Les deux règles sont indissociables. En garder une seule rouvre le trou.** C'est la même
  construction que `VeleroBackupTooOld` / `VeleroNoBackupMetric` : une règle sur la valeur, sa
  complémentaire en `absent(...)`. Seule la seconde aurait sonné le 2026-09-09.
- **La source est kube-state-metrics, pas la forge.** Aucun ServiceMonitor ne collecte Forgejo
  aujourd'hui, alors que le chart sait exposer des métriques (`[metrics] TOKEN` dans
  `helm-values.yaml`). Conséquence assumée : on voit qu'aucun pod ne sert, on ne verrait **pas** un
  processus vivant mais muet. Le jour où un ServiceMonitor existe, `absent(up{job="forgejo"} == 1)`
  sera une meilleure sonde et devra s'ajouter — pas remplacer celles-ci, qui couvrent la
  disparition de l'objet.
- **`for: 10m` sur `ForgejoDown` est un plancher, pas un réglage timide.** La forge n'a qu'un
  replica : toute montée de version Renovate la rend indisponible le temps du remplacement. Plus
  court, chaque mise à jour allumerait une alerte critique — et une alerte qu'on apprend à ignorer
  ne protège plus de rien. Un redémarrage normal observé tient en moins de 2 min.
- **`ForgejoDeploymentMissing` sonne pendant un exercice de PRA, et c'est voulu.** C'est la preuve
  qu'elle fonctionne. La faire taire se fait par un silence Alertmanager
  (`alertmanager.lan.wittner.tech`), jamais en allongeant `for`.
- **Si kube-state-metrics tombe, `absent(...)` se déclenche sans que la forge ait bougé.** C'est le
  prix de cette forme, et il est accepté : l'inverse — rester muet quand l'objet disparaît — est
  exactement la panne qu'on vient de vivre. Le cas se reconnaît immédiatement, `TargetDown` et les
  autres alertes KSM sonnant en même temps.
- **La base n'est PAS surveillée ici.** `forgejo-db` relève de
  [cnpg-monitoring](../cnpg-monitoring/README.md), et ses pannes y sont couvertes. `ForgejoDown`
  les verra malgré tout par ricochet : sans base, le pod n'est jamais Ready.

## Opérations

- **Vérifier que les règles sont chargées** :
  ```bash
  kubectl -n forgejo get prometheusrule
  kubectl -n monitoring exec -ti sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' | grep -o 'Forgejo[A-Za-z]*'
  ```
- **Éprouver `ForgejoDown` sans casser la forge** — un `scale --replicas=0` suffit, mais ⚠️
  `selfHeal` d'ArgoCD le remonte en quelques secondes : couper l'auto-sync des TROIS niveaux
  (`root`, `app`, `forgejo`) d'abord, comme pour la reprise (doc/forgejo-pra.md §8 étape A).
