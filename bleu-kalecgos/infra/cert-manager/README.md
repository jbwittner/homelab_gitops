# cert-manager — bleu-kalecgos

## Rôle

Émission et renouvellement automatique des certificats TLS (Let's Encrypt DNS-01 Cloudflare).
Ce composant n'installe **que** le moteur ; les objets métier (ClusterIssuer, Certificates)
vivent dans [`cert-manager-config`](../cert-manager-config/README.md).

## Source & versions

| Quoi | Valeur |
|---|---|
| Chart | `cert-manager` — https://charts.jetstack.io |
| Version épinglée | `v1.21.0` |
| Namespace | `cert-manager` (CreateNamespace) |
| Release Helm | `cert-manager` |
| Archétype | (a) Helm + `$values` |

## Fichiers

- `cert-manager.app.yaml` — Application multi-source
- `helm-values.yaml` — `crds.enabled/keep: true` + épinglage des résolveurs récursifs DNS-01
  (`1.1.1.1` — le self-check de propagation ne doit pas passer par le DNS du cluster, voir
  phase 7 du runbook)

## Dépendances & sync-wave

Wave **-5** : avant `cert-manager-config` (-4) qui a besoin des CRDs `Issuer`/`Certificate`.
Requis par : `cert-manager-config`, tout TLS du Gateway.

## Opérations courantes

- **Upgrade** : bumper `targetRevision` dans `cert-manager.app.yaml`, commit, push.
- **Debug émission** : `kubectl get certificate -n gateway`,
  `kubectl describe certificaterequest -n gateway`,
  `kubectl -n cert-manager logs deploy/cert-manager`.
