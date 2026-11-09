# filon (appli maison)

Pilotage des opportunités freelance, Spring Boot ([jbwittner/filon](https://github.com/jbwittner/filon), privé), PostgreSQL par CloudNativePG sauvegardé sur GCS. Un seul env, namespace `filon`, composant à plat (`filon.app.yaml` + `manifests/`).

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/filon/filon.app.yaml` | `filon-kalecgos`, namespace `filon` (label `ghcr-pull: enabled` : pull secret, [secrets](secrets.md#images-privées-ghcrio)) |
| `clusters/bleu-kalecgos/filon/manifests/deployment.yaml` | ligne `image:` réécrite par la CI ; probes actuator, ressources, identifiants base (Secret CNPG `filon-db-app`), utilisateur du login (Secret `filon-login`), clé Unipile (Secret `filon-unipile`), jeton MCP (Secret `filon-mcp`), config Spring |
| `clusters/bleu-kalecgos/filon/manifests/application.yaml` | config Spring (URL de la base) → `/app/config/application.yaml` |
| `clusters/bleu-kalecgos/filon/manifests/database.yaml` | `Cluster` CNPG `filon-db` (1 instance, 5 Gi, plugin barman-cloud, jeton WIF projeté) + `ScheduledBackup` (02:00 UTC) + `PodMonitor` |
| `clusters/bleu-kalecgos/filon/manifests/gcp-credentials.yaml` | ConfigMap `filon-db-gcp` : fichier d'identifiants WIF (`terraform output -json cnpg`, pas de secret) |
| `clusters/bleu-kalecgos/filon/manifests/externalsecret.yaml` | `secret/filon` (OpenBao) : champ `unipile_api_key` → Secret `filon-unipile` ; champs `login_username`, `login_password` → Secret `filon-login` (`FILON_USERNAME`, `FILON_PASSWORD`) ; champ `mcp_token` → Secret `filon-mcp` (`FILON_MCP_TOKEN`) |
| `clusters/bleu-kalecgos/filon/manifests/objectstore.yaml` | `ObjectStore` `filon-db` : `gs://homelab-cnpg-bleu-kalecgos-4d5b2c8d/filon`, rétention 30 j |
| `clusters/bleu-kalecgos/filon/manifests/httproute.yaml` | `filon.lan.wittner.tech` |
| `clusters/bleu-malygos/external-services/manifests/filon.yaml` | relais de `filon.lan.wittner.tech` vers kalecgos |

## Secrets (OpenBao)

Un secret, `secret/filon` :

```sh
export BAO_ADDR=https://openbao.lan.wittner.tech
bao login -method=oidc
read -rs UNIPILE_API_KEY   # coller la clé, non affichée
bao kv put secret/filon unipile_api_key="$UNIPILE_API_KEY"; unset UNIPILE_API_KEY
```

Utilisateur unique du login (mot de passe en clair) ; `patch` garde les autres champs :

```sh
read -rs LOGIN_PASSWORD    # non affiché
bao kv patch secret/filon login_username=jb login_password="$LOGIN_PASSWORD"; unset LOGIN_PASSWORD
```

Jeton bearer du serveur MCP (`/mcp`, Claude Desktop) :

```sh
bao kv patch secret/filon mcp_token="$(openssl rand -hex 32)"
bao kv get -field=mcp_token secret/filon    # à recopier dans la config du client MCP
```

Sans ces champs, le pod ne démarre pas (Secret `filon-login` ou `filon-mcp` absent, ou appli qui refuse de démarrer sans `FILON_PASSWORD` ou `FILON_MCP_TOKEN`).

Valeurs lues au démarrage : après un changement, relancer le pod (`kubectl rollout restart`).

## Déploiement

Chaque push sur `main` de filon (`main.yml`) déploie l'image `ghcr.io/jbwittner/filon:main-sha-<sha>`.

La CI commite `chore(filon): déployer …` sur `main` ici (ligne `image:` = tag fixe `@sha256:…`) → ArgoCD. Renovate ignore cette image (`renovate.json`).

Prérequis côté filon : secret Actions `GITOPS_TOKEN` (PAT fine-grained, Contents read/write sur `homelab_gitops`).

## Sauvegardes

WAL archivés en continu et sauvegarde complète chaque nuit par le plugin barman-cloud, sur GCS sans clé (Workload Identity Federation) : [sauvegardes](sauvegardes.md#bases-postgres-cnpg).

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n argocd get application filon-kalecgos
kubectl --context admin@bleu-kalecgos -n filon get externalsecret,cluster,objectstore,scheduledbackup,backup,pods
curl -s https://filon.lan.wittner.tech/actuator/health    # {"status":"UP"}
curl -s https://filon.lan.wittner.tech/actuator/info      # commit et heure du build, Java, OS
```

Probes : liveness = l'appli seule (une panne de Postgres ne relance pas le pod), readiness = l'appli + la base (le pod sort du trafic tant que Postgres est absent). Tuile Homepage : commit déployé (`/actuator/info`).

Interface web derrière un formulaire de login (utilisateur de `secret/filon`) ; la santé et `/actuator/info` répondent sans session, le reste de `/actuator` est refusé. Pas de métriques appli : seul Postgres est supervisé.
