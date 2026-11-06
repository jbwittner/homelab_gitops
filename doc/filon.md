# filon (appli maison)

Pilotage des opportunités freelance, Spring Boot ([jbwittner/filon](https://github.com/jbwittner/filon), privé), PostgreSQL par CloudNativePG sauvegardé sur GCS. Deux envs, dev et prod. Arbo multi-env : [arborescence](arborescence.md#appli-maison-plusieurs-envs).

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/filon/common/deployment.yaml` | commun : probes actuator, ressources, identifiants base (Secret CNPG `filon-db-app`), clé Unipile (Secret `filon-unipile`), config Spring |
| `clusters/bleu-kalecgos/filon/common/application.yaml` | config Spring commune (URL de la base) → `/app/config/application.yaml` |
| `clusters/bleu-kalecgos/filon/common/database.yaml` | `Cluster` CNPG `filon-db` (1 instance, 5 Gi, plugin barman-cloud, jeton WIF projeté) + `ScheduledBackup` (02:00 UTC) + `PodMonitor` |
| `clusters/bleu-kalecgos/filon/common/gcp-credentials.yaml` | ConfigMap `filon-db-gcp` : fichier d'identifiants WIF (`terraform output -json cnpg`, pas de secret) |
| `clusters/bleu-kalecgos/filon/<env>/filon-<env>.app.yaml` | `filon-<env>-kalecgos`, namespace `filon-<env>` (label `ghcr-pull: enabled` : pull secret, [secrets](secrets.md#images-privées-ghcrio)) |
| `clusters/bleu-kalecgos/filon/<env>/manifests/deployment.yaml` | ligne `image:` de l'env, réécrite par la CI |
| `clusters/bleu-kalecgos/filon/<env>/manifests/externalsecret.yaml` | `secret/filon/<env>` (OpenBao), champ `unipile_api_key` → Secret `filon-unipile` |
| `clusters/bleu-kalecgos/filon/<env>/manifests/objectstore.yaml` | `ObjectStore` `filon-db` : `gs://homelab-cnpg-bleu-kalecgos-4d5b2c8d/filon-<env>`, rétention 7 j (dev) / 30 j (prod) |
| `clusters/bleu-malygos/external-services/manifests/filon-dev.yaml`, `filon.yaml` | relais de `filon-dev.lan.wittner.tech` et `filon.lan.wittner.tech` vers kalecgos |

## Secrets (OpenBao)

Un secret par env, `secret/filon/dev` et `secret/filon/prod` :

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
read -rs UNIPILE_API_KEY   # coller la clé, non affichée
bao kv put secret/filon/dev unipile_api_key="$UNIPILE_API_KEY"
bao kv put secret/filon/prod unipile_api_key="$UNIPILE_API_KEY"; unset UNIPILE_API_KEY
```

Clé lue au démarrage : après un changement, relancer le pod (`kubectl rollout restart`).

## Déploiement

| Env | Déclencheur (CI de filon) | Image |
|---|---|---|
| dev | push sur `main` → `main.yml` | `ghcr.io/jbwittner/filon:main-sha-<sha>` |
| prod | tag `v*` sur un commit de `main` → `release.yml` | même image, retaguée `v<version>` (pas de rebuild) |

La CI commite `chore(filon): déployer …` sur `main` ici (ligne `image:` = tag fixe `@sha256:…`) → ArgoCD. Renovate ignore cette image (`renovate.json`).

Prérequis côté filon : secret Actions `GITOPS_TOKEN` (PAT fine-grained, Contents read/write sur `homelab_gitops`).

## Sauvegardes

WAL archivés en continu et sauvegarde complète chaque nuit par le plugin barman-cloud, sur GCS sans clé (Workload Identity Federation) : [sauvegardes](sauvegardes.md#bases-postgres-cnpg).

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get application filon-dev-kalecgos filon-prod-kalecgos
kubectl --context admin@bleu-kalecgos -n filon-dev get externalsecret,cluster,objectstore,scheduledbackup,backup,pods
curl -s https://filon-dev.lan.wittner.tech/actuator/health    # {"status":"UP"}
curl -s https://filon-dev.lan.wittner.tech/actuator/info      # commit et heure du build, Java, OS
```

Probes : liveness = l'appli seule (une panne de Postgres ne relance pas le pod), readiness = l'appli + la base (le pod sort du trafic tant que Postgres est absent). Tuile Homepage : commit déployé (`/actuator/info`).

Pas encore d'interface web : seules la santé et `/actuator/info` répondent. Pas de métriques appli : seul Postgres est supervisé.
