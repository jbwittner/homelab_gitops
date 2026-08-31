# hermes-exec

## Rôle

**Environnements d'exécution jetables** pour l'agent [hermes](../hermes/README.md) : un pod par
tâche, isolé, sans droits, sans secrets, sans sortie internet, détruit après usage.

Ce composant ne met en place **que le cadre**. Il ne déploie pas l'agent orchestrateur, ne crée
aucun secret et ne câble aucun accès Git/Artifactory — cf. §Points d'extension.

Séparation structurante :

| | Où | Qui l'applique |
| --- | --- | --- |
| **Le cadre** (ns, identité, policies, plafonds) | `manifests/` | ArgoCD, en GitOps |
| **Les tâches** (Jobs éphémères) | `templates/` | `kubectl create`, à la demande |

`templates/` est **hors du `path` de l'Application**, et c'est load-bearing : un Job placé dans
`manifests/` serait recréé en boucle par `selfHeal` chaque fois que son `ttlSecondsAfterFinished`
le supprime. Le TTL et le GitOps se battraient sans qu'aucun log ne le signale (ArgoCD resterait
`Synced`).

## Fichiers

- `hermes-exec.noapp.yaml` — Application. Livrée **désactivée** : le glob de
  [`app.bootstrap.yaml`](../app.bootstrap.yaml) n'accepte que `*.app.yaml` / `*.appset.yaml`
  (cf. §Activation)
- `manifests/namespace.yaml` — ns `hermes-exec` (`sync-wave: -1`), labellisé PodSecurity
  **`restricted`**
- `manifests/serviceaccount.yaml` — `hermes-exec-runner`, **sans aucun Role ni RoleBinding**,
  `automountServiceAccountToken: false` ; neutralise aussi le SA `default` du namespace
- `manifests/netpol-default-deny.yaml` — `CiliumNetworkPolicy` de refus par défaut, **ingress et
  egress**, sur le label de rôle
- `manifests/netpol-egress-allow.yaml` — **NON APPLIQUÉ** : absent des `resources:` du
  kustomization. Conservé comme point d'extension (cf. §Points d'extension)
- `manifests/resourcequota.yaml` — plafond du namespace, **dimensionné pour 5 tâches
  concurrentes** ; `persistentvolumeclaims: 0`
- `manifests/limitrange.yaml` — défauts et maxima par conteneur. **Se revoit avec le quota** :
  le tableau de correspondance est en tête de `resourcequota.yaml`
- `manifests/kustomization.yaml` — assemblage
- `templates/task-job.yaml` — **le modèle** de tâche, paramétrable
- `templates/demo-task-job.yaml` — tâche de démonstration inoffensive (cf. §Démonstration)

## Le modèle d'isolation

Cinq couches, indépendantes. Aucune n'est décorative.

1. **Aucune identité.** SA `hermes-exec-runner` sans le moindre RoleBinding, token non monté
   (`automountServiceAccountToken: false` sur le SA *et* sur le pod). Le SA `default` du namespace
   est neutralisé de la même façon, pour couvrir un Job qui oublierait `serviceAccountName`.
2. **Admission.** Le namespace est en PodSecurity `restricted` : un pod qui omet `runAsNonRoot`,
   `allowPrivilegeEscalation: false`, le drop des capabilities ou le `seccompProfile` est
   **refusé à la création**. C'est le seul garde-fou qui ne dépend pas du contenu du manifeste.
3. **securityContext.** non-root (uid 65532), `readOnlyRootFilesystem: true`, toutes capabilities
   droppées, `seccompProfile: RuntimeDefault`. Écriture uniquement dans `/work` et `/tmp`, deux
   `emptyDir` qui meurent avec le pod.
4. **Réseau.** Défaut-refus ingress + egress sur le label `hermes.wittner.tech/role=task-runner`,
   et **rien ne le contredit** : la policy d'autorisation n'est pas appliquée. Aucune sortie
   réseau du tout — pas d'internet, pas de LAN, **pas même la résolution DNS**.
5. **Plafonds.** `ResourceQuota` + `LimitRange` : un orchestrateur qui boucle sur la création de
   tâches se fait refuser la création avec un message explicite, il n'évince pas le cluster.
   Calés sur le POC (5 tâches concurrentes, 4 CPU / 6 Gi de limites pour tout le namespace), pas
   sur la capacité du cluster — un quota large ne protège de rien.

> [!CAUTION]
> **La 6ᵉ couche attendue est absente : il n'y a pas de runtime d'isolation renforcée.**
> `kubectl get runtimeclass` renvoie vide sur ce cluster — ni gVisor/runsc, ni Kata. Les pods de
> tâche partagent le noyau du nœud avec tous les autres pods. Ce n'est pas contourné : un
> `# runtimeClassName:` commenté attend dans les deux templates. Cf. §Points d'extension.

> [!IMPORTANT]
> **Le label `hermes.wittner.tech/role: task-runner` est le contrat entre les templates et les
> policies.** Cilium tourne ici en `policy-enforcement-mode: default` : un endpoint n'est en
> défaut-refus que sur les directions couvertes par une policy **qui le sélectionne**. Un pod de
> tâche qui ne porte pas ce label exactement n'est sélectionné par aucune policy — et se retrouve
> donc avec une **sortie internet complète**. Une faute de frappe ne produit aucune erreur : elle
> ouvre le réseau en silence.

## Ordre d'application

`manifests/` est appliqué par ArgoCD, pas à la main. L'ordre interne est garanti par le
`sync-wave: -1` du namespace ; le reste n'a pas de dépendance d'ordre.

### Activation

Le composant est livré désactivé. Avant de l'activer, décider si les destinations egress
(§Points d'extension) doivent être renseignées : **elles ne sont pas nécessaires au démarrage** —
sans elles le cadre est fonctionnel, simplement les tâches n'ont aucune sortie réseau utile.

```bash
git mv cluster/app/hermes-exec/hermes-exec.noapp.yaml \
       cluster/app/hermes-exec/hermes-exec.app.yaml
```

### Vérification avant activation (aucune écriture)

```bash
kubectl kustomize cluster/app/hermes-exec/manifests > /tmp/hermes-exec.yaml

# Le namespace n'existant pas encore, un dry-run direct échoue en « namespaces not found » sur
# les 6 objets qui s'y trouvent. On reprojette sur `default` le temps de valider les schémas.
sed 's/^  namespace: hermes-exec$/  namespace: default/' /tmp/hermes-exec.yaml \
  | kubectl apply --dry-run=server --validate=strict -f -
```

Une fois l'Application active, le diff réel se lit côté ArgoCD :

```bash
kubectl -n argocd get application hermes-exec -o jsonpath='{.status.sync.status}{"\n"}'
argocd app diff hermes-exec        # si le CLI est installé
```

## Lancer un environnement de tâche

`envsubst` n'est pas installé sur le poste (gettext absent) — `sed` fait le travail.

```bash
cd cluster/app/hermes-exec/templates

sed -e 's|${TASK_ID}|ma-tache|g' \
    -e 's|${TASK_IMAGE}|<image>|g' \
    -e 's|${TASK_TTL}|600|g' \
    -e 's|${TASK_DEADLINE}|1800|g' \
    task-job.yaml | kubectl create -f -
```

| Paramètre | Sens | Contrainte |
| --- | --- | --- |
| `TASK_ID` | identifiant de tâche | nom DNS-1123 (`a-z0-9`, `-`) — sert de suffixe au Job **et** de valeur du label `hermes.wittner.tech/task` |
| `TASK_IMAGE` | image de l'exécuteur | cf. §Points d'extension |
| `TASK_TTL` | rétention **après** fin, en secondes | assez haut pour lire les logs après coup |
| `TASK_DEADLINE` | durée de vie maximale, fin ou pas | **sans lui une tâche qui boucle n'atteint jamais l'état « terminé », donc le TTL ne se déclenche jamais** |

### Suivre et détruire

```bash
kubectl -n hermes-exec get jobs,pods -l hermes.wittner.tech/role=task-runner
kubectl -n hermes-exec logs -l hermes.wittner.tech/task=ma-tache

# Destruction automatique : ttlSecondsAfterFinished, rien à lancer.
# Destruction immédiate d'une tâche :
kubectl -n hermes-exec delete job hermes-task-ma-tache

# Purge de tout ce qui traîne (le --cascade par défaut emporte les pods) :
kubectl -n hermes-exec delete jobs -l hermes.wittner.tech/role=task-runner
```

> [!NOTE]
> Aucun contrôleur permanent n'est déployé pour le nettoyage. `ttlSecondsAfterFinished` est
> intégré au `kube-controller-manager` ; la purge par label ci-dessus est le filet manuel.

## Démonstration

`templates/demo-task-job.yaml` est une instance concrète du modèle, sans aucun paramètre à
substituer et **sans aucun accès réel**. Elle vérifie six propriétés puis s'arrête :

1. l'uid n'est pas 0 ;
2. aucun token de ServiceAccount n'est monté ;
3. `/work` est écrivable (écrit puis relit un fichier) ;
4. la racine **n'est pas** écrivable ;
5. la résolution DNS d'un nom externe **échoue** ;
6. une sortie IP directe (`http://1.1.1.1/`, sans DNS) **échoue**.

Les points 4 à 6 sont des tests **négatifs** : le Job réussit quand ils échouent.

```bash
kubectl create -f cluster/app/hermes-exec/templates/demo-task-job.yaml
kubectl -n hermes-exec wait --for=condition=complete job/hermes-task-demo --timeout=120s
kubectl -n hermes-exec logs job/hermes-task-demo
```

Attendu en dernière ligne : `== TOUS LES CONTROLES PASSENT ==`.

Un `Failed` sur ce Job veut dire qu'un garde-fou manque — lire les logs, la ligne `ECHEC:` nomme
lequel. Le Job disparaît de lui-même 600 s après sa fin.

L'image `busybox:1.37.0` est tirée par le kubelet, pas par le pod : le pull ne passe pas par la
`CiliumNetworkPolicy` et n'ouvre rien. C'est vrai de toute image d'exécuteur.

## Points d'extension

Ce qui est **délibérément laissé à câbler à la main**, après revue.

### 1. Destinations egress (miroir Git interne, Artifactory)

**Aucune sortie réseau, décision explicite.** `manifests/netpol-egress-allow.yaml` existe mais
n'est **pas listé** dans `manifests/kustomization.yaml` : la CNP n'est pas créée, seul le
défaut-refus s'applique. Les exécuteurs ne peuvent même pas résoudre un nom.

Pour ouvrir, le jour venu — **les deux gestes, dans cet ordre** :

1. compléter les deux listes du fichier (`rules.dns` **et** la section 2) — elles doivent rester
   alignées, un `toFQDNs` sans `matchName` DNS correspondant ne matche jamais rien et se
   diagnostique en timeout, pas en refus ;
2. ajouter `- netpol-egress-allow.yaml` aux `resources:` du kustomization.

C'est le geste 2 qui ouvre réellement le réseau. Un fichier présent mais non listé n'est pas
appliqué, et **rien dans le cluster ne le signale** — vérifier par
`kubectl -n hermes-exec get cnp`, jamais par la présence du fichier.

> [!CAUTION]
> **Ne jamais réduire `rules.dns` à une liste vide.** `dns: []` ne veut pas dire « rien n'est
> autorisé » : Cilium y lit « aucune restriction L7 » et laisse passer **toute** résolution, noms
> externes compris — soit un canal d'exfiltration par DNS. L'objet est accepté, la policy
> s'affiche `Valid: True`, et rien ne signale le trou. C'est le contrôle n°5 de la démo qui l'a
> levé, pas la revue du manifeste. La liste doit rester non vide.

⚠️ Un hostname en `*.lan.wittner.tech` devra **aussi** être déclaré sur le reverse proxy LAN
(`192.168.1.50`), sinon la résolution aboutit et la requête finit en 404 alors que la policy est
saine.

⚠️ **Aucune sortie internet ne doit être ajoutée**, même temporairement pour installer un paquet.
Ce qu'une tâche doit avoir, elle l'a dans son image.

### 2. Secrets et accès (SSH, Git, Artifactory)

**Rien n'est câblé.** Les templates n'ont ni `env`, ni `envFrom`, ni volume de type `secret`.
Aucune clé, aucun token, aucun certificat n'a été généré.

Le canal du dépôt est [sealed-secrets](../../infra/sealed-secrets/README.md) ; un Secret pour ce
composant devra être scellé pour le couple (`<nom>`, `hermes-exec`) — un SealedSecret est chiffré
pour son nom **et** son namespace, celui de `hermes` n'est pas réutilisable ici.

Point d'insertion : le bloc commenté du conteneur dans `templates/task-job.yaml`.

⚠️ Poser un accès Git/Artifactory sur ces pods **change le modèle de menace** : jusque-là un
exécuteur compromis ne peut rien atteindre. Après, il porte une identité qui écrit quelque part.
C'est ce qui justifie que ce soit une revue séparée et pas une ligne de plus dans ce commit.

### 3. Runtime d'isolation renforcée

**Absent du cluster.** À câbler dans cet ordre :

1. extension système Talos fournissant `runsc` (ou Kata) **et** l'entrée `runtimes.` dans la
   config containerd, sur les 3 nœuds — c'est de la machine config Talos, pas du Kubernetes ;
2. un objet `RuntimeClass` — **cluster-scoped**, donc hors du périmètre de ce composant et de
   son Application ;
3. décommenter `runtimeClassName:` dans `templates/task-job.yaml` **et**
   `templates/demo-task-job.yaml`.

Tant que ce n'est pas fait, l'isolation est celle d'un conteneur durci : noyau partagé.

### 4. L'agent orchestrateur

Non déployé, non connecté. Hermes ne sait pas que ce namespace existe, et n'a aucun droit pour y
créer quoi que ce soit — son pod tourne avec `automountServiceAccountToken: false` et sans RBAC
(cf. [hermes](../hermes/README.md)).

Lui donner la capacité de créer des Jobs ici demandera un `Role` (`jobs`, `pods/log`) dans
`hermes-exec` et un `RoleBinding` vers le SA d'Hermes — **c'est-à-dire donner à un LLM le droit de
créer des pods**. À traiter comme une revue à part entière, pas comme un détail de plomberie.

## Écarts entre la phase 1 et ce modèle

| Ce que le modèle suppose | Ce que le cluster offre | Conséquence |
| --- | --- | --- |
| Runtime d'isolation renforcée | Aucune `RuntimeClass` | Isolation conteneur seulement. TODO commenté, non contourné |
| PodSecurity `restricted` applicable | `hermes` ne peut pas l'être (image root) | D'où un **namespace séparé** `hermes-exec`, qui, lui, le porte |
| CNI appliquant les NetworkPolicy | Cilium v1.20.0, `enable-l7-proxy: true` | ✅ `toFQDNs` utilisable. Enforcement `default` → le label de rôle est load-bearing |
| Plafonds de ressources | Aucun quota ni LimitRange sur le cluster | Ajoutés au namespace, calés sur 5 tâches concurrentes |
| Stockage | `openebs-lvm-thin` (défaut), local-node | Sans objet : `persistentvolumeclaims: 0`, tout est `emptyDir` |
