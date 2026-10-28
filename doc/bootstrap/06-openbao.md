# 6. OpenBao et secrets (malygos)

Tout `ExternalSecret` attend OpenBao, y compris sur kalecgos (store via `https://openbao.lan.wittner.tech`, donc après le certificat du Gateway malygos, lui-même tiré du jeton Cloudflare dans OpenBao) : malygos d'abord.

| Secret (`secret/…`) | Lu par |
|---|---|
| `argocd` | `argocd-malygos` (OIDC) |
| `authelia` | `authelia-malygos` |
| `cert-manager` | `cert-manager-*` (DNS-01 Cloudflare) |
| `grafana`, `alertmanager` | `kube-prometheus-stack-malygos` |
| `smtp-relay` | `smtp-relay-*` |
| `renovate` | `renovate-kalecgos` |

## Ordre

| # | Cluster neuf | Snapshot Velero disponible |
|---|---|---|
| 1 | init + unseal ([openbao](../openbao.md)) | restauration ([sauvegardes](../sauvegardes.md#restaurer-openbao), remise en prod jamais testée) |
| 2 | structure : Terraform `homelab_terraform/openbao/bleu-malygos` (token root) | dans le snapshot |
| 3 | valeurs : `bao kv put secret/<comp> …` ([secrets](../secrets.md)) | dans le snapshot |

Puis :

1. Applications restées en échec (dépendance arrivée après les 5 essais automatiques d'ArgoCD) : Sync.
2. OIDC ArgoCD : une fois le Secret `argocd-oidc` créé, `argocd-server` doit le relire :
   ```sh
   kubectl --context admin@bleu-malygos -n argocd get secret argocd-oidc
   kubectl --context admin@bleu-malygos -n argocd rollout restart deploy/argocd-server
   ```

## Vérifier

```sh
kubectl --context admin@bleu-malygos get clustersecretstore openbao        # Ready True
kubectl --context admin@bleu-kalecgos get clustersecretstore openbao       # Ready True
kubectl --context admin@bleu-malygos get externalsecret -A                 # SecretSynced
kubectl --context admin@bleu-kalecgos get externalsecret -A                # SecretSynced
kubectl --context admin@bleu-malygos -n argocd get applications            # tout Synced / Healthy
```
