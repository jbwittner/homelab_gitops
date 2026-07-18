# bleu-kalecgos

Cluster actif — Talos mono-nœud `vert-eranikus`, piloté par ArgoCD en app-of-apps
(`cluster.yaml` → `*.bootstrap.yaml` → `*.app.yaml`, cf. [doc/conventions.md](../doc/conventions.md)).

## Infra

- [argocd](infra/argocd/README.md) — moteur GitOps, self-managed
- [cert-manager](infra/cert-manager/README.md) — moteur d'émission TLS
- [cert-manager-config](infra/cert-manager-config/README.md) — ClusterIssuer Let's Encrypt + wildcards
- [cilium](infra/cilium/README.md) — CNI, Gateway API, LB L2
- [gateway-api](infra/gateway-api/README.md) — CRDs Gateway API + `shared-gw`
- [openebs](infra/openebs/README.md) — stockage LVM node-local
- [sealed-secrets](infra/sealed-secrets/README.md) — déchiffrement des SealedSecrets

## App

- [cnpg](app/cnpg/README.md) — opérateur CloudNativePG
- [test-nginx](app/test-nginx/README.md) — smoke-tests jetables
