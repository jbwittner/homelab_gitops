# bankwiz (appli maison)

API Spring Boot ([jbwittner/bankwiz](https://github.com/jbwittner/bankwiz), privé), PostgreSQL par CloudNativePG. Arbo multi-env : [arborescence](arborescence.md#appli-maison-plusieurs-envs).

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/bankwiz/common/deployment.yaml` | commun : probes actuator, ressources, identifiants base (Secret CNPG `bankwiz-db-app`), volume projeté des deux configs |
| `clusters/bleu-kalecgos/bankwiz/common/application.yaml` | config Spring commune (URL de la base) → `/app/config/application.yaml` |
| `clusters/bleu-kalecgos/bankwiz/common/database.yaml` | `Cluster` CNPG `bankwiz-db` (1 instance, 5 Gi) + `PodMonitor` |
| `clusters/bleu-kalecgos/bankwiz/common/ghcr-pull.yaml` | pull secret ghcr.io (OpenBao `secret/bankwiz`, champ `ghcr_token`) |
| `clusters/bleu-kalecgos/bankwiz/dev/bankwiz-dev.app.yaml` | `bankwiz-dev-kalecgos`, namespace `bankwiz-dev` |
| `clusters/bleu-kalecgos/bankwiz/dev/manifests/deployment.yaml` | ligne `image:` de dev, réécrite par la CI |
| `clusters/bleu-kalecgos/bankwiz/dev/manifests/application.yaml` | config Spring de dev (profil `dev`) → `/app/config/env/application.yaml`, prioritaire sur la commune (sous-dossier de `config/`, fusion par Spring) |
| `clusters/bleu-malygos/external-services/manifests/bankwiz-dev.yaml` | relais de `bankwiz-dev.lan.wittner.tech` vers kalecgos |

## Déploiement en dev

Push sur `develop` de bankwiz → `develop.yml` : image `ghcr.io/jbwittner/bankwiz:develop-sha-<sha>`, puis commit `chore(bankwiz): déployer …` sur `main` ici (ligne `image:` = tag fixe `@sha256:…`) → ArgoCD. Renovate ignore cette image (`renovate.json`).

Prérequis côté bankwiz : secret Actions `GITOPS_TOKEN` (PAT fine-grained, Contents read/write sur `homelab_gitops`).

## Secret (une fois)

PAT GitHub classic, scope `read:packages` seul :

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
read -rs GHCR_TOKEN   # coller le PAT, non affiché
bao kv put secret/bankwiz ghcr_token="$GHCR_TOKEN"; unset GHCR_TOKEN
```

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get application bankwiz-dev-kalecgos
kubectl --context admin@bleu-kalecgos -n bankwiz-dev get externalsecret,cluster,pods
kubectl --context admin@bleu-kalecgos -n bankwiz-dev logs deploy/bankwiz | grep -i "generated security password"   # mot de passe Basic de user
curl -s https://bankwiz-dev.lan.wittner.tech/actuator/health    # {"status":"UP"}
```

Swagger : [bankwiz-dev](https://bankwiz-dev.lan.wittner.tech/swagger-ui.html). Pas de métriques appli (actuator `health`/`info` seuls) : seul Postgres est supervisé.
