# forgejo-runner

## Rôle

L'exécuteur des workflows Forgejo Actions des dépôts de `jbwittner`. Un pod, trois conteneurs, et
un démon Docker complet pour que **testcontainers** fonctionne.

La forge, elle, tourne **hors du cluster** (Docker, machine dédiée — cf.
[doc/forgejo-docker-bascule-et-sauvegarde.md](../../../doc/forgejo-docker-bascule-et-sauvegarde.md)).
Ce composant est donc un client : il va chercher ses jobs par Internet, il n'est jamais joint.

## Pourquoi il existe sous cette forme

Trois contraintes en cascade, chacune découlant de la précédente.

**1. Talos n'a pas de Docker.** Il a containerd. La doc Forgejo propose trois façons de donner
Docker aux workflows — `docker_host: automount` (partager le socket de l'hôte), LXC, ou
Docker-in-Docker. Les deux premières sont hors d'atteinte : il n'existe aucun
`/var/run/docker.sock` à monter, et un LXC ne se lance pas dans un pod. **DinD est le seul
chemin**, ce n'est pas une préférence.

**2. DinD exige un conteneur privilégié.** D'où le label `pod-security.kubernetes.io/enforce:
privileged` sur le namespace — le deuxième du dépôt après `openebs`.

**3. Le démon n'écoute sur aucun port — un socket Unix dans un `emptyDir` partagé.** La recette
DinD de la doc Forgejo fait écouter le démon en `tcp://0.0.0.0:2375` sans TLS, parce qu'elle
suppose deux conteneurs Docker séparés. Ici le runner et le démon sont dans le **même pod** : un
socket leur suffit. Le premier montage de ce composant suivait la doc, et rendait le démon
joignable sur l'IP du pod — soit un accès root au nœud Talos pour tout pod du cluster, tenu par la
seule `CiliumNetworkPolicy`. Le socket supprime le port au lieu de le garder fermé.

C'est aussi la réponse à la dépréciation Docker : depuis la 29, `dockerd` avertit qu'une écoute
TCP sans chiffrement deviendra *« a hard failure preventing the daemon from starting »*
([moby#36357](https://github.com/moby/moby/issues/36357), ouvert depuis 2018, milestone
`v-future`). Aucun drapeau d'opt-out n'existe ni n'est prévu.
*Alternative écartée* : TLS via `DOCKER_TLS_CERTDIR`. L'image `docker:dind` génère ses
certificats seule, mais le certificat serveur ne porte pas `pod.docker.internal` dans ses SAN —
toute vérification depuis un job container échouerait. Émettre les nôtres avec cert-manager
coûterait un Issuer, un Certificate, trois montages de Secret et une rotation à surveiller, pour
un résultat **moins bon** : le port resterait ouvert, simplement chiffré.

> [!IMPORTANT]
> `manifests/netpol.yaml` n'est pas du durcissement optionnel pour autant. Il porte tout le
> filtrage **sortant**, qui contraint les workflows eux-mêmes et tient le LAN hors de portée d'un
> build. Et si quelqu'un rouvrait un jour une écoute TCP sur le démon, son default-deny d'ingress
> redeviendrait le seul rempart — sans que rien ne le signale.

## Fichiers

- `forgejo-runner.app.yaml` — Application, ns **`forgejo-runner`**, wave par défaut
- `manifests/namespace.yaml` — le label PSA `privileged`, et pourquoi il est irréductible
- `manifests/statefulset.yaml` — initContainer + `dind` + `runner` + `prune`
- `manifests/config/config.yml` — la partie **commune** de la configuration, **sans** `server:`
- `manifests/connections.secret.example.yaml` — template du Secret des enregistrements, **et la
  procédure d'enregistrement hors ligne**. ⚠️ Son `SealedSecret` **n'est pas encore dans le
  repo** : deux lignes commentées dans `kustomization.yaml` — cf. *Mise en service*
- `manifests/netpol.yaml` — le default-deny d'ingress. **Lire son en-tête avant d'y toucher**
- `manifests/prometheusrule.yaml` — trois alertes, groupe `forgejo-runner.rules`

## Le montage Docker, en clair

Deux plans distincts, et les confondre est l'erreur la plus facile.

**Plan de contrôle — parler au démon.** Un seul socket, jamais le réseau :

| Qui | Réglage | Valeur |
|---|---|---|
| le conteneur `runner` | `DOCKER_HOST` (statefulset) | `unix:///run/docker-sock/docker.sock` |
| le conteneur `prune` | `DOCKER_HOST` (statefulset) | idem |
| le runner, pour placer les jobs | `container.docker_host` (config.yml) | idem |
| le **job container** | *rien* | le runner **monte** le socket à `/var/run/docker.sock` — c'est ce qu'un `docker_host` en `unix://` permet et qu'un `tcp://` interdit |

**Plan de données — joindre ce que les conteneurs publient.** Là, le réseau est inévitable :
les ports publiés atterrissent dans la netns **du pod**, pas dans celle du job container.
`container.options: --add-host=pod.docker.internal:host-gateway` pose l'alias qui y mène, et deux
réglages s'en servent : `TESTCONTAINERS_HOST_OVERRIDE` et `cache.host` (le proxy de cache du
runner écoute au même endroit).

⚠️ **`TESTCONTAINERS_HOST_OVERRIDE` est devenu indispensable** avec le socket. Testcontainers
déduit l'adresse des ports publiés depuis `DOCKER_HOST` ; face à un socket Unix il conclut
`localhost`, qui est faux ici. Sans l'override, chaque test part en timeout sur un conteneur
pourtant démarré — indiscernable d'un service lent à s'initialiser.

Ryuk fonctionne sans réglage : `/var/run/docker.sock` est bien présent dans le job container.

## Contraintes

- **Toute image de job DOIT contenir Node.js.** `actions/checkout`, `actions/cache`,
  `actions/setup-*` sont des actions JavaScript exécutées avec le node de l'image. Une image
  `maven:` ou `golang:` nue échoue dès la première étape `uses:`, **sur un message qui parle de
  node, pas du JDK** — le piège prend dix minutes à diagnostiquer la première fois.
  D'où `catthehacker/ubuntu:act-22.04` par défaut, avec `setup-java` / `setup-go` pour poser les
  toolchains et le serveur de cache pour ne pas les retélécharger.
  *Alternative écartée* : une image maison à trois toolchains. Elle demanderait sa propre chaîne
  de build, son dépôt et sa surveillance de fraîcheur, pour gagner quelques dizaines de secondes
  par run.
- **`runner.capacity` reste à 1. Le parallélisme se règle en replicas.** Deux jobs dans un même
  runner partagent un démon dind : ils se voient (`docker ps`, `docker exec`), ce que la doc
  Forgejo signale comme une fuite possible d'un job vers l'autre. Un replica de plus = un dind de
  plus = une isolation réelle. Le prix est un enregistrement de plus — cf. ci-dessous.
- **Chaque replica a son propre enregistrement.** Un couple (uuid, token) ne se partage pas entre
  deux daemons. C'est la raison d'être du StatefulSet (ordinal stable) et de l'initContainer.
- **La portée d'enregistrement est l'UTILISATEUR**, pas l'instance. Le runner n'exécute que les
  workflows des dépôts **dont `jbwittner` est propriétaire** — la propriété, pas les droits : un
  dépôt d'un tiers où tu es collaborateur ne l'atteint jamais. ⚠️ Une **organisation** n'est pas
  couverte et demanderait son propre enregistrement. ⚠️ Tout nouveau dépôt à toi est couvert
  d'office, sans décision explicite.
- **La policy réseau contraint aussi les workflows, et c'est voulu.** Le trafic d'un job sort par
  le bridge de dind, masqué derrière l'IP du pod : il se présente à Cilium avec l'identité de ce
  pod. Internet public est ouvert (registres, Maven Central, npm, proxy Go) ; **tout le LAN est
  fermé — à une exception près**.
- **L'exception : `192.168.1.50:443`, et elle était inévitable.** `forgejo.wittner.tech` est à
  double horizon : depuis le cluster, il résout vers le reverse proxy du LAN et non vers l'adresse
  publique. Sans cette règle le runner ne joint jamais la forge.
  ⚠️ **Elle ouvre plus que la forge** : ce `:443` sert *tous* les vhosts `*.lan.wittner.tech` du
  proxy, dont `forgejo-metrics` et `forgejo-db-metrics`. Une workflow peut les solliciter ; ce qui
  les protège est leur authentification (Bearer, Basic — cf.
  [forgejo-monitoring](../forgejo-monitoring/README.md)), pas cette policy. Surface assumée : la
  refermer supposerait que la forge soit joignable autrement qu'à travers ce proxy.
- **Le risque résiduel est réel et assumé.** Le dind contient l'essentiel : un `docker run -v /:/h`
  dans une workflow monte la racine du *conteneur dind*, pas celle du nœud. Ce qui reste est une
  évasion du dind privilégié lui-même. Acceptable ici parce que la forge est privée, sans forks
  externes : le code exécuté est **le tien**. Ça cesserait de l'être au premier dépôt public —
  il faudrait alors l'approbation manuelle des workflows de PR externes, **côté Forgejo**.
- **Aucune métrique de job.** forgejo-runner n'expose pas de `/metrics`. Les alertes disent « le
  processus tourne », rien de plus : un runner vivant mais mal authentifié, ou qui ne reçoit
  jamais de job, est indistinguable d'un runner au repos. Le seul témoin est l'état `offline`
  dans l'UI Forgejo, que rien ici ne lit.
- **Dépendance circulaire, version faible.** ArgoCD lit la forge ; ce runner tourne dans le
  cluster qu'ArgoCD déploie. Pas bloquant — le runner ne sert pas le GitOps, il ne fait que ne
  pas exister tant que le cluster n'est pas remonté. **Rien à construire là-dessus** ; c'est écrit
  pour que personne ne « répare » plus tard un problème qui n'en est pas un.
- **Les images ne sont jamais rafraîchies d'elles-mêmes** (`force_pull: false`) — c'est la
  contrepartie du cache sur PVC. Cf. *Opérations*.

## Mise en service

> [!IMPORTANT]
> L'étape 2 s'exécute **sur la machine Docker de la forge**, pas depuis ce dépôt : elle demande un
> accès administrateur au binaire Forgejo.

1. **Générer le secret et en dériver l'uuid** (l'uuid n'est pas aléatoire : c'est l'ASCII des
   16 premiers caractères du secret, en hexadécimal) :
   ```bash
   SECRET=$(openssl rand -hex 20)
   # `od` et non `xxd` : ce dernier vient de `vim-common`, absent d'une Debian minimale.
   UUID=$(printf '%s' "${SECRET:0:16}" | od -An -tx1 | tr -d ' \n' \
          | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
   echo "uuid:  $UUID"
   echo "token: $SECRET"
   ```
2. **Déclarer le runner sur la forge** :
   ```bash
   docker compose exec forgejo forgejo forgejo-cli actions register \
     --name kube-runner-0 --scope jbwittner --secret "$SECRET"
   ```
   La commande réaffiche l'uuid : il doit être **identique** à celui calculé en 1.
3. **Sceller.** Le Secret ne porte qu'une clé, `connection-0.yml` : un seul replica est déployé.
   En ajouter un second est une procédure à part entière — cf. *Monter le parallélisme*.
   ```bash
   cp cluster/app/forgejo-runner/manifests/connections.secret.example.yaml \
      cluster/app/forgejo-runner/manifests/connections.secret.yaml
   # renseigner les uuid/token, puis :
   kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
     < cluster/app/forgejo-runner/manifests/connections.secret.yaml \
     > cluster/app/forgejo-runner/manifests/connections.sealed.yaml
   rm cluster/app/forgejo-runner/manifests/connections.secret.yaml
   ```
4. **Décommenter les DEUX lignes** `connections.sealed.yaml` de `kustomization.yaml` (la ressource
   *et* l'entrée du `configMapGenerator`), dans le **même commit**.
5. **Vérifier la résolution de la forge** — cf. *Opérations*, premier point.

## Monter le parallélisme

Un seul replica est déployé, et `runner.capacity` reste à 1 : **un job à la fois**. Un second job
attend, sans expirer, côté forge.

Ajouter un replica n'est pas un chiffre à changer : chaque replica a **son propre enregistrement**
auprès de la forge (un couple uuid/token ne se partage pas entre deux daemons). L'ordre compte, et
l'inverser laisse un pod en erreur.

Pour passer de `N` à `N+1` replicas — l'exemple ci-dessous ajoute `forgejo-runner-1`, donc
`N = 1` :

1. **Enregistrer le nouveau runner**, sur la machine Docker de la forge. Même procédure qu'à la
   mise en service, avec un nom distinct :
   ```bash
   SECRET=$(openssl rand -hex 20)
   UUID=$(printf '%s' "${SECRET:0:16}" | od -An -tx1 | tr -d ' \n' \
          | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
   echo "uuid:  $UUID"; echo "token: $SECRET"

   docker compose exec forgejo forgejo forgejo-cli actions register \
     --name kube-runner-1 --scope jbwittner --secret "$SECRET"
   ```
   ⚠️ **`--name` doit être différent** de celui des runners déjà enregistrés. Un nom réutilisé
   avec un secret dont les 16 premiers caractères diffèrent crée un **second** runner homonyme,
   et l'UI devient illisible.

2. **Ajouter la clé au Secret, et resceller.** Le `SealedSecret` est un tout : il se régénère
   depuis un fichier en clair complet, on n'y ajoute pas une clé après coup.
   ```bash
   cp cluster/app/forgejo-runner/manifests/connections.secret.example.yaml \
      cluster/app/forgejo-runner/manifests/connections.secret.yaml
   ```
   Renseigner `connection-0.yml` avec le couple **déjà en service** (tu dois donc l'avoir gardé ;
   sinon, faire tourner son secret — cf. *Rotation* dans
   `manifests/connections.secret.example.yaml`), puis ajouter à la suite, à la même indentation :
   ```yaml
     connection-1.yml: |
       server:
         connections:
           forgejo:
             url: https://forgejo.wittner.tech/
             uuid: <uuid de kube-runner-1>
             token: <secret 40 hex de kube-runner-1>
   ```
   Le nom de la clé **est** l'ordinal du pod : `connection-1.yml` → `forgejo-runner-1`. Puis :
   ```bash
   kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
     < cluster/app/forgejo-runner/manifests/connections.secret.yaml \
     > cluster/app/forgejo-runner/manifests/connections.sealed.yaml
   rm cluster/app/forgejo-runner/manifests/connections.secret.yaml
   ```

3. **Seulement ensuite**, passer `replicas: 2` dans `manifests/statefulset.yaml`.

Les étapes 2 et 3 peuvent aller dans le **même commit** — le nouveau pod ne démarre qu'une fois le
Secret déchiffré par le contrôleur, et l'ordre de sync ArgoCD s'en charge. Ce qui ne peut pas
attendre, c'est l'étape 1 : elle est hors du dépôt.

⚠️ **Monter le chiffre sans la clé** laisse le nouveau pod en `Init:CrashLoopBackOff`, avec le
message explicite dans `kubectl -n forgejo-runner logs forgejo-runner-1 -c render-config`. Les
runners déjà en place continuent de tourner — la dégradation n'est pas une panne, et c'est
`ForgejoRunnerReplicaMismatch` qui la signale au bout de 30 min, pas `ForgejoRunnerDown`.

⚠️ **Coût par replica** : **60 Gi de PVC** (10 Gi de cache + 50 Gi de stockage dind, en thin) et
jusqu'à 7 Gi de RAM. Vérifier la place dans `lvmvg` et l'état d'`openebs-monitoring` avant.

**Redescendre** est plus simple : baisser `replicas`, et supprimer le runner correspondant dans
l'UI Forgejo. ⚠️ Les PVC du pod retiré **ne sont pas supprimés** par le StatefulSet — ils restent
et seront réutilisés tels quels si tu remontes le chiffre (cache intact, ce qui est l'effet
voulu). Pour récupérer la place, les supprimer à la main :
`kubectl -n forgejo-runner delete pvc data-forgejo-runner-1 dind-storage-forgejo-runner-1`.
La clé `connection-1.yml` peut rester scellée : elle ne coûte rien et évite de refaire l'étape 1.

## Opérations

- **Diagnostiquer un runner qui ne prend aucun job**, dans cet ordre — les trois premières causes
  sont muettes :
  ```bash
  # 1. vers quelle adresse la forge résout-elle ? (attendu : 192.168.1.50, le reverse proxy —
  #    seule adresse du LAN que netpol.yaml laisse passer, et seulement sur 443)
  kubectl -n forgejo-runner exec forgejo-runner-0 -c runner -- getent hosts forgejo.wittner.tech
  # 2. le config.yml a-t-il été assemblé ?
  kubectl -n forgejo-runner logs forgejo-runner-0 -c render-config
  # 3. le démon Docker répond-il ?
  kubectl -n forgejo-runner exec forgejo-runner-0 -c dind -- \
    docker -H unix:///run/docker-sock/docker.sock info
  # 4. les logs du runner (authentification, fetch)
  kubectl -n forgejo-runner logs forgejo-runner-0 -c runner --tail=50
  ```
  Puis l'UI Forgejo, `/user/settings/actions/runners` : un runner `offline` alors que le pod est
  `Running` désigne un token périmé — rien dans le cluster ne le dira.
  ⚠️ À distinguer d'un **blocage réseau**, qui lui est bruyant : le conteneur `runner` sort en
  `Error` et redémarre en boucle, sur un `deadline_exceeded` à l'appel `Declare`. Timeout et non
  refus = signature d'un drop Cilium, donc la règle `192.168.1.50` de `netpol.yaml`.
- **Soupçonner la policy réseau** (mode d'échec : timeout, jamais un refus lisible) :
  ```bash
  cilium monitor --type drop -n forgejo-runner
  kubectl -n forgejo-runner delete ciliumnetworkpolicy forgejo-runner   # ArgoCD la repose
  ```
  ⚠️ Ne pas laisser le cluster dans cet état : le démon Docker est nu tant qu'elle est absente.
- **Rafraîchir l'image de job** (`force_pull: false` fige le tag une fois tiré). L'image est celle
  du label, dans `manifests/config/config.yml` — ne pas la recopier ici, elle dériverait :
  ```bash
  IMG=$(grep -o 'docker://[^"]*' cluster/app/forgejo-runner/manifests/config/config.yml \
        | sed 's|docker://||' | sort -u)
  for i in $IMG; do
    kubectl -n forgejo-runner exec forgejo-runner-0 -c dind -- \
      docker -H unix:///run/docker-sock/docker.sock pull "$i"
  done
  ```
- **Élaguer tout de suite** sans attendre le passage quotidien du sidecar :
  ```bash
  kubectl -n forgejo-runner exec forgejo-runner-0 -c prune -- \
    docker system prune -af --filter "until=24h"
  ```
- **Retirer le composant** : renommer `forgejo-runner.app.yaml` en `.noapp.yaml`. Le `prune`
  d'ArgoCD emporte le namespace, les PVC et la policy **ensemble** — ne jamais supprimer la policy
  seule.
