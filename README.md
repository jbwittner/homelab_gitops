# homelab-gitops — multi-cluster (hub : Neltharion)

Dépôt GitOps du homelab, conçu **multi-cluster** (hub/spoke). Un **Argo CD central** (le
*hub*) pilote tous les clusters : les `Application` vivent sur le hub, leurs workloads
atterrissent sur le cluster cible (in-cluster pour le hub, `destination.name: <cluster>`
pour les spokes). Aujourd'hui le seul cluster est **Neltharion** (Talos / Kubernetes 1.36,
ingress **Traefik**), qui fait aussi office de hub.

Deux axes :

- **`components/{infra,apps}/<name>/`** — bases **partagées** agnostiques du cluster (values
  Helm communes, bases Kustomize).
- **`clusters/<cluster>/{infra,apps}/`** — couche **par-cluster** : une `Application`
  `<name>.app.yaml` par composant déployé (sa présence = le composant tourne sur ce cluster)
  + les surcharges spécifiques (values, namespaces, sealed-secrets, patches Kustomize).

Un app-of-apps **par cluster** (`bootstrap/root-<cluster>.yaml`), appliqué une fois sur le
hub, découvre les `Application` du cluster via `recurse + include: '*.app.yaml'` — y compris
la config d'Argo lui-même (self-management).

**Source de vérité** : ce dépôt **GitHub**. Boucle de sync : push sur `main` → Argo
détecte le changement → reconcilie le cluster.

## Arborescence

```
bootstrap/
  root-neltharion.yaml    # app-of-apps du cluster neltharion — kubectl apply -f UNE fois sur le hub

components/               # bases PARTAGÉES, agnostiques du cluster (miroir infra/apps)
  infra/
    traefik/values-common.yaml
    cert-manager/values-common.yaml
    external-dns/values-common.yaml
    argocd/base/                      # bundle Argo partagé (install pinné + patch cmd-params)
    sealed-secrets/                   # doc opérationnelle (contrôleur déployé via Helm)
  apps/
    whoami/base/                      # base Kustomize (Deployment, Service, Certificate, IngressRoute)

clusters/
  neltharion/             # = hub ; destination in-cluster
    infra/                # un dossier AUTO-CONTENU par composant déployé :
                          #   <name>/<name>.app.yaml + values/values.yaml (override Helm)
                          #   + ressources annexes (namespace, sealed-secrets, kustomization)
      argocd/             # self-management (wave -1) + overlay hub (UI, secrets scellés)
      sealed-secrets/     # wave 0 (Helm, single-source, sans override)
      traefik/            # wave 0 (Helm + values/ + namespace)
      cert-manager/       # wave 1 (Helm + values/ + ClusterIssuer + token scellé)
      external-dns/       # wave 1 (Helm + values/ + namespace + token scellé)
    apps/
      whoami/             # wave 3 (overlay Kustomize → components/apps/whoami/base)
```

## Bootstrap (one-time, impératif)

Le dépôt est privé : Argo le lit via une **deploy key SSH** stockée en SealedSecret
(`clusters/neltharion/infra/argocd/argocd-repo.sealed-secret.yaml`), appliquée dès l'étape 1.

> **Étape 0 obligatoire.** La repo-cred est scellée ; il faut le contrôleur sealed-secrets pour la
> déchiffrer, mais celui-ci n'arrive normalement qu'en wave 0 (qui a besoin de la cred pour cloner
> le repo). On installe donc sealed-secrets **à la main d'abord** ; Argo l'adopte ensuite. Détails :
> [`clusters/neltharion/infra/argocd/README.md`](clusters/neltharion/infra/argocd/README.md).

```bash
# 0. Installer le contrôleur sealed-secrets EN PREMIER (mêmes nom/namespace/version que la wave 0)
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s deployment/sealed-secrets -n sealed-secrets

# 1. Installer Argo + credentials repo scellés (server-side obligatoire)
kubectl apply -k clusters/neltharion/infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer le root du cluster — Argo prend le relais
kubectl apply -f bootstrap/root-neltharion.yaml
```

Après l'étape 4, tout passe par Git.

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — architecture détaillée, sync-waves, pièges du self-management, roadmap.
- [`bootstrap/README.md`](bootstrap/README.md) — procédure de bootstrap.
- [`clusters/neltharion/infra/argocd/README.md`](clusters/neltharion/infra/argocd/README.md) — bootstrap & self-management Argo, deploy key.
- [`components/infra/sealed-secrets/README.md`](components/infra/sealed-secrets/README.md) — kubeseal, backup/restore de clé.
- [`components/infra/traefik/README.md`](components/infra/traefik/README.md) — ingress hostPort, redirection HTTP→HTTPS, exposer une app.
- [`clusters/neltharion/infra/cert-manager/README.md`](clusters/neltharion/infra/cert-manager/README.md) — ClusterIssuer & token Cloudflare.
- [`clusters/neltharion/infra/external-dns/README.md`](clusters/neltharion/infra/external-dns/README.md) — sync DNS Cloudflare.
