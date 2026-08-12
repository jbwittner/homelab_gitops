---
title: Fiche cluster — bleu-kalecgos
type: fiche-cluster
cluster: bleu-kalecgos
tags: [homelab, wittnerlab, kubernetes, argocd, gitops, cluster, fiche-cluster]
created: 2026-08-09
modified: 2026-08-11
status: stable
---

# Fiche cluster — `bleu-kalecgos`

Valeurs propres à ce cluster. La **procédure** de bootstrap / disaster recovery est générique et
vit dans [runbook-bootstrap.md](../runbook-bootstrap.md).

```bash
export CLUSTER=bleu-kalecgos
export CLUSTER_DOMAIN=kalecgos.lan.wittner.tech
```

## Rôle — HUB ArgoCD

Ce cluster héberge **l'unique ArgoCD du repo**. Conséquences :

| Élément | Valeur |
|---|---|
| Tier-1 / tier-2 (`root`, `infra`, `app`) | déployés **ici**, ns `argocd` — leur `destination` est ce cluster |
| Secret de cluster local | `cluster-bleu-kalecgos`, en clair (aucun credential) — [`cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml`](../../cluster/infra/argocd/manifests/cluster-bleu-kalecgos.yaml) |
| Clé sealed-secrets | **ici** — la seule du repo : elle scelle aussi les secrets des spokes |
| `argocd-manager` | **pas de dossier** dans [`cluster/infra/argocd-manager/`](../../cluster/infra/argocd-manager/README.md) : le hub se gère via son propre ServiceAccount |

## Nœud

Mono-nœud **`vert-eranikus`**, Talos.

| Attente | Valeur | Consommateur |
|---|---|---|
| Endpoint apiserver local | `localhost:7445` (KubePrism) | `cilium` — `k8sServiceHost`/`k8sServicePort` |
| `/sys/fs/cgroup` monté par l'hôte | `cgroup.autoMount.enabled: false` | `cilium` |
| Modules noyau | `dm_mod`, `dm_thin_pool`, `dm_snapshot` | `openebs` |
| PodSecurity | `baseline` au cluster, `kube-system` exempté | `openebs`, `alloy`, `monitoring` (ns labellisés `privileged`) |

## Réseau

| Élément | Valeur |
|---|---|
| `CiliumLoadBalancerIPPool` | `bleu-kalecgos-pool` — `192.168.1.80` → `192.168.1.84` |
| `CiliumL2AnnouncementPolicy` | `bleu-kalecgos-l2` |
| IP du LB (`shared-gw`) | `192.168.1.80` (première du pool) |
| Listener propre au cluster | `https-internal-kalecgos` — `*.kalecgos.lan.wittner.tech` |
| Secret TLS du listener | `wildcard-kalecgos-lan-tls` (ns `gateway`) |
| Entrée DNS à créer | `*.kalecgos.lan.wittner.tech` → `192.168.1.80` |
| Entrée DNS non spécifique au cluster | `*.lan.wittner.tech` → `192.168.1.80` (listener `https-internal`, utilisé par `openbao`) |

Les noms `bleu-kalecgos-pool` / `bleu-kalecgos-l2` viennent du `namePrefix: bleu-kalecgos-` de
[`cluster/infra/cilium/bleu-kalecgos/manifests/kustomization.yaml`](../../cluster/infra/cilium/bleu-kalecgos/manifests/kustomization.yaml) :
les manifestes eux-mêmes portent les noms nus `pool` et `l2` (`l2-policy.yaml` vit dans
`common/`, partagé avec les autres clusters).

Les deux autres listeners de `shared-gw` (`https-public` `*.wittner.tech`, `https-internal`
`*.lan.wittner.tech`) ne sont pas spécifiques à ce cluster — mais `shared-gw` n'existe
aujourd'hui que **ici**, `gateway-api` étant un composant mono-cluster (cf.
[reseau.md](../reseau.md)).

**Exposé aujourd'hui** : `argocd.lan.wittner.tech`,
`grafana.lan.wittner.tech` (listener `https-internal-kalecgos`),
`openbao.lan.wittner.tech` (listener `https-internal`),
`authentik.wittner.tech` (listener `https-public`).

## Stockage

| Élément | Valeur |
|---|---|
| Partition brute | `/dev/disk/by-partlabel/r-lvmpv` |
| Volume Group | `lvmvg` — créé par le hook `lvmvg-bootstrap` |
| StorageClass | `openebs-lvm-thin` (**défaut du cluster**) |

## Composants

Index complet avec un lien par composant : [`README.md`](../../README.md) racine.

Applications attendues dans ArgoCD après l'étape 4 du runbook — les composants mono-cluster de ce
cluster ne portent **pas** de préfixe (c'est le hub) ; `cilium` est généré par un `ApplicationSet`
et l'a donc :

```
tier 1/2 : root, infra, app
appsets  : cilium, argocd-manager
infra    : argocd, cert-manager, cert-manager-config, external-secrets, gateway-api, openbao,
           openebs, sealed-secrets, bleu-kalecgos-cilium
app      : alloy, authentik, cnpg, kube-prometheus-stack, loki, renovate, test-nginx
```

```bash
kubectl -n argocd get app -l homelab.wittner.tech/cluster=bleu-kalecgos   # → cilium
```

## Secrets

Deux canaux, deux backups **non interchangeables**. Le critère qui répartit les secrets entre eux
est dans [regles-gitops.md](../regles-gitops.md).

### Canal 1 — SealedSecrets (étape 8a du runbook)

Les deux secrets en amont du coffre dans le graphe de bootstrap. Illisibles si la clé
sealed-secrets de ce cluster est perdue — **y compris le Secret de cluster du spoke
`bleu-arcanagos`**, scellé ici.

| SealedSecret | Namespace | Clé(s) | Composant | Template en clair | Source amont |
|---|---|---|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `api-token` | [cert-manager-config](../../cluster/infra/cert-manager-config/README.md) | `cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml` | Token API Cloudflare (`Zone:DNS:Edit` + `Zone:Zone:Read`) |
| `cluster-bleu-arcanagos` | `argocd` | `name`, `server`, `config` | [argocd-manager](../../cluster/infra/argocd-manager/README.md) | `cluster/infra/argocd/manifests/cluster-bleu-arcanagos.secret.yaml` | Token du SA `kube-system/argocd-manager` du spoke |

Sceller le token Cloudflare **en premier** : il est bloquant pour le bootstrap (sans lui, pas de
DNS-01, donc pas de certificat, donc aucun listener TLS opérationnel). Le Secret de cluster
dépend du spoke — son SA `argocd-manager` doit être posé (étape 2bis de son propre bootstrap)
pour que le token existe.

### Canal 2 — openbao (étape 8b du runbook)

Chiffrés dans le PVC d'[openbao](../../cluster/infra/openbao/README.md), pas dans Git ; le repo
ne contient que les `*.externalsecret.yaml` qui pointent dessus, via
[external-secrets](../../cluster/infra/external-secrets/README.md). Leur sauvegarde, ce sont les
**clés de descellement** + un **snapshot raft**, indépendants de la clé sealed-secrets.

| Chemin KV (`kv/…`) | Secret produit | Namespace | Clé(s) | Composant | Source amont |
|---|---|---|---|---|---|
| `homelab/grafana/admin` | `grafana-admin` | `monitoring` | `admin-user`, `admin-password` | [kube-prometheus-stack](../../cluster/app/kube-prometheus-stack/README.md) | Généré localement (`openssl rand`) |
| `homelab/authentik/secrets` | `authentik-secrets` | `authentik` | `secret-key` | [authentik](../../cluster/app/authentik/README.md) | Généré à la 1re install — **ne jamais changer ensuite** |
| `homelab/argocd/oidc` | `argocd-oidc` | `argocd` | `client-secret` | [argocd](../../cluster/infra/argocd/README.md) | Provider OIDC authentik (Terraform, autre repo) |
| `homelab/grafana/oidc` | `grafana-oidc` | `monitoring` | `client-secret` | [kube-prometheus-stack](../../cluster/app/kube-prometheus-stack/README.md) | Provider OIDC authentik (Terraform) |
| `homelab/argocd/notifications` | `argocd-notifications-secret` | `argocd` | `grafana-api-key` | [argocd](../../cluster/infra/argocd/README.md) | Service account token Grafana |
| `homelab/renovate/github` | `renovate-env` | `renovate` | `token` → `RENOVATE_TOKEN` + `RENOVATE_GITHUB_COM_TOKEN` | [renovate](../../cluster/app/renovate/README.md) | PAT GitHub |

L'ordre du tableau est celui à suivre : les trois entrées OIDC/authentik supposent authentik en
marche et ses providers créés (Terraform, autre repo) ; les notifications supposent Grafana en
marche (le service account token se crée dans son UI).

⚠️ Prérequis à tout `bao kv put` : le coffre **descellé** et **configuré par le repo Terraform**
(moteur KV v2 sur `kv`, mount d'auth `kubernetes-bleu-kalecgos`, role `external-secrets` +
policy de lecture sur `kv/data/homelab/*`). Sans cette configuration, les `ExternalSecret`
restent en `permission denied`. Le mount est **propre au cluster** : chaque cluster portant ESO
a le sien, cf. [external-secrets](../../cluster/infra/external-secrets/README.md).

## Vérification finale

```bash
kubectl get applications -n argocd                       # toutes Synced/Healthy
kubectl get applicationsets -n argocd                    # cilium, argocd-manager
kubectl get nodes                                        # vert-eranikus Ready
kubectl -n gateway get gateway shared-gw                 # PROGRAMMED=True, ADDRESS=192.168.1.80
kubectl -n gateway get certificate                       # 3× READY=True
kubectl get sc openebs-lvm-thin
kubectl -n test-nginx get pods,pvc,clusters.postgresql.cnpg.io   # smoke test stockage + CNPG
curl -I https://argocd.lan.wittner.tech
curl -I https://grafana.lan.wittner.tech
```
