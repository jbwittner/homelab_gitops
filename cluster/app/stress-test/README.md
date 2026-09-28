# stress-test

## Rôle

Charger volontairement **un** nœud pour mesurer son plafond thermique, et vérifier que
`MachineSensorNearCritical` ([kube-prometheus-stack](../kube-prometheus-stack/README.md)) se
déclenche pour de vrai. C'est un **instrument**, pas un service : son état normal est
`.noapp.yaml`, donc non déployé.

Créé le 2026-09-28, à la suite d'une inquiétude sur des températures « un peu élevées » aux
alentours de 60 °C — qui se sont révélées être le régime normal du parc. Ce composant existe pour
répondre à la question que les métriques au repos ne peuvent pas trancher : **jusqu'où ça monte
quand ça travaille vraiment**, et le refroidissement tient-il.

## Danger

⚠️ **Les trois nœuds sont control-plane et sans aucun taint.** Ils portent etcd, l'apiserver, et
les charges applicatives sur les mêmes cœurs. Saturer un nœud affame le membre etcd qui tourne
dessus.

⚠️ **Le quorum est de 2 sur 3.** Rendre un nœud non réactif est absorbable. En rendre **deux** fait
perdre le quorum : plus aucune écriture d'API, ArgoCD bloqué, kubelets incapables de rapporter, et
une récupération qui passe par Talos. C'est la seule façon de casser sérieusement ce cluster avec
ce composant, et elle est atteignable par une simple inattention — d'où la règle unique :

> **Un seul nœud à la fois. Un seul Job dans `kustomization.yaml`.**

⚠️ **On ne peut pas observer etcd pendant le test.** `kubeEtcd.enabled: false` dans
`helm-values.yaml`, avec scheduler, controller-manager et kube-proxy : il n'existe **aucune
métrique du serveur etcd** dans ce Prometheus — ni durée de `fsync` du WAL, ni changement de
leader. etcd ne se voit que par les métriques CLIENT de l'apiserver. C'est suffisant pour un test
thermique ; ça ne l'est pas pour un test de charge du control-plane, qui chargerait précisément ce
qui n'est pas mesuré. **Ne pas utiliser ce composant pour ça** sans avoir d'abord activé
`kubeEtcd`.

⚠️ `vert-eranikus` n'a que **16 Go** de RAM contre 32 pour les deux autres, et il porte
**Prometheus**. Le charger ralentit l'instrument qui enregistre la mesure. Il passe en dernier,
jamais en premier.

## Fichiers

- `stress-test.noapp.yaml` — Application ArgoCD. ⚠️ **Le suffixe est l'interrupteur** : `.app.yaml`
  lance, `.noapp.yaml` arrête et supprime le Job par `prune`.
- `manifests/namespace.yaml` — ns `stress-test`, PodSecurity `baseline` (le conteneur démarre root
  pour installer stress-ng ; `restricted` l'interdirait)
- `manifests/job-cpu.yaml` — le Job. Nom **dérivé du nœud cible**, `BestEffort`, `backoffLimit: 0`,
  `activeDeadlineSeconds: 900`, `--cpu 12` sur 16
- `manifests/kustomization.yaml` — assemblage. ⚠️ Un seul Job référencé à la fois

## Contraintes

- **Aucun bloc `resources`, et il ne faut pas en ajouter.** C'est l'absence de requests qui donne
  la QoS `BestEffort`, donc le poids CPU minimal dans cgroup v2 : etcd, l'apiserver et le kubelet
  (Guaranteed / Burstable) gagnent l'arbitrage dès qu'ils réclament le processeur. Des requests ici
  mettraient le stress à égalité avec le control-plane.
- **Pas de `ttlSecondsAfterFinished`.** Le TTL supprimerait le Job terminé, `selfHeal: true` le
  recréerait, et il se relancerait : boucle de stress infinie, sans erreur nulle part. Le Job
  terminé doit rester — c'est lui qui prouve à ArgoCD que l'état désiré est atteint.
- **Un `spec` de Job est immuable.** Changer le nœud ou les paramètres d'un Job existant fait
  échouer la synchronisation. C'est pourquoi le nom du Job porte le nom du nœud : changer de cible
  produit un objet différent, l'ancien est `prune`, le nouveau est créé.
- **`--cpu 0` est interdit** sur ces machines : tous les cœurs saturés font basculer le nœud en
  `NotReady`. `--cpu 12` sur 16 laisse de quoi faire tourner le control-plane.
- **Le pod a besoin d'un accès réseau sortant** vers les miroirs Alpine au démarrage : stress-ng
  est installé à l'exécution, pas embarqué dans l'image. Miroir injoignable = Job en échec, donc
  pas de test — visible, jamais silencieux. Raison de ce choix : l'image officielle
  `ghcr.io/colinianking/stress-ng` ne publie que des tags de commit SHA (Renovate aveugle), et la
  seule en semver est figée à 0.12.05 depuis 2021. Alpine community fournit 0.18.08, à jour, et
  `alpine` est suivi par Renovate.

## Opérations

### Lancer un test

```bash
# 1. Choisir le nœud DANS job-cpu.yaml (nodeSelector ET nom du Job — les deux).
# 2. Armer :
git mv cluster/app/stress-test/stress-test.noapp.yaml \
       cluster/app/stress-test/stress-test.app.yaml
git commit -am "test(stress-test): charge CPU de vert-ysondre" && git push
```

Le test démarre au cycle de réconciliation suivant et dure 10 min.

### Surveiller pendant

Valeurs au repos, mesurées le 2026-09-28 — c'est la ligne de base à comparer :

| Signal | Au repos | Ce qu'un écart veut dire |
|---|---|---|
| `etcd_request_duration_seconds` p99 (vu par l'apiserver) | 5 ms | etcd souffre |
| `apiserver_request_duration_seconds` p99 GET / LIST | 5 ms / 33 ms | le control-plane décroche |
| `node_hwmon_temp_crit_alarm_celsius` | 0 | à 1, le throttling a commencé |
| Package CPU | 52-59 °C | Tjmax 100 °C |
| `kube_node_status_condition{condition="Ready"}` | 1 | à 0, **arrêter immédiatement** |

Le dashboard « Machines — system » suffit pour les trois derniers ; la tuile « Hottest sensor »
donne l'instantané et la moyenne 5 min côte à côte, ce qui distingue le palier du pic.

### Arrêter

```bash
git mv cluster/app/stress-test/stress-test.app.yaml \
       cluster/app/stress-test/stress-test.noapp.yaml
git commit -am "test(stress-test): fin de la charge" && git push
```

⚠️ **En urgence**, quand attendre un cycle ArgoCD n'est pas acceptable :
`kubectl -n stress-test delete job --all`. **Cela ne suffit pas** : `selfHeal: true` recrée le Job
et le test repart. Il faut d'abord couper la synchronisation automatique de l'Application, ou
passer par le renommage ci-dessus. Le savoir AVANT d'en avoir besoin.

### Rejouer le test

`kubectl -n stress-test delete job --all` — `selfHeal` le recrée, donc il se relance. C'est
l'unique effet de bord utile du piège décrit juste au-dessus. La voie propre reste le
renommage `.noapp.yaml` → `.app.yaml`.

### Ce qu'on cherche à apprendre

1. **Le plafond thermique** : jusqu'où monte le package à 12 cœurs chargés, et à quelle distance
   des 100 °C de Tjmax.
2. **Le throttling** : `node_hwmon_temp_crit_alarm_celsius` passe-t-il à 1. Au repos il est à 0
   depuis au moins 7 jours.
3. **La règle d'alerte** : `MachineSensorNearCritical` se déclenche-t-elle vraiment (85 % du seuil
   constructeur, soit 85 °C côté CPU). Une règle jamais vue sonner n'est pas une règle vérifiée.
4. **L'écart entre nœuds** : `vert-eranikus` tourne 5-6 °C au-dessus de `vert-ysondre` au repos.
   Charge réelle ou position physique dans la pile ? Charger successivement les deux, à charge
   égale, tranche la question que les métriques au repos ne peuvent pas trancher.

## État

**Non déployé** (`.noapp.yaml`), et c'est l'état normal. Aucun test n'a encore été exécuté au
2026-09-28 — les chiffres de ce README sont des mesures AU REPOS, pas des résultats de charge.
