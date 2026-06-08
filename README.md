# homelab-gitops — Neltharion

Dépôt GitOps du homelab **Neltharion** (Talos / Kubernetes 1.36, ingress **Traefik**).

Pattern **app-of-apps** : deux `Application` racines, appliquées manuellement une seule
fois au bootstrap, pointent Argo CD sur `definitions/neltharion/` qui découvre
récursivement toutes les autres `Application` — y compris la config d'Argo lui-même
(self-management).

**Source de vérité** : ce dépôt **GitHub**. Boucle de sync : push sur `main` → Argo
détecte le changement → reconcilie le cluster.

## Arborescence

```
bootstrap/
  root-infra.yaml         # app-of-apps infra — kubectl apply -f UNE fois
  root-apps.yaml          # app-of-apps apps  — kubectl apply -f UNE fois

infra/                    # contenu (Kustomize/Helm values) déployé par Argo
  argocd/                 # bundle Kustomize Argo (bootstrap ET self-management)
  sealed-secrets/         # doc opérationnelle (contrôleur déployé via Helm, cf. definitions)
  traefik/                # namespace + values.yaml de la chart Traefik
  cert-manager-config/    # ClusterIssuer Let's Encrypt + token Cloudflare (scellé)
  external-dns/           # namespace + values.yaml + token Cloudflare (scellé)

definitions/
  neltharion/
    infra/                # une Application Argo par composant d'infra
      argocd.yaml         # self-management (wave -1, prune: false, ServerSideApply)
      sealed-secrets.yaml # wave 0 (Helm)
      traefik.yaml        # wave 0 (Helm + overlay infra/traefik)
      cert-manager.yaml   # wave 1 (Helm + overlay infra/cert-manager-config)
      external-dns.yaml   # wave 1 (Helm + overlay infra/external-dns)
    apps/                 # Applications métier
      whoami.app.yaml     # app de test (wave 3)

apps/
  whoami/                 # manifestes de l'app de test (Deployment, Service, Certificate, IngressRoute)
```

## Bootstrap (one-time, impératif)

Le dépôt est privé : Argo le lit via une **deploy key SSH** stockée en SealedSecret
(`infra/argocd/argocd-repo.sealed-secret.yaml`), appliquée dès l'étape 1.

```bash
# 1. Installer Argo + credentials repo scellés (server-side obligatoire)
kubectl apply -k infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer les deux roots — Argo prend le relais
kubectl apply -f bootstrap/root-infra.yaml -f bootstrap/root-apps.yaml
```

Après l'étape 4, tout passe par Git.

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — architecture détaillée, sync-waves, pièges du self-management, roadmap.
- [`bootstrap/README.md`](bootstrap/README.md) — procédure de bootstrap.
- [`infra/argocd/README.md`](infra/argocd/README.md) — bootstrap & self-management Argo, deploy key.
- [`infra/sealed-secrets/README.md`](infra/sealed-secrets/README.md) — kubeseal, backup/restore de clé.
- [`infra/traefik/README.md`](infra/traefik/README.md) — ingress hostPort, redirection HTTP→HTTPS, exposer une app.
- [`infra/cert-manager-config/README.md`](infra/cert-manager-config/README.md) — ClusterIssuer & token Cloudflare.
- [`infra/external-dns/README.md`](infra/external-dns/README.md) — sync DNS Cloudflare.
