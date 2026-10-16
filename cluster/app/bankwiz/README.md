# bankwiz

## Rôle

API REST de [bankwiz_server](https://forgejo.wittner.tech/jbwittner/bankwiz_server) (Spring Boot,
hexagonal). Un sous-dossier par environnement, chacun une `Application` autonome nommée
`bankwiz-<env>`, dans son propre namespace. Seul `dev` existe : il suit la branche `develop`.

## Fichiers

- `dev/bankwiz-dev.app.yaml` — l'`Application` (kustomize seul, archétype (c)), ns `bankwiz-dev`.
- `dev/manifests/deployment.yaml` — une réplique, image épinglée par tag fixe + digest ;
  identifiants de base injectés depuis le secret `bankwiz-db-app`.
- `dev/manifests/bankwiz-db.yaml` — `Cluster` CNPG `bankwiz-db` : PostgreSQL 18, une instance,
  2Gi, base et rôle `bankwiz`. **Non sauvegardée.**
- `dev/manifests/application.yaml` — configuration Spring de l'environnement (profil actif
  compris), ConfigMap par `configMapGenerator` monté en `/app/config/` : écrase le
  `application.yaml` du jar clé par clé, et toute modification redémarre le pod (hash du nom).
- `dev/manifests/bankwiz-api-httproute.yaml` — `bankwiz-api.dev.lan.wittner.tech`, listener `https-dev`.

## Contraintes

- **Un dossier par environnement, pas par cluster.** C'est un écart assumé à
  [conventions.md](../../../doc/conventions.md), où un sous-dossier désigne un cluster d'
  `ApplicationSet` : ici chaque environnement est une `Application` découverte directement par le
  glob récursif du tier-2. Le nom `bankwiz-<env>` évite la collision dans le ns `argocd` du hub.
- **Le hostname a deux niveaux sous `lan`** : `*.lan.wittner.tech` ne le couvre pas. Il est servi
  par le listener `https-dev` de `shared-gw` et le certificat `wildcard-dev-lan-tls`
  (`*.dev.lan.wittner.tech`), ajoutés pour lui dans
  [gateway-api](../../infra/gateway-api/README.md) et [cert-manager](../../infra/cert-manager/README.md).
  Tout futur `<app>.dev.lan.wittner.tech` les réutilise.
- **Reverse proxy `192.168.1.50` et résolveur DNS** : le nom doit y être déclaré, hors dépôt (cf.
  [reseau.md](../../../doc/reseau.md) §DNS et reverse proxy). Un wildcard DNS `*.lan` ne couvre pas
  forcément `*.dev.lan` selon le résolveur ; sans déclaration au proxy, l'URL répond **404**.
- **Aucun secret de pull, et c'est voulu.** Les paquets du registre Forgejo sont **publics** :
  leur visibilité suit celle du propriétaire (`jbwittner`), pas celle du dépôt. `bankwiz_server`
  est privé, son image ne l'est pas — n'importe qui peut la tirer et décompiler le jar (constaté le
  2026-10-14 : manifeste en 200 avec un jeton anonyme). Choix assumé, aucune app n'a donc
  d'`imagePullSecrets`. Si un jour les paquets passent privés, l'accès se déclare **une fois** au
  niveau des nœuds (`machine.registries.config."forgejo.wittner.tech".auth` dans `talconfig.yaml`
  de `homelab_talos`, jeton chiffré SOPS) plutôt que par un Secret dupliqué dans chaque namespace.
- **Tag fixe `develop-sha-<sha>`, jamais `develop`.** Le tag mobile ne fait rien bouger côté
  ArgoCD : il faudrait un `rollout restart` à la main à chaque push. Monter de version = un commit.
- **Une seule réplique** : le mot de passe du compte `user` est généré au démarrage, différent par
  pod.
- **Base CNPG câblée avant l'application.** L'image `develop` actuelle tourne encore sur
  `spi-memory` (données perdues à chaque redémarrage) : sans JDBC dans le classpath,
  `spring.datasource.url` (`application.yaml`) et `SPRING_DATASOURCE_USERNAME/PASSWORD` sont
  ignorés. Ils prennent effet tels quels dès qu'une image avec `spi-postgres` (branche
  `feat/postgresql` du dépôt applicatif) est déployée — rien à toucher ici.
- **`bankwiz-db` n'est sauvegardée par rien** : pas de chaîne barman, et son PVC est exclu de
  kopia par la règle cluster-wide de [velero](../../infra/velero/README.md). Choix assumé pour une
  base de dev : Flyway recrée le schéma, le profil `dev` rejoue les comptes d'exemple. Nœud perdu
  ou `Cluster` supprimé = base perdue.
- **`imageName` épinglé à la main** (`18.6-standard-trixie`) : Renovate ne lit pas ce champ, et le
  laisser au défaut de l'opérateur exposerait à une montée de majeure lors d'un upgrade de CNPG.
- **Actuator n'est pas exposé** : `management.server.port: 8081` (`application.yaml`) le sort du
  port applicatif, et le Service ne publie que 8080 — `/actuator/*` n'existe pas derrière
  l'HTTPRoute. Les sondes visent le port `management` du pod directement : groupes Kubernetes
  `/actuator/health/liveness` et `/readiness`, qui ignorent volontairement la base (une base
  indisponible ne tue ni ne retire le pod).

## Opérations

### Monter de version

Le workflow `develop.yml` du dépôt applicatif pousse `develop-sha-<sha court>` à chaque push sur
`develop`. Récupérer le digest puis remplacer la ligne `image:` du `deployment.yaml` :

```bash
docker buildx imagetools inspect forgejo.wittner.tech/jbwittner/bankwiz-server:develop-sha-<sha> \
  --format '{{json .Manifest.Digest}}'
```

### Vérifier

```bash
kubectl -n bankwiz-dev get deploy,pod,svc,httproute
kubectl -n bankwiz-dev get clusters.postgresql.cnpg.io bankwiz-db   # STATUS=Cluster in healthy state
kubectl -n gateway get certificate wildcard-dev-lan-tls        # READY=True
kubectl -n bankwiz-dev logs deploy/bankwiz-api | grep -i 'generated security password'
curl -s https://bankwiz-api.dev.lan.wittner.tech/public/ping
curl -s -o /dev/null -w '%{http_code}\n' https://bankwiz-api.dev.lan.wittner.tech/actuator/health   # 404 : non exposé
kubectl -n bankwiz-dev port-forward deploy/bankwiz-api 8081   # puis curl localhost:8081/actuator/info
```

Le mot de passe du compte `user` change à **chaque** redémarrage du pod : le relire dans les logs.
Swagger : `https://bankwiz-api.dev.lan.wittner.tech/swagger-ui.html`.
