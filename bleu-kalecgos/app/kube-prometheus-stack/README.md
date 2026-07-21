# kube-prometheus-stack

## Rôle

Stack d'observabilité du cluster : Prometheus + Alertmanager + Grafana + prometheus-operator
(CRDs ServiceMonitor/PodMonitor) + node-exporter + kube-state-metrics. Chart Helm officiel
`kube-prometheus-stack` (prometheus-community). Grafana exposé sur
`https://grafana.kalecgos.lan.wittner.tech` via `shared-gw` (listener `https-internal-kalecgos`),
en **SSO Authentik (OIDC)** avec **login local conservé** (break-glass). Prometheus et
Alertmanager restent internes (non exposés).

## Fichiers

- `kube-prometheus-stack.app.yaml` — Application ArgoCD multi-sources : chart Helm + values
  (`$values`) + `manifests/`. `ServerSideApply=true` (CRDs volumineuses).
- `helm-values.yaml` — values : OIDC Grafana (`auth.generic_oauth`), mapping groupe→rôle,
  admin local via `existingSecret`, PVCs (Prometheus/Alertmanager/Grafana), scrapes
  control-plane désactivés (Talos mono-nœud).
- `manifests/namespace.yaml` — namespace `monitoring`.
- `manifests/grafana-httproute.yaml` — HTTPRoute Grafana → `shared-gw`.
- `manifests/grafana-oidc.sealed.yaml` — SealedSecret `client-secret` OIDC (**à créer**, cf. Opérations).
- `manifests/grafana-admin.sealed.yaml` — SealedSecret admin local break-glass (**à créer**).
- `manifests/kustomization.yaml` — assemblage (les 2 SealedSecrets sont commentés jusqu'au scellage).

## Opérations

### SSO — authentik (OIDC)

Login via authentik. Le Provider/Application/groupes côté authentik est géré en **Terraform**
(autre repo). Contrat : `clientID=grafana`, issuer
`https://authentik.wittner.tech/application/o/grafana/`, scopes `openid profile email groups`,
redirect URI `https://grafana.kalecgos.lan.wittner.tech/login/generic_oauth`. Groupes :
`Grafana Admins` → rôle **Admin**, `Grafana Viewers` → rôle **Viewer** ; défaut = Viewer.
Compte local `admin` (secret `grafana-admin`) conservé en break-glass.

### Câblage des secrets (depuis la racine du repo ; `*.secret.yaml` gitignoré)

```bash
# 1. Renseigner les templates locaux :
#    manifests/grafana-oidc.secret.yaml  → client-secret (output terraform)
#    manifests/grafana-admin.secret.yaml → admin-password (openssl rand -base64 30)

# 2. Sceller, puis supprimer les fichiers en clair
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < bleu-kalecgos/app/kube-prometheus-stack/manifests/grafana-oidc.secret.yaml \
  > bleu-kalecgos/app/kube-prometheus-stack/manifests/grafana-oidc.sealed.yaml
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml \
  < bleu-kalecgos/app/kube-prometheus-stack/manifests/grafana-admin.secret.yaml \
  > bleu-kalecgos/app/kube-prometheus-stack/manifests/grafana-admin.sealed.yaml
rm bleu-kalecgos/app/kube-prometheus-stack/manifests/grafana-{oidc,admin}.secret.yaml

# 3. Décommenter les 2 lignes *.sealed.yaml dans manifests/kustomization.yaml, commit + push.
```

Rotation : régénérer côté Terraform (OIDC) / `openssl` (admin), re-renseigner le template,
re-sceller (étape 2).

### Accès Prometheus / Alertmanager (non exposés)

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

### État

`kubectl get pods -n monitoring` ; `kubectl get crd | grep monitoring.coreos.com` ;
`kubectl get pvc -n monitoring`.
