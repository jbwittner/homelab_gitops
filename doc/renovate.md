# Renovate

Mises à jour des dépendances (charts, images, URLs taguées) par PR GitHub. Auto-hébergé sur kalecgos (CronJob, une fois par jour à 5 h), authentifié par une GitHub App.

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/renovate/renovate.app.yaml` | `renovate-kalecgos`, chart officiel `renovate` |
| `clusters/bleu-kalecgos/renovate/values.yaml` | config globale (dépôts traités), App ID / Installation ID, `preCommand` qui génère le jeton |
| `clusters/bleu-kalecgos/renovate/manifests/github-app-token.yaml` | script Node : JWT signé avec la clé → jeton d'installation (1 h) |
| `clusters/bleu-kalecgos/renovate/manifests/github-app-key.yaml` | `ExternalSecret` : clé privée depuis `secret/renovate` (`private_key`) |
| `renovate.json` (racine de chaque dépôt) | règles du dépôt ; un dépôt sans ce fichier est ignoré (`requireConfig: required`) |

| Dépôt | Ce qui est suivi |
|---|---|
| `homelab_gitops` | charts des `*.app.yaml`, images de `manifests/`, URLs taguées des `kustomization.yaml` |
| `homelab_talos` | `talosVersion`, `kubernetesVersion` des `talconfig.yaml` (regex) : merge manuel, upgrade par `talosctl` ; mineure Kubernetes : PR à part avec rappel de la matrice de support Talos |
| `homelab_terraform` | providers Terraform et `.terraform.lock.hcl` (règles du dépôt) |

## GitHub App (une fois)

Settings → Developer settings → GitHub Apps → New : webhook décoché, « Only on this account ». Permissions de dépôt : Contents, Pull requests, Issues, Checks, Commit statuses, Workflows en lecture-écriture ; Administration, Dependabot alerts, Metadata en lecture. Installer sur les dépôts suivis. App ID et Installation ID : `values.yaml` (non sensibles).

Clé privée dans OpenBao, sans l'afficher :

```sh
bao kv put secret/renovate private_key=@$HOME/Downloads/<app>.<date>.private-key.pem
command rm ~/Downloads/<app>.<date>.private-key.pem
```

Rotation : nouvelle clé sur l'App, même commande, supprimer l'ancienne sur GitHub.

## Vérifier

```sh
kubectl --context admin@bleu-kalecgos -n renovate get externalsecret,cronjob,jobs
kubectl --context admin@bleu-kalecgos -n renovate create job --from=cronjob/renovate renovate-manuel   # passage immédiat
kubectl --context admin@bleu-kalecgos -n renovate logs -f job/renovate-manuel
```

`jeton GitHub App refusé` : App ID, Installation ID ou clé ; l'App doit être installée sur le dépôt.
