# forgejo-monitoring

## Rôle

Volet observabilité de [forgejo](../forgejo/README.md) : deux alertes de **disponibilité**.
Séparé du composant principal pour la même raison que
[velero-monitoring](../../infra/velero-monitoring/README.md) et
[cnpg-monitoring](../cnpg-monitoring/README.md) — ce sont des CRs `monitoring.coreos.com`, dont les
CRDs n'existent pas au bootstrap à froid.

**Il n'y a pas de dashboard ici** : celui de la forge (« Forge — forgejo ») vit avec les autres
dans [kube-prometheus-stack](../kube-prometheus-stack/README.md), et le ServiceMonitor qui
l'alimente dans [forgejo](../forgejo/README.md) — ce composant-ci ne porte que des alertes. ⚠️ Et
**aucune des deux ne lit encore les métriques applicatives** : elles interrogent kube-state-metrics
(voir *Contraintes*).

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
- **La source des deux règles reste kube-state-metrics, pas la forge.** Depuis le 2026-09-09 la
  forge **est** scrapée (`/metrics` authentifié, ServiceMonitor `forgejo-metrics`, job
  `forgejo-http` — cf. [forgejo §Métriques](../forgejo/README.md#métriques)), mais **aucune règle
  ne s'appuie encore dessus** : le trou « processus vivant mais muet » est donc toujours ouvert,
  et il l'est maintenant *sciemment*. La sonde qui le fermerait est écrite mais pas posée :

  ```promql
  absent(up{job="forgejo-http"} == 1)
  ```

  ⚠️ Elle **s'ajouterait** aux deux règles ci-dessus, sans en remplacer aucune : elles couvrent la
  disparition de l'objet, ce que `up` ne voit pas. ⚠️ Et elle sonnerait aussi sur une **dérive du
  token** de métriques (cible en 401) — ce qui est le comportement voulu, mais fait d'un secret
  mal tourné une alerte de disponibilité de la forge. C'est ce couplage qui explique qu'elle
  attende une décision plutôt qu'un commit.
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
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
  curl -s 'localhost:19090/api/v1/rules?type=alert' | grep -o 'Forgejo[A-Za-z]*' | sort -u
  ```
  ⚠️ Pas de `kubectl exec` dans le conteneur `prometheus` : son image n'a **ni shell ni `wget`**
  (`exec: "sh": executable file not found in $PATH`). Le seul accès à l'API passe par un
  port-forward.
- **Éprouver `ForgejoDown` sans casser la forge** — un `scale --replicas=0` suffit, mais ⚠️
  `selfHeal` d'ArgoCD le remonte en quelques secondes : couper l'auto-sync des TROIS niveaux
  (`root`, `app`, `forgejo`) d'abord, comme pour la reprise (doc/forgejo-pra.md §8 étape A).
