---
title: Fiche cluster — bleu-kalecgos
type: fiche-cluster
cluster: bleu-kalecgos
tags: [homelab, wittnerlab, kubernetes, argocd, gitops, cluster, fiche-cluster]
created: 2026-08-09
modified: 2026-08-10
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

Les noms `bleu-kalecgos-pool` / `bleu-kalecgos-l2` viennent du `namePrefix: bleu-kalecgos-` de
[`cluster/infra/cilium/bleu-kalecgos/manifests/kustomization.yaml`](../../cluster/infra/cilium/bleu-kalecgos/manifests/kustomization.yaml) :
les manifestes eux-mêmes portent les noms nus `pool` et `l2` (`l2-policy.yaml` vit dans
`common/`, partagé avec les autres clusters).

Les deux autres listeners de `shared-gw` (`https-public` `*.wittner.tech`, `https-internal`
`*.lan.wittner.tech`) ne sont pas spécifiques à ce cluster — mais `shared-gw` n'existe
aujourd'hui que **ici**, `gateway-api` étant un composant mono-cluster (cf.
[reseau.md](../reseau.md)).

**Exposé aujourd'hui** : `argocd.kalecgos.lan.wittner.tech`,
`grafana.kalecgos.lan.wittner.tech` (listener `https-internal-kalecgos`),
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
infra    : argocd, cert-manager, cert-manager-config, gateway-api, openebs, sealed-secrets,
           bleu-kalecgos-cilium
app      : alloy, authentik, cnpg, kube-prometheus-stack, loki, renovate, test-nginx
```

```bash
kubectl -n argocd get app -l homelab.wittner.tech/cluster=bleu-kalecgos   # → bleu-kalecgos-cilium
```

## SealedSecrets

Tous deviennent illisibles si la clé sealed-secrets de ce cluster est perdue — **y compris le
Secret de cluster du spoke `bleu-arcanagos`**, scellé ici.

| SealedSecret | Namespace | Clé(s) | Composant | Source amont à re-provisionner |
|---|---|---|---|---|
| `cloudflare-api-token` | `cert-manager` | `api-token` | `cert-manager-config` | Token API Cloudflare (`Zone:DNS:Edit` + `Zone:Zone:Read`) |
| `argocd-oidc` | `argocd` | `client-secret` | `argocd` | Provider OIDC authentik (Terraform, autre repo) |
| `argocd-notifications-secret` | `argocd` | `grafana-api-key` | `argocd` | Service account token Grafana |
| `cluster-bleu-arcanagos` | `argocd` | `name`, `server`, `config` | `argocd` | Token du SA `kube-system/argocd-manager` du spoke |
| `grafana-oidc` | `monitoring` | `client-secret` | `kube-prometheus-stack` | Provider OIDC authentik (Terraform) |
| `grafana-admin` | `monitoring` | `admin-user`, `admin-password` | `kube-prometheus-stack` | Généré localement (`openssl rand`) |
| `authentik-secrets` | `authentik` | `secret-key` | `authentik` | Généré à la 1re install — **ne jamais changer ensuite** |
| `renovate-env` | `renovate` | `RENOVATE_GITHUB_COM_TOKEN`, `RENOVATE_TOKEN` | `renovate` | PAT GitHub |

`cloudflare-api-token` est **bloquant pour le bootstrap** : sans lui, pas de DNS-01, donc pas de
certificat, donc aucun listener TLS opérationnel.

### Ordre de scellement (étape 8 du runbook)

| Ordre | Secret | Chemin du template | Détail |
|---|---|---|---|
| 1 | Token Cloudflare | `cluster/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml` | [cert-manager-config](../../cluster/infra/cert-manager-config/README.md) |
| 2 | Admin Grafana (break-glass) | `cluster/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml` | [kube-prometheus-stack](../../cluster/app/kube-prometheus-stack/README.md) |
| 3 | `AUTHENTIK_SECRET_KEY` | (généré, cf. README) | [authentik](../../cluster/app/authentik/README.md) |
| 4 | OIDC ArgoCD | `cluster/infra/argocd/manifests/argocd-oidc.secret.yaml` | [argocd](../../cluster/infra/argocd/README.md) |
| 5 | OIDC Grafana | `cluster/app/kube-prometheus-stack/manifests/grafana-oidc.secret.yaml` | [kube-prometheus-stack](../../cluster/app/kube-prometheus-stack/README.md) |
| 6 | Token notifications Grafana | `cluster/infra/argocd/manifests/argocd-notifications.secret.yaml` | [argocd](../../cluster/infra/argocd/README.md) |
| 7 | PAT GitHub Renovate | `cluster/app/renovate/manifests/renovate.secret.yaml` | [renovate](../../cluster/app/renovate/README.md) |
| 8 | Secret de cluster du spoke | `cluster/infra/argocd/manifests/cluster-bleu-arcanagos.secret.yaml` | [argocd-manager](../../cluster/infra/argocd-manager/README.md) |

Les 3, 4 et 5 dépendent d'authentik : il doit tourner et ses providers OIDC être créés
(Terraform, autre repo) avant de pouvoir sceller les client-secrets. Le 6 dépend de Grafana
(service account token créé dans l'UI). Le 8 dépend du spoke : son SA `argocd-manager` doit être
posé (étape 2bis de son propre bootstrap) pour que le token existe.

## Vérification finale

```bash
kubectl get applications -n argocd                       # toutes Synced/Healthy
kubectl get applicationsets -n argocd                    # cilium, argocd-manager
kubectl get nodes                                        # vert-eranikus Ready
kubectl -n gateway get gateway shared-gw                 # PROGRAMMED=True, ADDRESS=192.168.1.80
kubectl -n gateway get certificate                       # 3× READY=True
kubectl get sc openebs-lvm-thin
kubectl -n test-nginx get pods,pvc,clusters.postgresql.cnpg.io   # smoke test stockage + CNPG
curl -I https://argocd.kalecgos.lan.wittner.tech
curl -I https://grafana.kalecgos.lan.wittner.tech
```
