# n8n

Automatisation de workflows. Chart officiel ([n8n-io/n8n-hosting](https://github.com/n8n-io/n8n-hosting/tree/main/charts/n8n), OCI `ghcr.io/n8n-io/n8n-helm-chart/n8n`) en **standalone** : un pod main + sidecar task runners (nœuds Code JS/Python), PostgreSQL par CloudNativePG sauvegardé sur GCS. Sur kalecgos, namespace `n8n`.

Pas repris du [compose upstream](https://docs.n8n.io/deploy/host-n8n/install-options/install-using-docker-compose) : sandbox Instance AI (Docker-in-Docker privileged), searxng ([décisions](decisions.md)).

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/n8n/n8n.app.yaml` | `n8n-kalecgos` : chart + `values.yaml` + `manifests/` |
| `clusters/bleu-kalecgos/n8n/values.yaml` | standalone, PVC 2 Gi (`~/.n8n`), URL, fuseau, `N8N_PROXY_HOPS`, métriques, SMTP |
| `clusters/bleu-kalecgos/n8n/manifests/externalsecret.yaml` | `secret/n8n` → Secret `n8n-secrets` (`N8N_ENCRYPTION_KEY`, `N8N_RUNNERS_AUTH_TOKEN`, `N8N_HOST`…) ; champ `data_db_password` → Secret `n8n-db-data` (basic-auth, rôle `n8n_data`) |
| `clusters/bleu-kalecgos/n8n/manifests/database.yaml` | `Cluster` CNPG `n8n-db` (1 instance, 5 Gi, barman-cloud, jeton WIF, rôle géré `n8n_data`) + `Database` `n8n_data` + `ScheduledBackup` (02:30 UTC) + `PodMonitor` |
| `clusters/bleu-kalecgos/n8n/manifests/objectstore.yaml` | `ObjectStore` `n8n-db` : `gs://homelab-cnpg-bleu-kalecgos-4d5b2c8d/n8n`, 30 j |
| `clusters/bleu-kalecgos/n8n/manifests/gcp-credentials.yaml` | ConfigMap `n8n-db-gcp` (même fichier WIF que filon) |
| `clusters/bleu-kalecgos/n8n/manifests/httproute.yaml` | `n8n.lan.wittner.tech` → `n8n-main:5678` |
| `clusters/bleu-kalecgos/n8n/manifests/servicemonitor.yaml` | `/metrics` (pas d'option dans le chart) |
| `clusters/bleu-malygos/external-services/manifests/n8n.yaml` | relais de `n8n.lan.wittner.tech` vers kalecgos |

## Avant le premier sync (une fois)

1. Sujet WIF de la base, `homelab_terraform` (`gcp/homelab/cnpg.tf`, `local.cnpg_subjects`) : `system:serviceaccount:n8n:n8n-db`, puis `make apply`.
2. Secret OpenBao, valeurs générées sans affichage :

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
bao kv put secret/n8n encryption_key="$(openssl rand -hex 32)" runners_auth_token="$(openssl rand -hex 32)"
```

`encryption_key` chiffre les identifiants stockés en base : la perdre = identifiants illisibles. Ne jamais la changer (OpenBao est sauvegardé par Velero).

Sans `secret/n8n`, le pod reste en attente (Secret `n8n-secrets` absent).

## Base des workflows (`n8n_data`)

Données lues et écrites par les workflows : base `n8n_data`, rôle `n8n_data`, dans le Cluster `n8n-db`. Jamais la base interne `n8n` (schéma migré par n8n à chaque version). Mêmes sauvegardes ; une restauration ramène les deux bases ensemble. Petits besoins sans SQL : Data Tables de n8n.

Mot de passe (une fois), sans affichage :

```sh
bao kv patch secret/n8n data_db_password="$(openssl rand -hex 32)"
```

Identifiant n8n **Postgres** : hôte `n8n-db-rw`, port `5432`, base et utilisateur `n8n_data`, SSL `disable`, mot de passe copié sans l'afficher :

```sh
bao kv get -field=data_db_password secret/n8n | pbcopy
```

Sans le champ, le rôle n'a pas de mot de passe (connexion refusée) et la `Database` attend.

## Premier accès

`https://n8n.lan.wittner.tech` → création du compte propriétaire (local : OIDC réservé à l'édition entreprise). Mot de passe oublié : mail par le [relais SMTP](smtp.md), expéditeur `n8n@wittner.tech`.

## Points à connaître

| Point | |
|---|---|
| Webhooks | `https://n8n.lan.wittner.tech/webhook/…`, LAN seulement (aucun hostname public) |
| Version | celle du chart (`appVersion`), suivie par Renovate (`targetRevision`) |
| PVC `~/.n8n` | nœuds communautaires, données binaires ; **non sauvegardé** (pas de Velero sur kalecgos) : workflows et identifiants sont en base |
| Clés lues au démarrage | après un changement de `secret/n8n` : `kubectl rollout restart` |

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get application n8n-kalecgos
kubectl --context admin@bleu-kalecgos -n n8n get externalsecret,cluster,objectstore,scheduledbackup,backup,pvc,pods
curl -s https://n8n.lan.wittner.tech/healthz              # {"status":"ok"}
```
