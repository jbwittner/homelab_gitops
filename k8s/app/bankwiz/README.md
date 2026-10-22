# bankwiz

## Rôle

API REST de `bankwiz_server` (Spring Boot, hexagonal). Un sous-dossier par environnement, chacun une `Application` autonome nommée
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
- ⚠️ **L'image vit dans un registre qui n'est plus alimenté.** La ligne `image:` de
  `deployment.yaml` pointe le registre de l'ancienne forge : plus aucun build n'y publie, et rien
  ne garantit qu'il réponde encore. Le pod tourne tant que l'image est **en cache sur son nœud** ;
  un reschedule vers un nœud qui ne l'a pas finit en `ImagePullBackOff`, sans autre signal. À
  migrer vers `ghcr.io` quand la CI de `bankwiz_server` passera sur GitHub Actions — d'ici là,
  **aucune montée de version n'est possible** (§Monter de version).
- **Aucun secret de pull.** L'image est tirée en anonyme, aucune app n'a d'`imagePullSecrets`. Si
  le registre cible est un jour privé, l'accès se déclare **une fois** au niveau des nœuds
  (`machine.registries.config."<registre>".auth` dans `talconfig.yaml` de `homelab_talos`, jeton
  chiffré SOPS) plutôt que par un Secret dupliqué dans chaque namespace.
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

⚠️ **Bloqué** : plus aucune CI ne publie d'image (cf. §Contraintes). Une fois la CI du dépôt
applicatif migrée, elle devra pousser un tag fixe `develop-sha-<sha court>` à chaque push sur
`develop`. Récupérer alors le digest puis remplacer la ligne `image:` du `deployment.yaml` :

```bash
docker buildx imagetools inspect <registre>/jbwittner/bankwiz-server:develop-sha-<sha> \
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
