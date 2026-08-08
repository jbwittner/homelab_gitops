---
title: Bootstrap / disaster recovery — procédure générique
type: runbook
tags: [homelab, wittnerlab, kubernetes, argocd, gitops, bootstrap, disaster-recovery, runbook]
created: 2026-07-17
modified: 2026-08-09
status: stable
---

# Bootstrap / disaster recovery

> [!NOTE]
> **Objet** — amener un cluster Kubernetes **vierge** à l'état complet décrit par ce repo :
> tout le contenu de `<cluster>/` déployé et réconcilié par ArgoCD.
>
> Cette procédure est **générique** : elle vaut pour tout cluster du repo. Les valeurs propres à
> un cluster (IP, wildcard DNS, disque, inventaire des secrets) vivent dans sa
> **fiche cluster** : [`doc/clusters/`](clusters/).

> [!IMPORTANT]
> **Toutes les commandes de ce runbook se lancent depuis la racine du clone**
> (`homelab_gitops/`), sans `cd` intermédiaire. Tous les chemins sont relatifs à cette racine.
> Règle valable pour toute la documentation du repo.

## Paramétrage — à exporter avant tout

Les deux variables ci-dessous rendent chaque commande du runbook copiable telle quelle. Leurs
valeurs se lisent dans la fiche du cluster visé.

```bash
export CLUSTER=bleu-kalecgos                        # dossier du cluster, à la racine du repo
export CLUSTER_DOMAIN=kalecgos.lan.wittner.tech     # wildcard interne du cluster
```

| Cluster | Fiche | État |
|---|---|---|
| `bleu-kalecgos` | [clusters/bleu-kalecgos.md](clusters/bleu-kalecgos.md) | complet — les 8 étapes s'appliquent |
| `bleu-arcanogos` | [clusters/bleu-arcanogos.md](clusters/bleu-arcanogos.md) | en construction — s'arrête à l'étape 1 |

> [!NOTE]
> **Cluster partiel.** Un cluster dont la fiche marque des composants absents s'arrête à l'étape
> correspondante : pas d'`argocd/manifests/` → pas d'étape 2 ni au-delà ; pas de `gateway-api` →
> pas d'étape 5 ; pas d'`openebs` → pas d'étape 7 ; aucun `SealedSecret` → étapes 3 et 8 sans
> objet. La fiche fait foi.

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
| Un endpoint apiserver joignable en local sur le nœud | `cilium` (`k8sServiceHost`/`k8sServicePort` de `helm-values.yaml`) | Agent Cilium incapable de joindre l'apiserver sans kube-proxy |
| `/sys/fs/cgroup` déjà monté par l'hôte (`cgroup.autoMount.enabled: false`) | `cilium` | Agent en `CrashLoopBackOff` |
| Modules noyau `dm_mod`, `dm_thin_pool`, `dm_snapshot` chargés | `openebs` | `pvcreate`/`vgcreate` échouent dans le Job de bootstrap du VG |
| Une **partition brute** étiquetée (partlabel dans la fiche) | `openebs` | Job VG en échec, pas de StorageClass, tous les PVC `Pending` |
| PodSecurity `baseline` appliqué au cluster, `kube-system` exempté | `openebs`, `alloy` | Rien : les namespaces concernés sont labellisés `privileged` par leurs manifestes |
| Une entrée DNS wildcard `*.${CLUSTER_DOMAIN}` → IP du LB du cluster | exposition HTTP | Les URLs ne résolvent pas ; le cluster, lui, est sain |

---

## Prérequis outillage

- `kubectl` récent (kustomize intégré, avec support des ressources distantes — l'install ArgoCD
  tire `raw.githubusercontent.com`).
- `helm` (un seul usage : l'install Cilium de l'étape 1).
- `kubeseal` (scellement des secrets, étapes 3 et 8).
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
> **Tout est reconstructible depuis Git, sauf les secrets.** Le repo ne contient que des
> `SealedSecret` : ils sont indéchiffrables sans la **clé privée du contrôleur sealed-secrets**.
> Repartir sans cette clé n'est pas un bootstrap, c'est un re-scellement complet de tous les
> secrets du cluster (étape 8 en entier, avec tous les credentials amont à re-provisionner).

### 1. La clé sealed-secrets (le credential critique)

**Ce que c'est** : un `Secret` `kubernetes.io/tls` (`tls.crt` + `tls.key`) du namespace
`sealed-secrets`, porteur du label `sealedsecrets.bitnami.com/sealed-secrets-key: active`. Le
backup est un manifeste `kind: List` réapplicable tel quel.

**La clé est propre à un cluster** : un contrôleur par cluster, donc une clé par cluster.
Nommer le backup en conséquence (`sealed-secrets-key-<cluster>.yaml`) — le motif `.gitignore`
`*sealed-secrets-key*.yaml` les couvre tous.

**Où la trouver**, dans l'ordre :

1. **Le coffre** — source de vérité, hors cluster, hors Git. C'est la seule copie qui survit à
   la perte du nœud **et** à la perte du poste.
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

Absence de sortie ou `0` → le fichier n'est pas une clé exploitable : aller chercher le coffre
**avant** de continuer.

### 2. Ce que cette clé protège

**L'inventaire des `SealedSecret` est propre au cluster** — il vit dans sa fiche
([`doc/clusters/`](clusters/)), avec pour chacun le namespace, les clés et la source amont à
re-provisionner. Tous deviennent illisibles si la clé est perdue.

Un secret y est systématiquement **bloquant pour le bootstrap** : le **token du provider DNS**
consommé par `cert-manager-config`. Sans lui, pas de DNS-01, donc pas de certificat, donc aucun
listener TLS opérationnel sur `shared-gw`.

### 3. Les autres credentials (première construction, ou re-scellement)

À avoir sous la main **avant** l'étape 8, dans l'ordre donné par la fiche : token du provider
DNS, outputs Terraform des providers OIDC (autre repo), PAT GitHub. Les credentials qui
dépendent d'un service déployé par le cluster lui-même (ex. un token de service account Grafana)
se créent après coup, une fois ce service en marche.

> [!CAUTION]
> **Secrets — règle générale.** Les templates en clair `*.secret.yaml` sont **gitignorés** et
> ne doivent jamais quitter le poste ni survivre au scellement. Seuls les `*.sealed.yaml` sont
> committés. Backup de la clé sealed-secrets : coffre uniquement, jamais dans Git.

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
4. Tier-1 app-of-apps (apply cluster.yaml)       ← geste manuel n°3
     └─ déroule seul : gateway-api (-10) → sealed-secrets (-8) → cert-manager (-5)
        → cert-manager-config (-4) → argocd (-1) → cilium/openebs/apps (0)
5. Exposition : Gateway programmée + restart one-shot de cilium-operator + DNS
6. TLS Let's Encrypt (DNS-01) sur les wildcards
7. Stockage : namespace privileged → Job VG → StorageClass
8. Secrets applicatifs & SSO (première construction uniquement)
```

| Étape | Ce qui casse si tu la sautes |
|---|---|
| 1. Cilium | Aucun CNI → tous les pods restent `Pending`, CoreDNS compris |
| 2. ArgoCD | Pas de contrôleur GitOps → rien ne se réconcilie, tout le reste est mort-né |
| 3. Clé sealed-secrets | Contrôleur démarré avec une clé **neuve** → tous les SealedSecrets du repo sont indéchiffrables, tout est à resceller |
| 4. Tier-1 | Les Applications n'existent pas : ArgoCD tourne à vide |
| 5. Exposition | Sans restart de `cilium-operator` à la 1re pose des CRDs, la Gateway reste `Pending` ; sans secret TLS, le listener reste `ResolvedRefs=False` |
| 6. Token du provider DNS | DNS-01 bloqué, `Certificate` jamais `Ready`, aucun accès HTTPS valide |
| 7. Label PSA sur `openebs` | DaemonSet `lvm-node` et Job VG (privileged) rejetés par l'admission `baseline` |

> [!NOTE]
> **Rebuild à froid vs première construction.** Toutes les Applications vivent déjà dans le repo :
> après l'étape 4, les étapes 5 à 7 **convergent seules** dans l'ordre des sync-waves. En rebuild,
> ce runbook est une **checklist de vérification** autour de trois gestes manuels irréductibles :
> l'`apply -k` d'ArgoCD, la restauration de la clé sealed-secrets, et le restart one-shot de
> `cilium-operator`. L'étape 8 (scellement des secrets) et la parenthèse autosignée de l'étape 6
> ne concernent que la **première construction**.

---

## Étape 1 — Cilium (CNI)

> [!IMPORTANT]
> **Sans CNI, rien ne schedule.** Le cluster est livré sans CNI : tous les pods, CoreDNS compris,
> restent `Pending` jusqu'à ce que Cilium tourne.

La version du chart et les values ont une **source unique** dans le repo : `targetRevision` de
`${CLUSTER}/infra/cilium/cilium.app.yaml` et `${CLUSTER}/infra/cilium/helm-values.yaml`.
Ne jamais les retaper à la main — les lire :

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update cilium

CILIUM_VERSION="$(command grep -A3 'chart: cilium' ${CLUSTER}/infra/cilium/cilium.app.yaml \
  | command grep 'targetRevision:' | awk '{print $2}')"
echo "Cilium ${CILIUM_VERSION}"     # doit correspondre au targetRevision de l'Application

helm install cilium cilium/cilium --version "${CILIUM_VERSION}" -n kube-system \
  -f ${CLUSTER}/infra/cilium/helm-values.yaml
```

> [!WARNING]
> **Le `--version` et le `releaseName` sont load-bearing.** La release **doit** s'appeler
> `cilium` : l'Application `cilium` (étape 4) *adopte* ce release. Un nom différent renommerait
> toutes les ressources Cilium et détruirait le CNI. Une version différente du `targetRevision`
> ferait diverger l'app dès le premier sync.

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

> [!IMPORTANT]
> **Pas de Helm ici.** ArgoCD s'installe depuis le dossier auto-contenu
> `${CLUSTER}/infra/argocd/manifests/` : kustomize avec install upstream **épinglé** (le tag
> exact vit dans `kustomization.yaml`, source unique) + namespace + patchs
> (`argocd-cmd-params-cm`, `argocd-cm`, `argocd-rbac-cm`, `argocd-notifications-cm`) + la
> HTTPRoute UI. Ce **même dossier** sert à l'apply manuel du bootstrap **et** au self-management
> (`argocd.app.yaml`, wave -1, même `path`) → convergence garantie.

### 2.1 Installer

```bash
kubectl apply -k ${CLUSTER}/infra/argocd/manifests --server-side --force-conflicts
```

> [!WARNING]
> **`--server-side --force-conflicts` obligatoire.** Sans SSA : `metadata.annotations: Too long`
> sur les CRDs ApplicationSet. Et le mode doit **matcher** le `ServerSideApply=true` de
> l'Application self-managed, sinon `OutOfSync` permanent.

> [!NOTE]
> **Deux échecs attendus à ce stade**, non bloquants :
> - la **HTTPRoute** — les CRDs Gateway API n'existent pas encore ; elle convergera à l'étape 5 ;
> - les **SealedSecrets** (`argocd-oidc`, `argocd-notifications`) — la CRD `SealedSecret` n'est
>   posée qu'à l'étape 4 ; ils convergeront ensuite.
>
> Si l'`apply -k` refuse **en bloc** à cause d'un type inconnu : commenter temporairement les
> lignes concernées dans `kustomization.yaml` pour le bootstrap, le self-management les reposera
> après l'étape 5. Ne pas oublier de les décommenter et de pousser.

### 2.2 Vérifier et accéder à l'UI

```bash
kubectl -n argocd get pods
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Mot de passe admin initial (auto-généré à l'install)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# UI au bootstrap (l'exposition Gateway n'arrive qu'à l'étape 5)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080 (certificat autosigné, accepter)
```

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

```bash
kubectl apply -f ${CLUSTER}/cluster.yaml
```

`${CLUSTER}-cluster` découvre les `*.bootstrap.yaml` (recurse) → `${CLUSTER}-infra` et
`${CLUSTER}-app` découvrent chacun leurs `*.app.yaml` → toutes les Applications se créent et
déroulent leurs sync-waves. L'Application `argocd` (wave -1) **adopte** la config posée à
l'étape 2 → `Synced` sans rien changer → self-management acté.

> [!CAUTION]
> **Pièges « Argo manages Argo »**
> - `prune: false` sur l'Application `argocd` — il se couperait les jambes. `selfHeal: true` OK.
> - Repo-server et application-controller peuvent redémarrer une fois après le premier sync :
>   normal, laisser se stabiliser.
> - Crash-loop après un upgrade de Kubernetes → bumper le tag Argo CD dans
>   `${CLUSTER}/infra/argocd/manifests/kustomization.yaml`.

**Vérification :**

```bash
kubectl get applications -n argocd
```

Attendu au minimum : `${CLUSTER}-cluster`, `${CLUSTER}-infra`, `${CLUSTER}-app`, plus la liste
des composants de la fiche du cluster. `cilium` doit passer `Synced/Healthy` **sans rien
modifier** (adoption du `helm install` de l'étape 1).

---

## Étape 5 — Exposition (Gateway API)

Tout est déjà déclaratif : `gateway-api` (wave -10) pose les CRDs upstream épinglées, le
namespace `gateway` et le Gateway partagé `shared-gw`. Les listeners (2 wildcards partagés + 1
listener propre au cluster) sont détaillés dans [reseau.md](reseau.md) et dans la fiche du
cluster.

> [!NOTE]
> La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer :
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

**c. DNS** — le résolveur du réseau doit renvoyer le wildcard `*.${CLUSTER_DOMAIN}` vers l'IP du
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

`cert-manager` (wave -5) pose le moteur ; `cert-manager-config` (wave -4) pose le
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
curl -I https://argocd.${CLUSTER_DOMAIN}                    # SANS -k → chaîne LE valide
```

Le header `server: envoy` confirme le proxy Cilium.

> [!WARNING]
> **Résolveurs du self-check DNS-01.** cert-manager vérifie la propagation du TXT
> `_acme-challenge` via le DNS **du cluster**. Si celui-ci remonte vers un upstream qui renvoie
> NXDOMAIN sur ce nom (déjà observé avec Quad9), le challenge reste `Pending` indéfiniment.
> Remède : épingler les résolveurs récursifs dans
> `${CLUSTER}/infra/cert-manager/helm-values.yaml` —
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
> `ClusterIssuer selfsigned` dans `${CLUSTER}/infra/cert-manager-config/manifests/` et pointer
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
  → hook Sync `lvmvg-bootstrap` (0) : pvcreate + vgcreate sur la partition brute du nœud
    → StorageClass (1)
```

Nom du VG, partlabel de la partition et nom de la StorageClass : dans la fiche du cluster.

Rien à lancer à la main. Le label PSA `privileged` sur le namespace est ce qui autorise le
DaemonSet node-plugin et le Job (tous deux `privileged`) sous une admission `baseline` : c'est un
mécanisme natif, chirurgical et versionné, préféré à toute modification de la configuration
d'admission du cluster.

> [!NOTE]
> **Bootstrap du VG.** LocalPV-LVM ne provisionne **pas** le Volume Group, il l'exige préexistant.
> Le VG est donc créé par un conteneur privilégié qui embarque `lvm2` (la même image que le
> node-plugin), à partir de la partition brute étiquetée. C'est le seul état réel sur disque, non
> réconciliable par GitOps — le script est **idempotent** (skip si PV/VG déjà présents).

**Vérification :**

```bash
kubectl get ns openebs --show-labels            # pod-security.kubernetes.io/enforce=privileged
kubectl -n openebs get pods                     # controller + node plugin Running
kubectl -n openebs logs job/lvmvg-bootstrap     # pvcreate/vgcreate ou « déjà présent — skip »
kubectl get sc
```

Le **smoke test** de stockage (PVC + pod + Cluster CNPG) dépend des composants déployés : voir la
fiche du cluster.

---

## Étape 8 — Secrets applicatifs et SSO (première construction)

En **rebuild avec la bonne clé**, cette étape est déjà faite : les `*.sealed.yaml` du repo se
déchiffrent seuls. Elle ne sert qu'à une première construction ou à un re-scellement complet.

**Le cert public du contrôleur, une fois** (`pub-cert.pem` est gitignoré) :

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem
```

**Boucle de scellement, identique pour tous les secrets** — renseigner le template en clair
(`*.secret.yaml`, gitignoré), sceller, supprimer le clair, committer le `*.sealed.yaml` :

```bash
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < <chemin>/<name>.secret.yaml \
  > <chemin>/<name>.sealed.yaml
rm <chemin>/<name>.secret.yaml
```

L'**ordre de scellement** et le chemin de chaque template sont dans la fiche du cluster
([`doc/clusters/`](clusters/)), avec le README du composant à suivre pour chacun. Deux
dépendances structurent cet ordre, quel que soit le cluster :

- les client-secrets **OIDC** exigent que le provider d'identité tourne et que ses providers
  soient créés (Terraform, autre repo) ;
- les tokens de **service account** d'un service déployé ici (ex. notifications ArgoCD ←
  Grafana) exigent ce service en marche.

**Et immédiatement après : sauvegarder la clé au coffre** (cf. étape 3) — à partir de maintenant,
elle est le seul élément non reconstructible du cluster.

---

## Vérification finale

```bash
kubectl get applications -n argocd                       # toutes Synced/Healthy
kubectl get nodes                                        # Ready
kubectl -n gateway get gateway shared-gw                 # PROGRAMMED=True
kubectl -n gateway get certificate                       # tous READY=True
kubectl get sc
curl -I https://argocd.${CLUSTER_DOMAIN}
```

Le bloc de vérification complet, avec les hostnames et le smoke test réels du cluster, est dans
sa fiche : [`doc/clusters/`](clusters/).

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
- **Clé sealed-secrets d'un autre cluster** restaurée par erreur → même effet. Un cluster, une
  clé : vérifier le suffixe du fichier de backup.
- **Fichier référencé mais absent dans un `kustomization.yaml`** (typiquement un `*.sealed.yaml`
  pas encore scellé) → `kustomize build` échoue, l'Application entière part en erreur.
- **`bpf.masquerade=true` côté Cilium** ne cohabite pas avec un forward du DNS cluster vers
  l'hôte : CoreDNS casse. Laisser `bpf.masquerade` désactivé.
- **Quad9 comme résolveur des self-checks DNS-01** → NXDOMAIN sur `_acme-challenge` ; épingler
  `1.1.1.1`. TXT orphelins d'un run avorté = 400 côté provider DNS.
- **Pools L2 qui se chevauchent entre clusters** → deux clusters annonçant la même IP en ARP sur
  le même L2 : trafic imprévisible. Chaque cluster a sa plage, disjointe (cf. fiches).
- **PVC seul en `Pending`** → normal : `WaitForFirstConsumer`, le volume n'est taillé que quand un
  pod consomme le PVC.
