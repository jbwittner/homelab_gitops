# cert-manager

## Rôle

Émission et renouvellement automatiques des certificats TLS (Let's Encrypt, DNS-01 Cloudflare).
Ce composant n'installe **que** le moteur ; les objets métier (ClusterIssuer, Certificates,
token Cloudflare) vivent dans [`cert-manager-config`](../cert-manager-config/README.md).

## Fichiers

- `cert-manager.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cert-manager`
- `helm-values.yaml` — `crds.enabled: true` + `crds.keep: true` (les CRDs survivent à une
  désinstallation du chart, donc les `Certificate` existants ne sont pas emportés)

## Contraintes

- Wave **-5** : après les CRDs Gateway API, avant tout consommateur de certificat.
- Les CRDs sont posées par le chart, pas par un manifeste : ne pas les dupliquer ailleurs.

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cert-manager.app.yaml`, commit, push.
- **Debug émission** :
  ```bash
  kubectl -n gateway get certificate
  kubectl -n gateway describe certificaterequest
  kubectl -n cert-manager get challenges
  kubectl -n cert-manager logs deploy/cert-manager
  ```
- **Challenge DNS-01 bloqué en `Pending`** : le self-check de propagation passe par le DNS **du
  cluster**. Si un upstream renvoie NXDOMAIN sur `_acme-challenge`, rien n'aboutit. Remède
  (non appliqué aujourd'hui, à ajouter dans `helm-values.yaml` si le cas se représente) :
  ```yaml
  extraArgs:
    - --dns01-recursive-nameservers=1.1.1.1:53
    - --dns01-recursive-nameservers-only
  ```
  Après un run avorté, purger les TXT `_acme-challenge` orphelins côté Cloudflare.
