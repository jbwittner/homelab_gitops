# cert-manager

## Rôle

Émission et renouvellement automatique des certificats TLS (Let's Encrypt DNS-01 Cloudflare).
Ce composant n'installe **que** le moteur ; les objets métier (ClusterIssuer, Certificates)
vivent dans [`cert-manager-config`](../cert-manager-config/README.md).

## Fichiers

- `cert-manager.app.yaml` — Application (archétype (a) : Helm + `$values`), ns `cert-manager`
- `helm-values.yaml` — `crds.enabled/keep: true` + épinglage des résolveurs récursifs DNS-01
  (le self-check de propagation ne doit pas passer par le DNS du cluster, voir phase 7 du runbook)

## Opérations

- **Upgrade** : bumper `targetRevision` dans `cert-manager.app.yaml`, commit, push.
- **Debug émission** : `kubectl get certificate -n gateway`,
  `kubectl describe certificaterequest -n gateway`,
  `kubectl -n cert-manager logs deploy/cert-manager`.
