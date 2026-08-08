# bleu-kalecgos

Cluster actif — mono-nœud `vert-eranikus`, piloté par ArgoCD en app-of-apps
(`cluster.yaml` → `*.bootstrap.yaml` → `*.app.yaml`, cf. [doc/conventions.md](../doc/conventions.md)).

Reconstruire le cluster à partir de zéro : [doc/runbook-bootstrap.md](../doc/runbook-bootstrap.md)
(procédure générique) + [doc/clusters/bleu-kalecgos.md](../doc/clusters/bleu-kalecgos.md)
(valeurs de ce cluster : réseau, disque, secrets).

## Infra

Le socle, sans lequel rien d'autre ne tourne. L'ordre de déploiement est porté par les
sync-waves, pas par cette liste.

- [argocd](infra/argocd/README.md) — moteur GitOps, self-managed, SSO authentik
- [cert-manager](infra/cert-manager/README.md) — moteur d'émission TLS
- [cert-manager-config](infra/cert-manager-config/README.md) — ClusterIssuer Let's Encrypt + certificats wildcard
- [cilium](infra/cilium/README.md) — CNI, Gateway API, LoadBalancer L2
- [gateway-api](infra/gateway-api/README.md) — CRDs Gateway API + Gateway partagé `shared-gw`
- [openebs](infra/openebs/README.md) — stockage LVM node-local
- [sealed-secrets](infra/sealed-secrets/README.md) — déchiffrement des SealedSecrets

## App

- [alloy](app/alloy/README.md) — collecte des logs des pods (DaemonSet) vers Loki
- [authentik](app/authentik/README.md) — Identity Provider SSO (OIDC, SAML, LDAP)
- [cnpg](app/cnpg/README.md) — opérateur CloudNativePG (PostgreSQL déclaratif)
- [kube-prometheus-stack](app/kube-prometheus-stack/README.md) — observabilité (Prometheus / Alertmanager / Grafana), Grafana en SSO authentik
- [loki](app/loki/README.md) — stockage et requêtage des logs, datasource Grafana
- [renovate](app/renovate/README.md) — mises à jour de dépendances automatisées (CronJob self-hosted)
- [test-nginx](app/test-nginx/README.md) — smoke-tests jetables (exposition, PVC, base CNPG)

## Fichiers de ce niveau

- `cluster.yaml` — Application **tier-1**, appliquée à la main au bootstrap ; découvre les
  `*.bootstrap.yaml`
- `infra/infra.bootstrap.yaml`, `app/app.bootstrap.yaml` — tier-2, découvrent chacun leurs
  `*.app.yaml`
