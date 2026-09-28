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

## Résultats — tir n°1, `vert-ysondre`, 2026-09-28 20:56 → 21:06 UTC

12 cœurs sur 16, 600 s. `stress-ng` 0.18.08 : 11 545 649 bogo ops, 7037 s de temps utilisateur
sur 9600 s disponibles (73,3 %, soit les 12 hogs à plein régime), 0 échec.

| Mesure | Au repos | Sous charge | Limite |
|---|---|---|---|
| Package CPU `vert-ysondre` | 58 °C | **82 °C** au pic, **77 °C** en palier | Tjmax 100 °C |
| Fréquence moyenne | 1,39 GHz | 3,60 GHz au pic, **3,25 GHz** en palier | turbo 4,8 GHz |
| `crit_alarm` | 0 | **0** sur toute la durée | 1 = throttling |
| NVMe (capteur le plus chaud) | 58 °C | 59,9 °C | crit 79-87 °C |
| etcd p99 (vu par l'apiserver) | 20 ms | **5 ms** | — |
| Nœuds Ready | 3/3 | **3/3** | — |
| `vert-eranikus` / `vert-itharius` | 58 / 54 °C | 60 / 58 °C | — |

**Ce que ça établit :**

1. **Le plafond est fixé par la puissance, pas par la dissipation.** La température monte à 82 °C
   pendant le burst, puis REDESCEND à 77 °C alors que la charge continue de monter — et la
   fréquence tombe de 3,60 à 3,25 GHz au même moment. C'est le PL1 qui reprend la main après la
   fenêtre de turbo. `crit_alarm` est resté à 0 : le CPU se bride sur le watt bien avant d'avoir
   chaud. Le refroidissement de ces boîtiers n'est pas le facteur limitant.
2. **18 °C de marge au pire moment.** Un homelab à 60 °C au repos n'a aucun problème thermique.
3. **La protection BestEffort fonctionne, et mieux qu'espéré.** À 75 % de CPU occupé, etcd p99 est
   passé à 5 ms — soit QUATRE FOIS MIEUX que les 20 ms au repos. Aucun nœud n'a vacillé. Le pari
   « pas de requests = poids minimal en cgroup v2 » est vérifié.
4. **Les deux autres nœuds n'ont rien senti** : +2 et +4 °C, imputables à l'air ambiant du local,
   pas à la charge.

**⚠️ CE QUE CE TIR N'A PAS ÉTABLI — et c'est le résultat le plus utile :**

- **`MachineSensorNearCritical` n'a PAS été exercée. Ni `firing`, ni même `pending`.** Son seuil
  est à 85 % de Tjmax, soit 85 °C ; le pic a été de 82 °C. **Trois degrés manquants.** La règle
  reste non vérifiée.
- Et elle est probablement **invérifiable par ce moyen** : si le PL1 plafonne la machine à 77 °C en
  régime établi, aucune charge CPU ne la fera franchir 85 °C. Ce qui confirme, par l'expérience et
  non par le raisonnement, que cette règle ne détecte PAS une charge lourde mais un
  **refroidissement dégradé** — ventilateur mort, pâte sèche, aération obstruée. C'est ce qu'on
  veut d'elle, mais ce n'est pas la justification qui avait été écrite en la créant.
- Pour l'exercer vraiment il faudrait dégrader le refroidissement physiquement, ou baisser
  temporairement le seuil de la règle. Les deux sont des choix à faire consciemment, pas des
  effets de bord d'un test de charge.
- Le `for: 10m` de la règle et le `--timeout 600s` du Job sont **exactement égaux** : même en
  franchissant le seuil, l'alerte n'aurait atteint que `pending`. Un tir destiné à la voir `firing`
  doit durer plus longtemps que son `for:` — `--timeout 1200s` avec `activeDeadlineSeconds: 1500`.

**⚠️ DÉCOUVERTE ANNEXE, qui corrige une idée reçue :** `stress-ng` signale que les 16 CPU sont
**déjà en gouverneur `powersave`**. Passer les nœuds en `powersave` pour les refroidir — piste
évoquée avant ce test — n'a donc aucun sens : c'est déjà le réglage en place, et il n'empêche ni
le turbo à 3,6 GHz ni les 82 °C.

## État

**Non déployé** (`.noapp.yaml`), désarmé le 2026-09-28 après le tir n°1. Le Job `Completed` a été
supprimé par le `prune` d'ArgoCD au renommage.

Prochain tir utile : `vert-eranikus`, pour trancher la question laissée ouverte — ses 5-6 °C
d'écart au repos avec `vert-ysondre` viennent-ils de sa charge (il porte Prometheus) ou de sa
position physique ? À charge ÉGALE, si l'écart persiste, c'est l'air ; s'il disparaît, c'était la
charge. ⚠️ Charger `vert-eranikus` ralentit Prometheus, donc l'instrument de mesure : relire le
§ Danger avant.
