---
title: Bootstrap — bleu-kalecgos (vert-eranikus)
type: runbook
cluster: bleu-kalecgos
node: vert-eranikus
ip: 192.168.1.11
tags: [homelab, wittnerlab, talos, kubernetes, bootstrap, runbook, socle]
created: 2026-07-17
modified: 2026-07-18
status: draft
---

# Bootstrap — `bleu-kalecgos`

> [!abstract] Objet
> Reconstruction complète du nœud socle `vert-eranikus` (Talos mono-nœud, control-plane) depuis un disque vierge jusqu'au stockage LVM opérationnel. Single-disk : un NVMe 512 GB partagé OS + LVM (EPHEMERAL 100 GiB, partition brute LVM ~370 GiB).

## Chaîne de dépendances (acyclique)

> [!important] L'ordre n'est pas négociable
> Chaque étage dépend du précédent. La valeur de ce runbook, ce sont les dépendances, pas les commandes.

```
0. Disque vierge (reset / USB)
1. Talos installé + partitionné (EPHEMERAL 100 + r-lvmpv 370)   ← layout au 1er provision
2. bootstrap etcd
3. Cilium (CNI = none → rien ne schedule sans lui)
4. ArgoCD (kustomize épinglé, apply -k) + tier-1 app-of-apps
5. Exposition ArgoCD : CRDs Gateway API → shared-gw → HTTPRoute
   TLS autosigné (cert-manager, ClusterIssuer selfsigned)
6. Sealed Secrets (clé restaurée AVANT le démarrage du contrôleur en DR)
7. Let's Encrypt : token CF scellé → ClusterIssuer letsencrypt-prod → flip issuerRef
8. PodSecurity : namespace openebs labellisé privileged   ← AVANT les pods du driver
9. Driver OpenEBS LVM → StorageClass
```

| Étape | Ce qui casse si tu la sautes |
|---|---|
| 1. Layout disque | EPHEMERAL remplit le disque → `r-lvmpv` en `failed`, pas de LVM |
| 2. bootstrap | etcd absent → apiserver ne démarre pas |
| 3. Cilium | CNI `none` → tous les pods restent `Pending`, y compris CoreDNS |
| 4. ArgoCD | Pas de contrôleur GitOps → rien ne se réconcilie, tout le reste est mort-né |
| 5. CRDs → Gateway | Sans les CRDs, `shared-gw` ne s'applique pas ; sans secret TLS, le listener reste `ResolvedRefs=False` ; sans restart `cilium-operator` (1re pose), la Gateway reste `Pending` |
| 6. Clé sealed-secrets | Contrôleur démarré avec une clé NEUVE → tous les SealedSecrets du repo (token CF inclus) sont indéchiffrables ; il faut tout resceller |
| 7. Token CF | Secret `cloudflare-api-token` absent/indéchiffrable → challenge DNS-01 bloqué, `Certificate` jamais `Ready` |
| 8. PodSecurity | Sans le label `privileged` sur `openebs`, le DaemonSet `lvm-node` + le Job VG (privileged) sont rejetés par l'admission `baseline` |

> [!note] Rebuild à froid vs première construction
> Une fois toutes les Applications dans `homelab-gitops`, les étapes 5→9 convergent **toutes seules** après le `kubectl apply -f cluster.yaml` de la phase 4, dans l'ordre des sync-waves : `gateway-api-crds` (-10) → `sealed-secrets` (-8) → `cert-manager` (-5) → `cert-manager-config` (-4) → `argocd` (-1) → openebs. En rebuild, ce runbook devient une **checklist de vérification** + trois gestes manuels irréductibles : l'apply -k ArgoCD, la restauration de la clé sealed-secrets, et le restart one-shot de `cilium-operator`. La phase autosignée (5) n'a de sens qu'à la **première construction**, avant que LE ne soit dans le repo.

---

## Prérequis

> [!check] À vérifier avant de commencer
> - `talhelper --version` ≥ **v3.0.37** (support des documents autonomes `VolumeConfig`/`RawVolumeConfig` en patch multi-docs).
> - `talosctl`, `kubectl`, `helm`, `cilium` CLI présents. `kubectl` récent (kustomize intégré avec remote resources — l'install ArgoCD tire `raw.githubusercontent.com`).
> - `kubeseal` CLI présent (phase 6-7).
> - Backup de la **clé sealed-secrets** accessible hors cluster (coffre) — indispensable en rebuild, cf. phase 6.
> - `talsecret.yaml` **neuf**, hors Git. Régénérer : `talhelper gensecret > talsecret.yaml`.
> - Clone local de `homelab-gitops` à jour (`https://github.com/jbwittner/homelab_gitops.git`, public → HTTPS anonyme, aucun credential).

> [!info] Conventions de commandes
> - **`talosctl`** : contexte non persistant ici → chaque commande porte le triplet `-n 192.168.1.11 -e 192.168.1.11 --talosconfig=./clusterconfig/talosconfig`. Raccourci optionnel : `export TALOSCONFIG=./clusterconfig/talosconfig` (puis seulement `-n`/`-e`), ou `talosctl config merge ./clusterconfig/talosconfig` pour tout mémoriser.
> - **`grep` est aliasé sur `rg`** (ripgrep) : `rg` interprète `-E` comme `--encoding` et ignore `-A` façon GNU grep. Utiliser `command grep -E …` (le vrai grep) ou `rg` avec sa propre syntaxe.

> [!danger] Secrets
> La config machine générée contient les **clés racines du cluster** (CA k8s, CA etcd, `serviceAccount.key`, `secretboxEncryptionSecret`, tokens). Elle et le `talsecret.yaml` restent **hors Git** et hors espaces partagés. On-prem ne change rien à cette règle. Même règle pour le backup de la clé sealed-secrets (phase 6) : coffre, jamais en clair dans Git.

---

## Phase 0 — Retour à un état vierge

> [!warning] Destructif — détruit etcd et tout l'état du cluster
> N'exécuter que sur un cluster qu'on assume perdre. Tout est déclaratif (`homelab-gitops`), donc reconstructible — **sauf la clé sealed-secrets** (backup hors cluster obligatoire, cf. phase 6).

> [!question] Deux chemins — lequel ?
> - **A. Reset à distance (cas normal, celui-ci).** Le nœud tourne déjà sous Talos et répond à `talosctl` → on le reset **remote**, il reboote en maintenance depuis son propre disque. **Pas de clé USB, pas d'accès physique.**
> - **B. Boot USB (secours / matériel vierge).** Seulement si le nœud ne répond plus du tout, si le disque système est illisible, ou pour un **premier install sur une machine neuve**. Voir l'encadré en fin de phase.
>
> Pour une reconstruction d'un nœud Talos en marche → **chemin A**.

### A. Reset à distance (par défaut)

Depuis ton laptop, sans toucher à la machine. `--graceful=false` obligatoire : impossible de quitter etcd proprement en membre unique (mono-CP).

```bash
talosctl -n 192.168.1.11 -e 192.168.1.11 reset \
  --talosconfig=./clusterconfig/talosconfig \
  --graceful=false \
  --reboot \
  --system-labels-to-wipe STATE \
  --system-labels-to-wipe EPHEMERAL
```

Wipe STATE (config) + EPHEMERAL (etcd/données). Les partitions EFI/BOOT restent → le nœud **reboote en mode maintenance depuis son propre disque** (pas de config, TLS absent). On enchaîne sur `apply-config --insecure` (phase 1).

### B. Boot USB (secours / matériel vierge) — *pas nécessaire ici*

> [!tip] Quand seulement
> Machine injoignable, disque système corrompu, ou bootstrap d'un serveur **neuf** sans Talos installé. On boote physiquement sur une **clé USB Talos** : elle démarre en maintenance car le disque n'est pas utilisé, ce qui permet de le wiper totalement (table GPT comprise, résidus de PV LVM inclus).
>
> Ne PAS utiliser `--wipe-mode all` via `reset` sans USB sous la main : ça efface aussi l'install Talos du disque, et le nœud ne peut plus rebooter — il faudra alors une USB/ISO pour le relancer.

---

## Phase 1 — Talos + layout disque

> [!note] Le layout s'applique au PREMIER provision
> Partant d'un disque vierge, EPHEMERAL@100 + `r-lvmpv`@370 se créent d'emblée — plus besoin du cycle wipe.

Config clé (`talconfig.yaml`, patches nœud) :
- `machine.kernel.modules` : `dm_mod`, `dm_thin_pool`, `dm_snapshot`.
- `VolumeConfig EPHEMERAL` : `maxSize: 100GiB`.
- `RawVolumeConfig lvmpv` : `maxSize: 370GiB` (100 + 370 = 470 ≤ ~475 GiB utiles → ordre-robuste).

> [!warning] Piège d'ordre Talos
> `RawVolumeConfig` est provisionné AVANT `EPHEMERAL`. Si l'un n'est pas cappé, il mange tout le disque et l'autre échoue. Les **deux** sont cappés → chacun atteint sa borne quel que soit l'ordre.

```bash
talhelper genconfig
# Sanity : les deux documents doivent être présents (command grep = vrai grep, pas rg)
command grep -E 'VolumeConfig|RawVolumeConfig' clusterconfig/*.yaml

# Appliquer en mode maintenance (TLS absent → --insecure)
talhelper gencommand apply --extra-flags --insecure
```

> [!check] Vérification
> ```bash
> talosctl -n 192.168.1.11 -e 192.168.1.11 get discoveredvolumes --talosconfig=./clusterconfig/talosconfig   # EPHEMERAL ~100 + r-lvmpv ~370
> talosctl -n 192.168.1.11 -e 192.168.1.11 get volumestatus --talosconfig=./clusterconfig/talosconfig         # r-lvmpv PHASE = ready (pas failed)
> talosctl -n 192.168.1.11 -e 192.168.1.11 read /proc/modules --talosconfig=./clusterconfig/talosconfig | command grep dm_
> ```
> Label confirmé de la partition brute : **`r-lvmpv`**.

---

## Phase 2 — bootstrap etcd

```bash
talhelper gencommand bootstrap
talosctl -n 192.168.1.11 -e 192.168.1.11 health --wait-timeout 10m --talosconfig=./clusterconfig/talosconfig
```

> [!check] `talosctl -n 192.168.1.11 -e 192.168.1.11 get members --talosconfig=./clusterconfig/talosconfig` → nœud présent, etcd `ready`.

Récupérer le kubeconfig :
```bash
talosctl -n 192.168.1.11 -e 192.168.1.11 kubeconfig ./kubeconfig --talosconfig=./clusterconfig/talosconfig
```

---

## Phase 3 — Cilium (CNI)

> [!important] Sans CNI, rien ne schedule
> `cniConfig.name: none` → tous les pods (dont CoreDNS) restent `Pending` jusqu'à Cilium.

Valeurs clés (mono-nœud) : `kubeProxyReplacement=true`, `k8sServiceHost=localhost`, `k8sServicePort=7445` (KubePrism), `operator.replicas=1`, `cgroup.autoMount.enabled=false`, `cgroup.hostRoot=/sys/fs/cgroup`, L2 announcements + LB-IPAM (pool `.80–.84`).

> [!danger] Garde-fou CoreDNS
> `forwardKubeDNSToHost: true` (dans le talconfig) **ne doit pas** cohabiter avec `bpf.masquerade=true` côté Cilium → CoreDNS casse. Laisser `bpf.masquerade` désactivé.

> [!important] Version pinée : `1.19.5`
> SemVer **sans `v`** (chart = release). Le `--version` du helm install ci-dessous et le `targetRevision` de l'Application ArgoCD doivent rester **strictement identiques** (source unique : `values.yaml`). Toute dérive entre les deux = comportement imprévisible.

> [!warning] Saut de mineure 1.18 → 1.19
> Le socle tournait en 1.18.0. Relire les *1.19 Upgrade Notes* et vérifier la compat des valeurs `kubeProxyReplacement` / KubePrism avant/après. Rappel discipline : les upgrades Cilium se canaryent normalement sur `itharius` d'abord — ici pas de canary (itharius pas encore monté), choix assumé.

```bash
helm install cilium cilium/cilium --version 1.19.5 -n kube-system \
  -f bleu-kalecgos/infra/cilium/values.yaml
cilium status --wait
```

> [!note] Reprise en main par ArgoCD
> Ce `helm install` est le seul geste Helm du bootstrap. Une fois ArgoCD monté (phase 4), l'Application `cilium` (multi-source : chart 1.19.5 + `$values` + `manifests/` ip-pool/l2-policy) adopte le release — le `targetRevision` et le `values.yaml` étant identiques, elle passe `Synced` sans rien changer.

---

## Phase 4 — ArgoCD (kustomize épinglé) + app-of-apps

> [!important] Pas de Helm ici
> ArgoCD s'installe via le **dossier auto-contenu** `bleu-kalecgos/infra/argocd/` : kustomize avec install upstream **épinglé** (`raw.githubusercontent.com/argoproj/argo-cd/refs/tags/v3.4.5/manifests/install.yaml`) + `namespace.yaml` + patchs `argocd-cmd-params-cm` (`server.insecure: "true"`) / `argocd-cm` + la HTTPRoute UI. Ce **même dossier** sert à l'apply manuel du bootstrap ET au self-management (`argocd.app.yaml`, wave -1, `path: bleu-kalecgos/infra/argocd`) → convergence garantie.

### 1. Installer ArgoCD (impératif, une fois — le seul geste manuel du GitOps)

```bash
kubectl apply -k bleu-kalecgos/infra/argocd --server-side --force-conflicts
```

> [!warning] `--server-side --force-conflicts` obligatoire
> Sans SSA : `metadata.annotations: Too long` sur les CRDs ApplicationSet. Et ça doit **matcher** le `ServerSideApply=true` de l'Application self-managed, sinon `OutOfSync` permanent.

> [!note] La HTTPRoute part en échec, c'est attendu
> `argocd-httproute.yaml` est dans le kustomize mais les CRDs Gateway API n'existent pas encore → la ressource échoue à s'appliquer à ce stade. Non bloquant : le reste du bundle s'installe, et la route convergera d'elle-même en phase 5. (Si l'apply -k refuse en bloc à cause du type inconnu : commenter temporairement la ligne dans `kustomization.yaml` pour le bootstrap, le self-management la reposera après la phase 5.)

### 2. Vérifier, récupérer l'admin, accéder en port-forward

```bash
kubectl get pods -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Mot de passe admin initial (auto-généré à l'install)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo

# UI au bootstrap (l'exposition Gateway n'arrive qu'en phase 5)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080 (autosigné, accepter)
```

**Set du mot de passe admin** (le port-forward doit tourner dans un autre terminal) :

```bash
# Login CLI avec le mot de passe initial
argocd login localhost:8080 --username admin --insecure \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

# Définir le mot de passe définitif (prompt interactif : ancien puis nouveau)
argocd account update-password

# Ménage : le secret initial ne sert plus (le hash actif vit dans argocd-secret)
kubectl -n argocd delete secret argocd-initial-admin-secret
```

> [!tip] Variante sans CLI argocd
> Patch direct du hash bcrypt dans `argocd-secret` (c'est là que vit le mot de passe actif, champ `admin.password`) :
> ```bash
> kubectl -n argocd patch secret argocd-secret -p \
>   '{"stringData": {
>     "admin.password": "'"$(htpasswd -nbBC 10 "" '<NOUVEAU_MDP>' | tr -d ':\n')"'",
>     "admin.passwordMtime": "'"$(date +%FT%T%Z)"'"
>   }}'
> ```

> [!note] Statut GitOps de ce geste
> Le mot de passe admin est le **deuxième geste impératif assumé** du bootstrap (avec l'apply -k) : `argocd-secret` n'est pas dans le kustomize et le self-management ne le réconcilie pas — le hash survit aux syncs. Cible long terme déjà actée : hash géré en **SealedSecret** dans `homelab-gitops` (après phase 6), puis compte `admin` local désactivé au profit de l'OIDC **Authentik** quand il sera déployé sur le socle.

### 3. Lancer le tier-1 (déclenche toute la réconciliation)

```bash
kubectl apply -f bleu-kalecgos/cluster.yaml
```

`bleu-kalecgos-cluster` découvre les `*.bootstrap.yaml` (recurse) → `bleu-kalecgos-infra` découvre les `*.app.yaml` → toutes les Applications se créent et déroulent leurs sync-waves. L'Application `argocd` (wave -1) **adopte** la config posée à l'étape 1 → `Synced` sans rien changer → self-management acté.

> [!danger] Pièges « Argo manages Argo »
> - `prune: false` sur l'Application `argocd` (il se couperait les jambes) ; `selfHeal: true` OK.
> - Repo-server/controller peuvent redémarrer une fois après le premier sync : normal, laisser se stabiliser.
> - K8s 1.36 bleeding-edge : si crash-loop, bumper le tag `v3.4.x` dans `kustomization.yaml`.

> [!check] Vérif
> `kubectl get applications -n argocd` → `bleu-kalecgos-cluster`, `bleu-kalecgos-infra`, `argocd`, `cilium` au minimum. `cilium` doit être `Synced/Healthy` sans avoir rien modifié (adoption du helm install de phase 3).

---

## Phase 5 — Exposition ArgoCD (Gateway API, TLS autosigné)

> [!abstract] Objectif minimal
> Sortir du port-forward : `https://argocd.kalecgos.lan.wittner.tech` servi par la `shared-gw` (IP `.80`, première du pool LB), certificat **autosigné** en attendant Let's Encrypt (phase 7). Tout est déjà des Applications du repo — cette phase est surtout de la vérification d'ordre.

### Les briques (toutes GitOps, découvertes par le tier-1)

**1. `gateway-api-crds`** (wave **-10**) — `infra/gateway-api/` : kustomize remote épinglé `standard-install.yaml` **v1.4.1** (matrice : Cilium 1.19 → GwAPI v1.4.1) + `namespace.yaml` (ns `gateway`) + `gateway.yaml` (`shared-gw`, 3 listeners : `https-public` `*.wittner.tech`, `https-internal` `*.lan.wittner.tech`, `https-internal-kalecgos` `*.kalecgos.lan.wittner.tech`). `ServerSideApply=true` obligatoire (CRDs trop grosses). La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer (une GatewayClass déclarée à la main reste `Pending`, non réconciliée).

**2. cert-manager** (wave **-5**) — `infra/cert-manager/` : chart Jetstack v1.21.0, `crds.enabled: true`.

**3. cert-manager-config** (wave **-4**) — `infra/cert-manager-config/` : à ce stade (avant sealed-secrets/LE), un `ClusterIssuer selfsigned` + les 3 `Certificate` wildcard pointés dessus :

```yaml
# clusterissuer-selfsigned.yaml — temporaire, retiré en phase 7
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

Les 3 `Certificate` (`wildcard-public-tls`, `wildcard-lan-tls`, `wildcard-kalecgos-lan-tls`, **ns `gateway`** — là où la Gateway consomme les Secrets) avec `issuerRef: {name: selfsigned, kind: ClusterIssuer}`. Les **trois** secrets doivent exister, sinon les listeners correspondants restent `ResolvedRefs=False`.

**4. HTTPRoute ArgoCD** — déjà dans `infra/argocd/` : `parentRefs → shared-gw / sectionName: https-internal-kalecgos`, hostname `argocd.kalecgos.lan.wittner.tech`, backend `argocd-server:80` (TLS terminé à la Gateway, server en `insecure`). Les `group/kind/weight` sont **explicites** dans le manifeste — sinon les defaults CRD injectés côté live créent un `OutOfSync` permanent.

### Gestes manuels de cette phase

```bash
# a. Vérifier que le moteur Gateway est bien allumé côté Cilium (flag Helm + CRDs, les deux)
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-gateway-api}'   # → "true"

# b. 1re pose des CRDs : le contrôleur Gateway de Cilium ne les voit qu'après restart
#    de l'operator. Événement UNIQUE de bootstrap, pas une dérive GitOps.
kubectl -n kube-system rollout restart deployment/cilium-operator
```

**c. DNS (AdGuard)** : rewrite wildcard `*.kalecgos.lan.wittner.tech → 192.168.1.80` (le VIP de `shared-gw`). Rappel : un wildcard ne couvre qu'**un** niveau — vaut pour le cert, le listener ET le rewrite.

> [!check] Vérification bout en bout
> ```bash
> kubectl -n gateway get gateway shared-gw        # PROGRAMMED=True, ADDRESS=192.168.1.80
> kubectl -n gateway get secrets | command grep wildcard   # les 3 secrets TLS présents
> kubectl -n argocd get httproute argocd-server   # Accepted
> curl -kI https://argocd.kalecgos.lan.wittner.tech   # 200/302, cert autosigné (-k requis)
> ```
> Le header `server: envoy` confirme le proxy Cilium. Le `-k` est l'état **attendu** de cette phase.

> [!warning] Rejouer la HTTPRoute si commentée en phase 4
> Si la ligne `argocd-httproute.yaml` avait été commentée pour l'apply bootstrap : la décommenter, push — le self-management la pose.

---

## Phase 6 — Sealed Secrets

> [!abstract] Rôle dans la chaîne
> Prérequis de Let's Encrypt : le token Cloudflare du DNS-01 est un **SealedSecret** dans Git (règle : aucun `kubectl create secret` impératif, aucune donnée en clair au cluster hors GitOps). Wave **-8** — le contrôleur précède tout SealedSecret consommé plus tard.

Application `sealed-secrets` (`infra/sealed-secrets/`) : chart Bitnami **2.19.1** (app v0.38.4), ns `sealed-secrets`, aucune values custom. Déployée par le tier-1, rien à lancer.

> [!danger] DR — la clé AVANT le contrôleur
> En **rebuild**, le contrôleur démarré à vide génère une clé **neuve** → tous les SealedSecrets du repo deviennent indéchiffrables (il faudrait tout resceller). Restaurer la clé **avant** son premier démarrage — ou immédiatement après, suivi d'un restart :
> ```bash
> kubectl apply -f keys-backup.yaml            # backup coffre, JAMAIS dans Git
> kubectl rollout restart deployment/sealed-secrets -n sealed-secrets
> ```
> En **première construction** (pas de SealedSecret préexistant) : rien à restaurer, mais faire le backup TOUT DE SUITE :
> ```bash
> kubectl get secret -n sealed-secrets \
>   -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > keys-backup.yaml
> ```

```bash
# Cert public pour sceller côté laptop (une fois)
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  > pub-cert.pem
```

> [!check] `kubectl -n sealed-secrets get pods` → contrôleur `Running` ; `kubectl get sealedsecrets -A` répond (CRD posée).

---

## Phase 7 — Let's Encrypt (DNS-01 Cloudflare)

> [!abstract] La bascule
> Remplacer l'autosigné par LE : sceller le token Cloudflare → committer le `ClusterIssuer letsencrypt-prod` → **flipper les `issuerRef`** des 3 Certificates → retirer l'issuer `selfsigned`. Tout en Git, ArgoCD déroule.

### 1. Sceller le token Cloudflare

Token API : `Zone:DNS:Edit` + `Zone:Zone:Read` sur `wittner.tech`.

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace=cert-manager \
  --from-literal=api-token='<TOKEN>' \
  --dry-run=client -o yaml \
| kubeseal --cert pub-cert.pem --format yaml \
> bleu-kalecgos/infra/cert-manager-config/cloudflare-api-token.sealed.yaml
```

Committer **uniquement** le `.sealed.yaml` (le référencer dans le `kustomization.yaml` de `cert-manager-config`).

### 2. ClusterIssuer + flip des Certificates (commit)

- `clusterissuer.yaml` : `letsencrypt-prod`, ACME prod, solver `dns01.cloudflare` → `apiTokenSecretRef: {name: cloudflare-api-token, key: api-token}` (le SealedSecret, ns `cert-manager`).
- `certificates.yaml` : les 3 `issuerRef` passent de `selfsigned` à `letsencrypt-prod`. Le changement de spec déclenche la ré-émission — cert-manager écrase les secrets autosignés dans ns `gateway`.
- Supprimer `clusterissuer-selfsigned.yaml` (prune ArgoCD fait le ménage).

> [!warning] Leçon Traefik transposée : résolveurs du DNS-01
> Sur le Level 0, Quad9 retournait NXDOMAIN pour `_acme-challenge` alors que Cloudflare le voyait → seul `1.1.1.1` fiabilise. Le self-check de propagation de cert-manager passe par le DNS **du cluster** (CoreDNS → AdGuard → mix d'upstreams dont Quad9). Épingler les résolveurs récursifs dans `helm-values.yaml` de cert-manager :
> ```yaml
> extraArgs:
>   - --dns01-recursive-nameservers=1.1.1.1:53
>   - --dns01-recursive-nameservers-only
> ```
> Et en cas de run avorté : nettoyer les **TXT `_acme-challenge` orphelins** chez Cloudflare avant de réessayer (sinon 400).

> [!check] Vérification
> ```bash
> kubectl -n gateway get certificate      # les 3 en READY=True
> kubectl -n cert-manager get challenges  # vide une fois émis
> curl -I https://argocd.kalecgos.lan.wittner.tech   # SANS -k → chaîne LE valide
> ```
> DNS-01 → aucune exposition publique requise, marche pour les hostnames internes du split-horizon (`*.lan` jamais publié chez Cloudflare, seul le TXT de challenge y transite).

---

## Phase 8 — PodSecurity (label sur `openebs`)

> [!info] 100 % déclaratif — aucun patch Talos
> Talos applique PodSecurity `baseline` cluster-wide, seul `kube-system` exempté. Plutôt que de modifier le machineconfig, on labellise le namespace `openebs` en `privileged` — mécanisme PSA natif, chirurgical, versionné, visible sur l'objet Namespace.

Rien à lancer à la main ici : le label est porté par le manifeste explicite `manifests/namespace.yaml` (sync-wave `-1`), déployé via ArgoCD **en même temps que le driver** (phase 9). L'ordre est garanti par les sync-waves : namespace labellisé (`-1`) → Job VG (`0`) → StorageClass (`1`).

```yaml
# manifests/namespace.yaml (extrait)
apiVersion: v1
kind: Namespace
metadata:
  name: openebs
  labels:
    pod-security.kubernetes.io/enforce: privileged
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

> [!warning] Pourquoi le label et pas un hook
> Le Job VG et le DaemonSet `lvm-node` tournent en `privileged`. Sous `baseline`, ils sont rejetés tant que le namespace n'est pas labellisé. Le Job est une **ressource normale à sync-wave 0** (plus un hook PreSync) → il s'exécute forcément après le namespace labellisé (`-1`). C'est ce qui élimine la course.

> [!check] Vérif
> `kubectl get ns openebs --show-labels` → `pod-security.kubernetes.io/enforce=privileged` présent.

---

## Phase 9 — Driver OpenEBS LVM

Via ArgoCD (chemin `bleu-kalecgos/infra/openebs-lvm/`) :
- Application driver (chart `lvm-localpv`, driver v1.9.1) → namespace `openebs`, `CreateNamespace=false` (le namespace est déjà créé + labellisé par `manifests/namespace.yaml`).
- Manifests : `namespace.yaml` (wave -1) + Job VG (wave 0, ressource normale) + `StorageClass` thin (wave 1).

> [!note] Bootstrap du VG
> Talos n'a pas de lvm2 userspace → le VG se crée depuis un conteneur privilégié qui `pvcreate` la partition brute `/dev/disk/by-partlabel/r-lvmpv`. État réel sur le disque, hors GitOps réconciliable (analogue à l'exception AdGuard).

```bash
# Le Job VG fait : pvcreate r-lvmpv → vgcreate lvmvg → driver up
kubectl -n openebs get pods            # controller + node plugin Running
kubectl get sc openebs-lvm-thin
```

> [!check] Smoke test
> PVC 1Gi sur `openebs-lvm-thin` + pod busybox → PVC `Bound`, LV créé dans `lvmvg`.

---

## Extension future (sans reprovision)

> [!tip] Ajout d'un 2e disque plus tard
> Migration/extension LVM à chaud, aucun rebuild :
> ```bash
> pvcreate /dev/disk/by-id/<nouveau>
> vgextend lvmvg /dev/disk/by-id/<nouveau>   # extension
> # ou migration : pvmove <ancienne-part> → vgreduce lvmvg <ancienne-part>
> ```
> Rappel isolation : un VG étalé sur 2 disques = 1 seul domaine de panne. Pour une vraie isolation, créer un **VG distinct** par disque.

---

## Pièges rencontrés (mémo)

> [!bug] Collection
> - **`apply-config` sans reboot n'a aucun effet sur la taille d'EPHEMERAL** : Talos ne dimensionne qu'au 1er provision. Il faut wiper.
> - **xfs ne se réduit jamais** : impossible de rétrécir EPHEMERAL en place, seul le wipe libère l'espace.
> - **talhelper < v3.0.37** ignore silencieusement les documents autonomes.
> - **RFC6902** ne marche pas sur configs multi-docs → strategic-merge uniquement.
> - **`--graceful` sur mono-CP** bloque (etcd leave impossible) → `--graceful=false`.
> - **Résolution DNS de `vert-ysera`** ne passe pas par AdGuard → faux « cert non servi » côté Traefik (artefact de résolution locale, pas un vrai souci TLS).
> - **Apply non-SSA après un apply SSA** (ou l'inverse) sur ArgoCD → `OutOfSync` permanent ; l'apply manuel et l'Application self-managed doivent être **tous deux** server-side.
> - **GatewayClass déclarée à la main** → `ACCEPTED: Unknown / Pending` : Cilium ne réconcilie pas une GatewayClass qu'il ne possède pas. La laisser auto-créer.
> - **CRDs Gateway API posées après Cilium** → contrôleur Gateway aveugle tant que `cilium-operator` n'a pas redémarré (one-shot de bootstrap).
> - **Defaults CRD Gateway API** (`group`, `kind`, `weight`, `matches`) injectés côté live → `OutOfSync` permanent si non explicités dans les manifestes HTTPRoute.
> - **Contrôleur sealed-secrets démarré avant restauration de la clé** → nouvelle clé, SealedSecrets du repo indéchiffrables.
> - **Quad9 comme résolveur des self-checks DNS-01** → NXDOMAIN sur `_acme-challenge` ; épingler `1.1.1.1` (`--dns01-recursive-nameservers`). TXT orphelins d'un run avorté = 400 Cloudflare.
