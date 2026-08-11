# openbao

## Rôle

Gestionnaire de secrets (fork libre de Vault), stockage **raft intégré**, un replica.
Contrairement à [`sealed-secrets`](../../infra/sealed-secrets/README.md), ce n'est **pas** un
canal de secrets GitOps : son contenu vit dans le PVC, hors de Git. UI exposée sur
`openbao.lan.wittner.tech`.

## Fichiers

- `openbao.app.yaml` — Application (archétype (b) : Helm + `$values` + `manifests/`), ns `openbao`
- `helm-values.yaml` — raft 1 replica, injector, ServiceMonitor, rétention du PVC
- `manifests/namespace.yaml` — ns `openbao` (wave -1), sans label PodSecurity
- `manifests/openbao-httproute.yaml` — UI sur le listener `https-internal` de `shared-gw`

## Contraintes

- **OpenBao démarre scellé.** Après chaque redémarrage du pod, il faut le desceller à la main
  (voir Opérations). Tant qu'il l'est, l'API répond `503` et le pod n'est pas `Ready` — c'est
  attendu, pas une panne.
- **Les clés de descellement et le token root ne vont JAMAIS dans Git**, même en `SealedSecret` :
  ce sont elles qui protègent tout le reste. Elles vivent au coffre, hors cluster, comme la clé
  privée sealed-secrets. Sans elles, le contenu du PVC est définitivement illisible.
- **`persistentVolumeClaimRetentionPolicy: Retain`** des deux côtés : sans ça, un `prune` ArgoCD
  ou un passage à 0 replica effacerait le PVC, donc le coffre. Ne pas y toucher.
- **L'HTTPRoute pointe sur le Service `openbao`, pas `openbao-active`.** Ce dernier ne sélectionne
  que les pods labellisés `openbao-active: "true"`, label posé une fois le nœud descellé et
  leader : un OpenBao scellé n'y a aucun endpoint, et l'UI serait injoignable exactement quand on
  en a besoin pour le desceller.
- **Le PDB est désactivé.** À un replica le chart calcule `maxUnavailable: 0`, ce qui bloque
  indéfiniment tout `kubectl drain` du nœud.
- **La cible Prometheus disparaît quand OpenBao est scellé** (le ServiceMonitor sélectionne le
  Service `-active`, sans endpoint dans cet état). Une alerte sur ce composant doit donc porter
  sur l'*absence* de la série, pas sur `up == 0`.
- **Le contenu du coffre n'est pas GitOps.** Le chart déploie le serveur, il ne configure rien à
  l'intérieur : méthodes d'auth, policies, roles et moteurs de secrets se posent au CLI `bao` ou
  par le provider Terraform/OpenTofu, et ne vivent pas dans `cluster/`. L'agent injector, en
  particulier, n'injecte rien tant que l'auth `kubernetes` + une policy + un role n'existent pas.
  Le candidat naturel pour cette configuration est le repo Terraform qui gère déjà les providers
  OIDC authentik ; tant que ce n'est pas tranché, ces gestes sont manuels et non reproductibles
  depuis Git. [`doc/regles-gitops.md`](../../../doc/regles-gitops.md) dit encore que les
  `SealedSecret` sont le seul canal de secrets : à mettre à jour le jour où un composant
  consomme réellement le coffre.

## Opérations

- **Initialiser** (une seule fois, à la première installation) — conserver la sortie au coffre :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao operator init
  ```
- **Desceller** (après chaque redémarrage du pod) — répéter avec 3 parts de clé distinctes :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao operator unseal
  kubectl -n openbao exec -ti openbao-0 -- bao status     # Sealed=false, HA Mode=active
  ```
- **Sauvegarder le coffre** (à chaud, possible grâce au backend raft) :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft snapshot save /tmp/openbao.snap
  kubectl -n openbao cp openbao-0:/tmp/openbao.snap ./openbao.snap
  ```
  Le snapshot contient **tout le coffre chiffré** : le traiter comme un secret, et le stocker
  hors cluster. Il reste inutile sans les clés de descellement. Le chart embarque un CronJob de
  snapshot automatique (`snapshotAgent`), non activé : il ne sait pousser que vers S3, et le
  homelab n'a ni bucket ni MinIO. Le jour où l'un des deux existe, c'est la voie à privilégier
  plutôt qu'un CronJob maison.
- **Restaurer** :
  ```bash
  kubectl -n openbao cp ./openbao.snap openbao-0:/tmp/openbao.snap
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft snapshot restore /tmp/openbao.snap
  ```
- **Activer l'auth Kubernetes** (prérequis de l'injector, à faire une fois descellé et
  authentifié avec le token root) :
  ```bash
  kubectl -n openbao exec -ti openbao-0 -- bao auth enable kubernetes
  kubectl -n openbao exec -ti openbao-0 -- sh -c \
    'bao write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
  ```
- **Upgrade** : bumper `targetRevision` dans `openbao.app.yaml`, commit, push. Le pod redémarre
  **scellé** — prévoir le descellement dans la foulée.
- **Debug** :
  ```bash
  kubectl -n openbao get pods,pvc,svc
  kubectl -n openbao logs openbao-0
  kubectl -n openbao exec -ti openbao-0 -- bao status
  kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers   # descellé requis
  kubectl get httproute -n openbao openbao -o yaml                        # Accepted/ResolvedRefs
  ```
  Si le pod échoue au démarrage sur une erreur `mlock` / `cannot allocate memory` : le chart pose
  `SKIP_SETCAP=true`, donc pas de capability `IPC_LOCK` (elle serait de toute façon refusée par
  le PodSecurity `baseline` de Talos). Le correctif est `disable_mlock = true` dans le bloc
  `config` de `helm-values.yaml`.
