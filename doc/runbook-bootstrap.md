---
title: Bootstrap / disaster recovery — procédure générique
type: runbook
tags: [homelab, wittnerlab, kubernetes, argocd, gitops, bootstrap, disaster-recovery, runbook]
created: 2026-07-17
modified: 2026-08-11
status: stable
---

# Bootstrap / disaster recovery

> [!NOTE]
> **Objet** — amener un cluster Kubernetes **vierge** à l'état complet décrit par ce repo : tous
> les composants de `cluster/` qui le désignent, déployés et réconciliés par ArgoCD.
>
> Cette procédure est **générique** : elle vaut pour tout cluster du repo. Les valeurs propres à
> un cluster (IP, wildcard DNS, disque, inventaire des secrets) vivent dans sa
> **conventions du dépôt** : [`conventions.md`](conventions.md).

> [!IMPORTANT]
> **Toutes les commandes de ce runbook se lancent depuis la racine du clone**
> (`homelab_gitops/`), sans `cd` intermédiaire. Tous les chemins sont relatifs à cette racine.
> Règle valable pour toute la documentation du repo.

## Paramétrage — à exporter avant tout

La variable ci-dessous rend chaque commande du runbook copiable telle quelle.

```bash
export CLUSTER=bleu-kalecgos     # nom du cluster, tel que porté par son Secret d'enregistrement
```

Le wildcard interne n'est **pas** paramétré : il n'y a qu'un cluster et le listener interne sert
`*.lan.wittner.tech`, sans préfixe de cluster (cf. [reseau.md](reseau.md)).

⚠️ `${CLUSTER}` n'est **plus** un dossier de premier niveau : l'arbre de déploiement est unique
(`cluster/`). La variable nomme le cluster — donc son Secret d'enregistrement
(`cluster-${CLUSTER}`), le suffixe de son backup de clé, et les sous-dossiers qu'il aurait dans
un composant multi-cluster (`cluster/infra/<name>/${CLUSTER}/`). Le repo n'ayant plus qu'un
cluster, aucun composant n'est aujourd'hui dans ce cas : tous sont des `Application`.

> [!NOTE]
> **Le dépôt est mono-cluster.** `bleu-kalecgos` est le seul cluster, et il héberge son propre
> ArgoCD : toutes les étapes de ce runbook s'appliquent, dans l'ordre. Les mécanismes multi-cluster
> (hub/spoke, `ApplicationSet`, préfixe `<cluster>-`) restent décrits dans
> [conventions.md](conventions.md), mais **aucun n'est en service** — il n'y a pas de spoke à
> enregistrer, pas de fiche cluster, et pas d'étape 2bis.

## Point d'entrée — ce qu'on suppose déjà là

Le provisionnement du nœud est **hors périmètre de ce repo**. Ce runbook démarre au moment où
les quatre conditions ci-dessous sont réunies :

| Condition | Pourquoi | Vérification |
|---|---|---|
| Un cluster Kubernetes **propre** (aucune charge, aucun composant applicatif) | Le repo est la seule source de vérité : un reliquat non géré finit en dérive ou en conflit d'adoption | `kubectl get ns` → uniquement les namespaces système |
| **Aucun CNI installé** | Cilium est posé par ce runbook (étape 1) et doit être le seul CNI ; deux CNI = réseau cassé | `kubectl get pods -A` → CoreDNS en `Pending` (attendu, il attend le CNI) |
| Un **kubeconfig** valide pointant sur ce cluster | Toutes les commandes en dépendent | `kubectl cluster-info` |
| **kube-proxy absent** | Cilium tourne en `kubeProxyReplacement: true` | `kubectl -n kube-system get ds` → pas de `kube-proxy` |

**Contraintes de nœud** attendues par certains composants, à satisfaire au provisionnement.
Les **valeurs exactes** (endpoint apiserver, étiquette de partition…) sont dans la fiche du
cluster :

| Attente | Composant concerné | Effet si absente |
|---|---|---|
| Un endpoint apiserver joignable en local sur le nœud | `cilium` (`k8sServiceHost`/`k8sServicePort` de son `helm-values.yaml`) | Agent Cilium incapable de joindre l'apiserver sans kube-proxy |
| `/sys/fs/cgroup` déjà monté par l'hôte (`cgroup.autoMount.enabled: false`) | `cilium` | Agent en `CrashLoopBackOff` |
| Modules noyau `dm_mod`, `dm_thin_pool`, `dm_snapshot` chargés **sur chaque nœud** | `openebs` | `pvcreate`/`vgcreate` échouent dans le DaemonSet de bootstrap du VG |
| Une **partition brute** étiquetée (partlabel dans la fiche) **sur chaque nœud** | `openebs` | DaemonSet VG jamais `Healthy`, pas de StorageClass, tous les PVC `Pending` |
| PodSecurity `baseline` appliqué au cluster, `kube-system` exempté | `openebs`, `alloy`, `kube-prometheus-stack` | Rien : les namespaces concernés sont labellisés `privileged` par leurs manifestes |
| Une entrée DNS wildcard `*.lan.wittner.tech` → `192.168.1.80`, **et** les noms déclarés au reverse proxy `192.168.1.50` | exposition HTTP | Les URLs ne résolvent pas, ou répondent 404 ; le cluster, lui, est sain |

---

## Prérequis outillage

- `kubectl` récent (kustomize intégré, avec support des ressources distantes — l'install ArgoCD
  tire `raw.githubusercontent.com`).
- `helm` (un seul usage : l'install Cilium de l'étape 1).
- `kubeseal` (scellement des 2 SealedSecrets, étapes 3 et 8a).
- `argocd` CLI — optionnel, seulement pour le mot de passe admin (étape 2).
- Clone de `homelab_gitops` à jour : `https://github.com/jbwittner/homelab_gitops.git`
  (dépôt **public** → clone HTTPS anonyme, aucun credential Git côté cluster).

```bash
kubectl version --client
helm version --short
kubeseal --version
git -C . rev-parse --abbrev-ref HEAD     # doit être `main` à jour
```

> [!NOTE]
> **`grep` peut être aliasé sur `rg`** (ripgrep) : `rg` interprète `-E` comme `--encoding` et
> ignore `-A` façon GNU grep. Les commandes de ce runbook utilisent `command grep` pour forcer
> le vrai `grep`.

---

## Prérequis credentials — à réunir AVANT de commencer

> [!CAUTION]
> **Tout est reconstructible depuis Git, sauf les secrets** — et ils empruntent désormais **un
> seul** canal : les onze `SealedSecret` du repo, tous indéchiffrables sans la **clé privée du
> contrôleur sealed-secrets**. Un unique backup, mais sans aucune redondance.
>
> Repartir sans cette clé n'est pas un bootstrap : c'est un re-provisionnement de **tous** les
> secrets du dépôt (étape 8), avec les credentials amont à récupérer un par un — clé GCP des deux
> buckets de sauvegarde comprise, ce qui suppose d'en réémettre.
>
> ⚠️ Ordre load-bearing en reprise : **la clé sealed-secrets se restaure AVANT toute tentative de
> restauration velero ou barman.** Sans elle, `velero-gcs` et `forgejo-db-gcs` sont indéchiffrables
> et aucune sauvegarde n'est lisible.

### 1. La clé sealed-secrets (le credential critique)

**Ce que c'est** : un `Secret` `kubernetes.io/tls` (`tls.crt` + `tls.key`) du namespace
`sealed-secrets`, porteur du label `sealedsecrets.bitnami.com/sealed-secrets-key: active`. Le
backup est un manifeste `kind: List` réapplicable tel quel.

**La clé est propre au cluster qui héberge le contrôleur.** Nommer le backup en conséquence
(`sealed-secrets-key-<cluster>.yaml`) — le motif `.gitignore` `*sealed-secrets-key*.yaml` les
couvre tous.

⚠️ **La rotation automatique est coupée** (`keyrenewperiod: "0"`, cf.
[sealed-secrets](../cluster/infra/sealed-secrets/README.md)) : il n'y a qu'**une** clé active, donc
un seul fichier à garder — mais aussi aucune génération de secours si celui-ci est perdu.

**Où la trouver**, dans l'ordre :

1. **Le gestionnaire de mots de passe / stockage hors ligne** — source de vérité, hors cluster,
   hors Git. C'est la seule copie qui survit à la perte du nœud **et** à la perte du poste.
   (Ce rôle a été tenu par un coffre déployé dans le cluster, retiré depuis.)
2. **`sealed-secrets-key-${CLUSTER}.yaml` à la racine du clone** — copie de travail, couverte par
   `.gitignore`. Elle disparaît avec le clone : ce n'est **pas** un backup.
3. **Le cluster encore en vie** — si le cluster n'est pas encore détruit, refaire le backup
   maintenant, avant toute opération destructive :

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-${CLUSTER}.yaml
```

**Vérifier le fichier avant de commencer** (aucune donnée sensible affichée) :

```bash
command grep -c 'tls.key' sealed-secrets-key-${CLUSTER}.yaml                      # ≥ 1
command grep -c 'sealed-secrets-key: active' sealed-secrets-key-${CLUSTER}.yaml   # ≥ 1
```

Absence de sortie ou `0` → le fichier n'est pas une clé exploitable : retrouver le backup hors
ligne **avant** de continuer.

### 2. Ce que cette clé protège

**Onze fichiers, treize documents `SealedSecret`.** Trois d'entre eux sont **bloquants au
bootstrap**, dans cet ordre :

| Secret | Composant | Ce que sa perte coûte |
|---|---|---|
| `repo-homelab-gitops` | [argocd](../cluster/infra/argocd/README.md) | le dépôt est **privé** : sans ce credential SSH, `argocd-repo-server` ne clone rien et **toutes** les Applications tombent en `ComparisonError` — `argocd` compris, puisqu'il est self-managed |
| `cloudflare-api-token` | [cert-manager](../cluster/infra/cert-manager/README.md) | pas de DNS-01, donc pas de certificat, donc aucun listener TLS opérationnel sur `shared-gw` |
| `velero-gcs` + `forgejo-db-gcs` | [velero](../cluster/infra/velero/README.md), [forgejo](../cluster/app/forgejo/README.md) | **aucune sauvegarde n'est lisible** : ce sont les credentials des deux buckets GCS |

Les huit autres (`argocd-oidc`, `argocd-notifications-secret`, `forgejo-admin`, `forgejo-secrets`,
`forgejo-smtp`, `grafana-admin`, `alertmanager-smtp`, `hermes-env`, `renovate-github`) ne bloquent
pas l'amorçage : leur composant démarre en `CreateContainerConfigError` ou tourne dégradé, ce qui
est visible et rattrapable.

### 3. Les autres credentials (première construction, ou re-provisionnement)

À avoir sous la main **avant** l'étape 8 : token API Cloudflare, deploy key SSH du dépôt (côté
GitHub), clés de compte de service GCP des deux buckets, PAT GitHub pour Renovate, credentials du
relais SMTP. Les credentials qui dépendent d'un service déployé par le cluster lui-même (ex. un
token de service account Grafana pour les notifications ArgoCD) se créent après coup, une fois ce
service en marche.

⚠️ **Une clé de compte de service GCP ne se récupère pas** : elle ne sort pas d'un état Terraform
sans l'y stocker en clair. Si la clé sealed-secrets est perdue, il faut en **réémettre** de
nouvelles (`gcloud iam service-accounts keys create`) et resceller.

> [!CAUTION]
> **Secrets — règle générale.** Les templates en clair `*.secret.yaml` sont **gitignorés** et ne
> doivent jamais quitter le poste ni survivre au scellement. Les `*.secret.example.yaml`, eux, sont
> committés : ils ne portent que des `REMPLACER` et la procédure. Seuls les `*.sealed.yaml` sont
> committés avec du contenu. Backup de la clé sealed-secrets : hors ligne uniquement, jamais dans
> Git.

---

## Chaîne de dépendances (acyclique)

> [!IMPORTANT]
> **L'ordre n'est pas négociable.** Chaque étage dépend du précédent. La valeur de ce runbook,
> ce sont les dépendances — les commandes, elles, sont triviales.

```
0. Cluster vierge, sans CNI, kubeconfig en main
1. Cilium (CNI) — sans lui, RIEN ne schedule
2. ArgoCD (kustomize épinglé, apply -k)          ← geste manuel n°1
3. Clé sealed-secrets restaurée                  ← geste manuel n°2 (DR uniquement)
3bis. Secret repo-homelab-gitops posé à la main  ← geste manuel n°3 — le dépôt est PRIVÉ
4. Tier-1 app-of-apps (apply cluster/root.yaml)  ← geste manuel n°4, UNE FOIS
     └─ déroule seul : gateway-api (-10) → sealed-secrets (-8) → cert-manager (-5)
        → argocd (-1) / cnpg-barman-plugin (-1) → cilium, openebs, cnpg,
          kube-prometheus-stack, forgejo, hermes, renovate (0) → velero (1)
        → les quatre *-monitoring (2)
        (infra et app sont deux app-of-apps SŒURS : aucune wave de l'un n'ordonne l'autre)
5. Exposition : Gateway programmée + restart one-shot de cilium-operator + DNS + reverse proxy
6. TLS Let's Encrypt (DNS-01) sur les deux wildcards
7. Stockage : namespace privileged → DaemonSet VG → StorageClass
8. Scellement des secrets applicatifs (première construction uniquement)
```

> [!IMPORTANT]
> **L'étape 3bis n'existait pas quand ce runbook a été écrit.** Le dépôt est passé en visibilité
> privée : `argocd-repo-server` ne peut plus le cloner anonymement. Le Secret `repo-homelab-gitops`
> doit donc être posé **à la main avant `cluster/root.yaml`** — son `SealedSecret` ne peut pas s'en
> charger, puisqu'à ce moment ni la CRD `SealedSecret` n'existe, ni le dépôt n'est lisible. Il ne
> fait ensuite que le **reprendre en gestion**. Cf.
> [argocd](../cluster/infra/argocd/README.md) §Accès au dépôt privé.

⚠️ **Les sync-waves n'ordonnent qu'à l'intérieur d'un même app-of-apps.** `cluster/infra/` et
`cluster/app/` sont deux Applications sœurs synchronisées en parallèle : une wave d'`infra` ne
garantit rien vis-à-vis d'un composant d'`app`. C'est la raison pour laquelle **velero est un
composant d'infra** — c'est ce qui lui permet de porter la wave `1`, donc d'être ordonné après la
StorageClass d'openebs. À l'inverse, `cnpg-barman-plugin` (wave `-1`) et `cnpg` (wave `0`) sont
ordonnés entre eux parce qu'ils partagent le même app-of-apps, `app/`.

| Étape | Ce qui casse si tu la sautes |
|---|---|
| 1. Cilium | Aucun CNI → tous les pods restent `Pending`, CoreDNS compris |
| 2. ArgoCD | Pas de contrôleur GitOps → rien ne se réconcilie, tout le reste est mort-né |
| 3. Clé sealed-secrets | Contrôleur démarré avec une clé **neuve** → les onze SealedSecrets du repo sont indéchiffrables, tout est à resceller — y compris les credentials GCS, qui sont à **réémettre** |
| 3bis. Secret `repo-homelab-gitops` | Le dépôt est privé : `argocd-repo-server` ne clone rien, **toutes** les Applications tombent en `ComparisonError`, `argocd` compris |
| 4. Tier-1 | Les Applications n'existent pas : ArgoCD tourne à vide |
| 5. Exposition | Sans restart de `cilium-operator` à la 1re pose des CRDs, la Gateway reste `Pending` ; sans secret TLS, le listener reste `ResolvedRefs=False` |
| 6. Token du provider DNS | DNS-01 bloqué, `Certificate` jamais `Ready`, aucun accès HTTPS valide |
| 7. Label PSA sur `openebs` | DaemonSets `lvm-node` et `lvmvg-bootstrap` (privileged) rejetés par l'admission `baseline` |
| 8. Scellement des secrets | Chaque composant concerné démarre en `CreateContainerConfigError` (`envFrom` ou `existingSecret` pointant un Secret absent) : Forgejo, Grafana, Hermes, Renovate. Panne franche et lisible, pas silencieuse |

> [!NOTE]
> **Rebuild à froid vs première construction.** Toutes les Applications vivent déjà dans le repo :
> après l'étape 4, les étapes 5 à 7 **convergent seules** dans l'ordre des sync-waves. En rebuild,
> ce runbook est une **checklist de vérification** autour de quatre gestes manuels irréductibles :
> l'`apply -k` d'ArgoCD, la restauration de la clé sealed-secrets, la pose du Secret
> `repo-homelab-gitops`, et le restart one-shot de `cilium-operator`. L'étape 8 (scellement des secrets) et la parenthèse autosignée de l'étape 6
> ne concernent que la **première construction**.

---

## Étape 1 — Cilium (CNI)

> [!IMPORTANT]
> **Sans CNI, rien ne schedule.** Le cluster est livré sans CNI : tous les pods, CoreDNS compris,
> restent `Pending` jusqu'à ce que Cilium tourne.

Cilium est aujourd'hui un composant **mono-cluster** : une `Application`
([`cluster/infra/cilium/cilium.app.yaml`](../cluster/infra/cilium/cilium.app.yaml)) qui porte la
version du chart et pointe un `helm-values.yaml` unique. Version et values ont donc une **source
unique** dans le repo : ne jamais les retaper à la main — les lire.

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update cilium

CILIUM_VERSION="$(command grep -A3 'chart: cilium' cluster/infra/cilium/cilium.app.yaml \
  | command grep 'targetRevision:' | awk '{print $2}')"
echo "Cilium ${CILIUM_VERSION}"     # doit correspondre au targetRevision de l'Application

helm install cilium cilium/cilium --version "${CILIUM_VERSION}" -n kube-system \
  -f cluster/infra/cilium/helm-values.yaml
```

> [!WARNING]
> **Le `--version`, le `releaseName` et les values sont load-bearing.** La release
> **doit** s'appeler `cilium` : l'Application `cilium` (étape 4) *adopte* ce release. Un
> nom différent renommerait toutes les ressources Cilium et détruirait le CNI. Une version — ou un
> jeu de values — différent de celui de l'Application la ferait diverger dès le premier sync.

> [!NOTE]
> **Bootstrap d'un second cluster.** Cilium redeviendrait alors multi-cluster (`ApplicationSet`,
> values en deux couches `common/` + `${CLUSTER}/`, cf.
> [`cluster/infra/cilium/README.md`](../cluster/infra/cilium/README.md)) : c'est la migration à
> faire **avant** cette étape, et les chemins ci-dessus deviennent
> `cluster/infra/cilium/{cilium.appset.yaml,common/helm-values.yaml}` plus l'éventuelle surcharge
> `${CLUSTER}/helm-values.yaml`, passée **après** la couche commune.

**Vérification :**

```bash
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system get pods -l k8s-app=kube-dns      # CoreDNS passe Running
```

> [!NOTE]
> **Reprise en main par ArgoCD.** Ce `helm install` est le **seul geste Helm** du bootstrap. Une
> fois le tier-1 lancé (étape 4), l'Application `cilium` (chart + `$values` + `manifests/`
> ip-pool/l2-policy) adopte le release et passe `Synced` sans rien changer.

---

## Étape 2 — ArgoCD

> [!NOTE]
> [!IMPORTANT]
> **Pas de Helm ici.** ArgoCD s'installe depuis le dossier auto-contenu
> `cluster/infra/argocd/manifests/` : kustomize avec install upstream **épinglé** (le tag
> exact vit dans `kustomization.yaml`, source unique) + namespace + patchs
> (`argocd-cmd-params-cm`, `argocd-cm`, `argocd-rbac-cm`, `argocd-notifications-cm`) + la
> HTTPRoute UI + les Secrets de cluster. Ce **même dossier** sert à l'apply manuel du bootstrap
> **et** au self-management (`argocd.app.yaml`, wave -1, même `path`) → convergence garantie.

### 2.1 Installer

```bash
kubectl apply -k cluster/infra/argocd/manifests --server-side --force-conflicts
```

> [!WARNING]
> **`--server-side --force-conflicts` obligatoire.** Sans SSA : `metadata.annotations: Too long`
> sur les CRDs ApplicationSet. Et le mode doit **matcher** le `ServerSideApply=true` de
> l'Application self-managed, sinon `OutOfSync` permanent.

> [!NOTE]
> **Deux échecs attendus à ce stade**, non bloquants :
> - la **HTTPRoute** — les CRDs Gateway API n'existent pas encore ; elle convergera à l'étape 5 ;
> - les **SealedSecret** de `post-bootstrap/` — la CRD `SealedSecret` n'est posée qu'à
>   l'étape 4 ; ils convergeront ensuite. Corollaire : le dépôt privé n'est pas clonable
>   avant que le contrôleur sealed-secrets ait déchiffré leur Secret de cluster.
>
> Les `ExternalSecret` d'ArgoCD, eux, **ne sont pas concernés** : ils vivent dans
> `cluster/infra/argocd/post-bootstrap/`, hors du dossier de cet `apply -k`, précisément pour
> que leur CRD absente ne fasse pas échouer le geste d'amorçage.
>
> Si l'`apply -k` refuse **en bloc** à cause d'un type inconnu : commenter temporairement les
> lignes concernées dans `kustomization.yaml` pour le bootstrap, le self-management les reposera
> après l'étape 5. Ne pas oublier de les décommenter et de pousser.

### 2.2 Vérifier et accéder à l'UI

```bash
kubectl -n argocd get pods
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Le cluster local doit être enregistré SOUS SON NOM (Secret posé par l'apply -k ci-dessus)
kubectl -n argocd get secret cluster-${CLUSTER}

# Mot de passe admin initial (auto-généré à l'install)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# UI au bootstrap (l'exposition Gateway n'arrive qu'à l'étape 5)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080 (certificat autosigné, accepter)
```

> [!IMPORTANT]
> **Le Secret `cluster-${CLUSTER}` conditionne toute l'étape 4.** Toutes les `destination` du
> repo désignent leur cluster par `name:`, cluster local compris — sans ce Secret, ArgoCD ne
> connaît son propre cluster que sous l'entrée codée en dur `in-cluster`, et **chaque**
> Application posée à l'étape 4 tombe en `ComparisonError: cluster not found`. Il vit dans
> `cluster/infra/argocd/manifests/` justement pour être posé par l'`apply -k` ci-dessus : ne
> pas l'en sortir. Symptôme inverse (apps `Unknown` en masse après coup) → vérifier d'abord ce
> Secret.

### 2.3 Fixer le mot de passe admin

Le port-forward doit tourner dans un autre terminal.

```bash
argocd login localhost:8080 --username admin --insecure \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

argocd account update-password        # prompt interactif : ancien puis nouveau

kubectl -n argocd delete secret argocd-initial-admin-secret   # le hash actif vit dans argocd-secret
```

> [!TIP]
> **Variante sans CLI `argocd`** — patch direct du hash bcrypt dans `argocd-secret` :
> ```bash
> kubectl -n argocd patch secret argocd-secret -p \
>   '{"stringData": {
>     "admin.password": "'"$(htpasswd -nbBC 10 "" '<NOUVEAU_MDP>' | tr -d ':\n')"'",
>     "admin.passwordMtime": "'"$(date +%FT%T%Z)"'"
>   }}'
> ```

> [!NOTE]
> **Statut GitOps de ce geste.** Le mot de passe admin est un geste impératif assumé :
> `argocd-secret` n'est pas dans le kustomize, le self-management ne le réconcilie pas, le hash
> survit aux syncs. Le compte local reste le **break-glass** quand l'OIDC est en place
> (étape 8) ; il n'est pas désactivé.

---

## Étape 3 — Restaurer la clé sealed-secrets

> [!NOTE]
> [!CAUTION]
> **Geste OBLIGATOIRE en rebuild, et le plus facile à oublier.** Le contrôleur sealed-secrets
> démarre à l'étape 4 (wave -8). S'il démarre **sans** la clé restaurée, il en génère une neuve
> et tous les `SealedSecret` du repo deviennent indéchiffrables. Restaurer **avant** son premier
> démarrage — ou immédiatement après, suivi d'un restart.

Le namespace `sealed-secrets` est créé par l'Application (`CreateNamespace=true`), donc pas avant
l'étape 4. Deux façons de gagner la course, au choix :

**a. Devancer le contrôleur** — créer le namespace et poser la clé maintenant. Le namespace sera
adopté par l'Application au sync suivant :

```bash
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f sealed-secrets-key-${CLUSTER}.yaml
```

**b. Rattraper après coup** — lancer l'étape 4, puis dès que le namespace existe :

```bash
kubectl apply -f sealed-secrets-key-${CLUSTER}.yaml
kubectl rollout restart deployment/sealed-secrets -n sealed-secrets
```

**Vérifier que la clé restaurée est bien celle qui sert.** Le contrôleur conserve *toutes* les
clés pour déchiffrer, mais scelle avec la **plus récente** :

```bash
kubectl get secrets -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key --sort-by=.metadata.creationTimestamp
```

Plusieurs clés = normal. Si une clé **neuve** est plus récente que la restaurée, les prochains
scellements utiliseront la neuve (les SealedSecrets existants, eux, restent déchiffrables). Pour
revenir à un état propre : supprimer la clé neuve, puis `rollout restart`.

> [!NOTE]
> **Première construction** (aucun SealedSecret préexistant) : rien à restaurer — mais faire le
> backup **tout de suite** après l'étape 4 et le déposer au coffre :
> ```bash
> kubectl get secret -n sealed-secrets \
>   -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-${CLUSTER}.yaml
> ```

---

## Étape 4 — Tier-1 app-of-apps

**Toujours sur le HUB**, et **une seule fois pour tout le repo** :

```bash
kubectl apply -f cluster/root.yaml
```

> [!IMPORTANT]
> **Ce geste n'est pas par cluster.** L'arbre `cluster/` est commun : `root` découvre les deux
> `*.bootstrap.yaml` (`infra`, `app`), qui découvrent chacun leurs `*.app.yaml` / `*.appset.yaml`,
> tous clusters confondus. Ajouter un cluster au repo ne se termine donc **pas** par un apply :
> une fois son Secret de cluster déchiffré (étapes 2bis/3) et ses sous-dossiers committés, les
> `ApplicationSet` produisent ses Applications tout seuls. Si le hub est reconstruit, en revanche,
> ce `apply -f` est bien à refaire — c'est le seul objet du repo que rien ne pose pour lui.

Les Applications se créent et déroulent leurs sync-waves. L'Application `argocd` (wave -1)
**adopte** la config posée à l'étape 2 → `Synced` sans rien changer → self-management acté.
Les Applications `${CLUSTER}-cilium` adoptent le `helm install` de l'étape 1.

> [!CAUTION]
> **Pièges « Argo manages Argo »**
> - `prune: false` sur l'Application `argocd` — il se couperait les jambes. `selfHeal: true` OK.
> - Repo-server et application-controller peuvent redémarrer une fois après le premier sync :
>   normal, laisser se stabiliser.
> - Crash-loop après un upgrade de Kubernetes → bumper le tag Argo CD dans
>   `cluster/infra/argocd/manifests/kustomization.yaml`.
> - Le contrôleur **ApplicationSet** n'est plus load-bearing (aucun `*.appset.yaml` dans le repo) :
>   s'il ne tourne pas, ces Applications n'existent tout simplement pas — et le CNI d'un cluster
>   fraîchement bootstrappé n'est jamais adopté.

**Vérification :**

```bash
kubectl get applications -n argocd
kubectl get applicationsets -n argocd
kubectl -n argocd get app -l homelab.wittner.tech/cluster=${CLUSTER}   # les apps générées de ce cluster
```

Attendu — **20 Applications**, aucun `ApplicationSet` :

```
tier 1        root
tier 2        infra, app
infra         gateway-api, sealed-secrets, cert-manager, argocd, cilium, openebs,
              velero, openebs-monitoring, velero-monitoring
              (external-secrets est en .noapp.yaml : ABSENT, et c'est voulu)
app           cnpg-barman-plugin, cnpg, kube-prometheus-stack, forgejo, hermes, renovate,
              cnpg-monitoring, forgejo-monitoring
```

Le préfixe `<cluster>-` ne s'applique qu'aux Applications générées par un `ApplicationSet` : il
n'y en a aucune aujourd'hui (cf. [conventions.md](conventions.md)).
L'Application Cilium du cluster doit passer `Synced/Healthy` **sans rien modifier** (adoption du
`helm install` de l'étape 1).

---

## Étape 5 — Exposition (Gateway API)

Tout est déjà déclaratif : `gateway-api` (wave -10) pose les CRDs upstream épinglées, le
namespace `gateway` et le Gateway partagé `shared-gw`. Ses **deux** listeners — `https-public`
(`*.wittner.tech`) et `https-internal` (`*.lan.wittner.tech`) — sont détaillés dans
[reseau.md](reseau.md).

> [!NOTE]
> `gateway-api` est une `Application` **mono-cluster**. La `GatewayClass cilium` est
> **auto-créée par le contrôleur Cilium** — ne pas la déclarer :
> une GatewayClass posée à la main reste `Pending`, Cilium ne réconcilie pas ce qu'il ne possède
> pas.

### Les deux gestes de cette étape

```bash
# a. Le moteur Gateway est-il allumé côté Cilium (flag Helm ET CRDs présentes) ?
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-gateway-api}'   # → "true"

# b. 1re pose des CRDs : le contrôleur Gateway de Cilium ne les voit qu'après un restart de
#    l'operator. Événement UNIQUE de bootstrap, pas une dérive GitOps.
kubectl -n kube-system rollout restart deployment/cilium-operator
```

**c. DNS et reverse proxy** — le résolveur doit renvoyer `*.lan.wittner.tech` vers l'IP du
LB du cluster (la première du pool `CiliumLoadBalancerIPPool` annoncé en L2 par Cilium ; valeurs
dans la fiche). Rappel : un wildcard ne couvre qu'**un** niveau — la règle vaut pour le
certificat, le listener et l'enregistrement DNS.

**Vérification :**

```bash
kubectl -n gateway get gateway shared-gw        # PROGRAMMED=True, ADDRESS = IP du LB
kubectl -n argocd get httproute argocd-server   # Accepted
```

---

## Étape 6 — TLS Let's Encrypt (DNS-01)

`cert-manager` (wave -5) pose le moteur **et**, dans son `manifests/`, le
`ClusterIssuer letsencrypt-prod`, les `Certificate` wildcard (namespace **`gateway`**, là où
la Gateway consomme les Secrets) et le SealedSecret du token du provider DNS.

Rien à lancer : si la clé sealed-secrets est la bonne (étape 3), le token se déchiffre, le
challenge DNS-01 passe, les secrets `wildcard-*-tls` se remplissent et les listeners passent
`ResolvedRefs=True`.

**Vérification :**

```bash
kubectl -n cert-manager get secret cloudflare-api-token     # déchiffré par sealed-secrets
kubectl -n gateway get certificate                          # tous en READY=True
kubectl -n cert-manager get challenges                      # vide une fois émis
kubectl -n gateway get secrets | command grep wildcard      # les secrets TLS présents
curl -I https://argocd.lan.wittner.tech                     # SANS -k → chaîne LE valide
```

Le header `server: envoy` confirme le proxy Cilium.

> [!WARNING]
> **Résolveurs du self-check DNS-01.** cert-manager vérifie la propagation du TXT
> `_acme-challenge` via le DNS **du cluster**. Si celui-ci remonte vers un upstream qui renvoie
> NXDOMAIN sur ce nom (déjà observé avec Quad9), le challenge reste `Pending` indéfiniment.
> Remède : épingler les résolveurs récursifs dans
> `cluster/infra/cert-manager/helm-values.yaml` —
> ```yaml
> extraArgs:
>   - --dns01-recursive-nameservers=1.1.1.1:53
>   - --dns01-recursive-nameservers-only
> ```
> **État actuel du repo : non épinglé** (l'émission fonctionne sans). C'est le remède documenté,
> pas l'état déployé. Après un run avorté, nettoyer les **TXT `_acme-challenge` orphelins** chez
> le provider DNS avant de réessayer — sinon 400.

> [!NOTE]
> **Première construction seulement — la parenthèse autosignée.** Si le token du provider DNS
> n'est pas encore scellé, aucun certificat ne peut être émis et les listeners restent
> `ResolvedRefs=False`. Pour sortir du port-forward en attendant, ajouter temporairement un
> `ClusterIssuer selfsigned` dans `cluster/infra/cert-manager/manifests/` et pointer
> les `Certificate` dessus :
> ```yaml
> apiVersion: cert-manager.io/v1
> kind: ClusterIssuer
> metadata:
>   name: selfsigned
> spec:
>   selfSigned: {}
> ```
> **Tous** les secrets attendus par les listeners doivent exister, sinon les listeners
> correspondants restent `ResolvedRefs=False`. `curl -kI` est alors l'état attendu. La bascule
> vers Let's Encrypt = sceller le token (étape 8), repointer les `issuerRef` sur
> `letsencrypt-prod`, supprimer l'issuer autosigné (le prune ArgoCD fait le ménage). Le repo est
> aujourd'hui à l'état final : ce fichier n'existe pas.

---

## Étape 7 — Stockage (OpenEBS LVM)

L'Application `openebs` déploie le moteur LocalPV-LVM et, dans `manifests/`, l'ordonnancement
irréductible par sync-waves de **ressource** :

```
namespace `openebs` labellisé PSA privileged (-1)
  → DaemonSet `lvmvg-bootstrap` (0) : pvcreate + vgcreate sur la partition brute, SUR CHAQUE NŒUD
    → StorageClass (1)
```

Nom du VG, partlabel de la partition et nom de la StorageClass : dans la fiche du cluster.

Rien à lancer à la main. Le label PSA `privileged` sur le namespace est ce qui autorise les deux
DaemonSets — node-plugin et bootstrap du VG, tous deux `privileged` — sous une admission
`baseline` : c'est un mécanisme natif, chirurgical et versionné, préféré à toute modification de
la configuration d'admission du cluster.

> [!NOTE]
> **Bootstrap du VG.** LocalPV-LVM ne provisionne **pas** le Volume Group, il l'exige préexistant.
> Le VG est donc créé par un conteneur privilégié qui embarque `lvm2` (la même image que le
> node-plugin), à partir de la partition brute étiquetée. C'est le seul état réel sur disque, non
> réconciliable par GitOps — le script est **idempotent** (skip si PV/VG déjà présents).
>
> Le stockage étant **node-local**, il faut un VG par nœud : d'où un DaemonSet et non un Job. Un
> nœud ajouté après le bootstrap est traité automatiquement (pod → VG), à condition qu'il porte la
> partition brute et les modules noyau. La StorageClass (wave 1) attend que le DaemonSet soit
> `Healthy`, c'est-à-dire que **tous** les nœuds schedulables aient leur VG.

**Vérification :**

```bash
kubectl get ns openebs --show-labels            # pod-security.kubernetes.io/enforce=privileged
kubectl -n openebs get pods -o wide             # controller + node plugin + bootstrap Running, par nœud
kubectl -n openebs get ds lvmvg-bootstrap       # DESIRED == READY ⇒ un VG sur chaque nœud
kubectl -n openebs logs -l app.kubernetes.io/component=vg-bootstrap -c vg-bootstrap --prefix --tail=-1
kubectl get sc
```

Le **smoke test** de stockage (PVC + pod + Cluster CNPG) dépend des composants déployés : voir la
fiche du cluster.

---

## Étape 8 — Sceller les secrets applicatifs (première construction)

Un seul canal : **sealed-secrets**. Le second (un backend externe via external-secrets) n'existe
plus — cf. [regles-gitops.md](regles-gitops.md).

En **rebuild**, cette étape est déjà faite : les `*.sealed.yaml` du repo se déchiffrent seuls dès
que la bonne clé est en place (étape 3). Elle ne sert qu'à une première construction ou à un
re-provisionnement complet après perte de la clé.

**Le cert public du contrôleur, une fois** (`pub-cert.pem` est gitignoré) :

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem
```

**Boucle de scellement, identique pour tous** — partir du `*.secret.example.yaml` versionné, le
recopier en `*.secret.yaml` (gitignoré), le renseigner, sceller, supprimer le clair, committer le
`*.sealed.yaml` :

```bash
D=cluster/<infra|app>/<composant>/manifests
cp $D/<secret>.secret.example.yaml $D/<secret>.secret.yaml
$EDITOR $D/<secret>.secret.yaml                       # remplacer les REMPLACER

kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < $D/<secret>.secret.yaml > $D/<secret>.sealed.yaml
rm $D/<secret>.secret.yaml
```

⚠️ **Décommenter la ligne du `kustomization.yaml` DANS LE MÊME COMMIT que le fichier scellé.** Une
ligne pointant un fichier absent casse le `kustomize build` **entier**, donc l'Application. Et un
fichier scellé **vide** ne casse rien : kustomize l'accepte et ne rend rien — vérifier le contenu,
pas l'existence.

### L'ordre, et ce qui bloque quoi

| Ordre | Secret | Composant | Bloquant ? |
|---|---|---|---|
| 1 | `repo-homelab-gitops` | argocd | **oui** — fait à l'étape 3bis, avant même le tier-1 |
| 2 | `cloudflare-api-token` | cert-manager | **oui** — sans lui, pas de DNS-01, donc aucun listener TLS (étape 6) |
| 3 | `velero-gcs`, `forgejo-db-gcs` | velero, forgejo | non pour démarrer, **oui** pour toute sauvegarde ou reprise |
| 4 | `forgejo-admin` (3 documents), `grafana-admin`, `hermes-env`, `renovate-github` | forgejo, kube-prometheus-stack, hermes, renovate | non — le pod reste en `CreateContainerConfigError`, panne franche |
| 5 | `alertmanager-smtp`, `argocd-notifications-secret`, `argocd-oidc` | kube-prometheus-stack, argocd | non — dégradation silencieuse : pas de mail, pas d'annotation Grafana, pas de SSO |

Deux dépendances structurent cet ordre :

- les credentials qui viennent d'un **service déployé ici** (clé d'API Grafana pour les
  notifications ArgoCD) se créent **après** que ce service tourne ;
- les clés de **compte de service GCP** viennent du repo Terraform ; une clé JSON ne se sort pas
  d'un état Terraform sans l'y stocker en clair, donc elle s'émet à la main
  (`gcloud iam service-accounts keys create`) — cf.
  [forgejo](../cluster/app/forgejo/README.md) §Câblage du credential GCS.

**Et immédiatement après : sauvegarder la clé sealed-secrets hors ligne** (cf. étape 3). À partir
de maintenant, elle seule ouvre les onze `SealedSecret`.

---

## Vérification finale

```bash
kubectl get applications -n argocd                       # toutes Synced/Healthy
kubectl get nodes                                        # Ready
kubectl -n gateway get gateway shared-gw                 # PROGRAMMED=True
kubectl -n gateway get certificate                       # tous READY=True
kubectl get sc                                           # openebs-lvm-thin (default)
kubectl get sealedsecrets -A                             # tous SYNCED=True
kubectl get secret -A -l app.kubernetes.io/part-of=homelab-gitops
curl -I https://argocd.lan.wittner.tech
curl -I https://forgejo.wittner.tech
```

> [!NOTE]
> Un `SealedSecret` en `Synced=False` alors que tout le reste est vert : soit la clé du contrôleur
> n'est pas celle qui a scellé (étape 3), soit le `Secret` cible **préexiste sans
> `ownerReference`** — « already exists and is not managed by SealedSecret ». Le second cas arrive
> après une restauration velero qui a recréé le Secret : c'est précisément pourquoi les quatre
> Secrets reproductibles depuis Git portent `velero.io/exclude-from-backup` (cf.
> [forgejo-pra.md](forgejo-pra.md) §5).

> [!IMPORTANT]
> **Un 404 sur un hostname `*.lan.wittner.tech` alors que le `HTTPRoute` est `Accepted` n'est pas
> un problème de cluster** : le nom doit être déclaré au reverse proxy `192.168.1.50`. Cf.
> [reseau.md](reseau.md).

---

## Pièges rencontrés (mémo)

- **Apply non-SSA après un apply SSA** (ou l'inverse) sur ArgoCD → `OutOfSync` permanent :
  l'apply manuel et l'Application self-managed doivent être **tous deux** server-side.
- **`GatewayClass` déclarée à la main** → `ACCEPTED: Unknown / Pending`. Cilium ne réconcilie pas
  une GatewayClass qu'il ne possède pas ; la laisser s'auto-créer.
- **CRDs Gateway API posées après Cilium** → contrôleur Gateway aveugle tant que
  `cilium-operator` n'a pas redémarré (one-shot de bootstrap).
- **Defaults CRD Gateway API** (`group`, `kind`, `weight`, `matches`) injectés côté live →
  `OutOfSync` permanent s'ils ne sont pas explicités dans les HTTPRoute.
- **Contrôleur sealed-secrets démarré avant restauration de la clé** → clé neuve, SealedSecrets
  du repo indéchiffrables. C'est l'erreur la plus coûteuse du runbook.
- **Clé sealed-secrets d'un autre cluster** restaurée par erreur → même effet. Un contrôleur, une
  clé : vérifier le suffixe du fichier de backup.
- **Secret restauré par velero par-dessus un `SealedSecret`** → le contrôleur refuse de
  s'approprier un objet préexistant, la `SealedSecret` reste `Synced=False` et le `Secret` devient
  orphelin : les rotations faites dans Git ne se propagent plus, **en silence**.
- **Dépôt privé et Secret `repo-homelab-gitops` absent** → `ComparisonError` sur **toutes** les
  Applications, `argocd` compris : l'outil avec lequel on diagnostiquerait est aussi la victime.
- **Fichier référencé mais absent dans un `kustomization.yaml`** (typiquement un `*.sealed.yaml`
  pas encore scellé) → `kustomize build` échoue, l'Application entière part en erreur.
- **`bpf.masquerade=true` côté Cilium** ne cohabite pas avec un forward du DNS cluster vers
  l'hôte : CoreDNS casse. Laisser `bpf.masquerade` désactivé.
- **Quad9 comme résolveur des self-checks DNS-01** → NXDOMAIN sur `_acme-challenge` ; épingler
  `1.1.1.1`. TXT orphelins d'un run avorté = 400 côté provider DNS.
- **Suffixe de fichier incorrect** (`.noapp.yaml` au lieu de `.app.yaml`, ou l'inverse) → le glob
  du tier-2 ne ramasse pas le composant, et **rien ne le signale** : l'Application n'existe
  simplement pas. C'est l'état voulu pour `external-secrets` ; c'en est un piège partout ailleurs.
- **PVC seul en `Pending`** → normal : `WaitForFirstConsumer`, le volume n'est taillé que quand un
  pod consomme le PVC.
