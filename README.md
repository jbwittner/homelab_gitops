# homelab-gitops — multi-cluster (hub : Neltharion)

Dépôt GitOps du homelab, conçu **multi-cluster** (hub/spoke). Un **Argo CD central** (le
*hub*) pilote tous les clusters : les `Application` vivent sur le hub, leurs workloads
atterrissent sur le cluster cible (in-cluster pour le hub, `destination.name: <cluster>`
pour les spokes). Aujourd'hui le seul cluster est **Neltharion** (Talos / Kubernetes 1.36,
ingress **Traefik**), qui fait aussi office de hub.

Organisation **par-cluster et auto-contenue** (pas de tree `components/` partagé) : tout vit
sous `<cluster>/{infra,apps}/`, un dossier **auto-contenu par composant déployé** (sa présence
= le composant tourne sur ce cluster) avec son `<name>.app.yaml`, son `values.yaml` Helm fusionné
et ses ressources annexes (namespace, sealed-secrets, ClusterIssuer). Un 2e cluster = on **copie**
le dossier `<cluster>/` et on l'adapte (duplication assumée pour un layout simple et plat).

Déploiement via un **app-of-apps à 3 niveaux** :

- **Tier 1** — `bootstrap/<cluster>.yaml` (`kubectl apply -f` une fois sur le hub) découvre les
  deux bootstraps de partie via `recurse + include: '*.bootstrap.yaml'`.
- **Tier 2** — `<cluster>/infra/infra.bootstrap.yaml` et `<cluster>/apps/apps.bootstrap.yaml`,
  chacun découvre ses composants via `recurse + include: '*.app.yaml'`.
- **Tier 3** — les `<name>.app.yaml` des composants (dont Argo lui-même, self-management).

Les deux suffixes distincts (`.bootstrap.yaml` / `.app.yaml`) empêchent les niveaux de se
matcher entre eux.

**Source de vérité** : ce dépôt **GitHub**. Boucle de sync : push sur `main` → Argo
détecte le changement → reconcilie le cluster.

## Arborescence

```
bootstrap/
  neltharion.yaml         # TIER 1 — app-of-apps du cluster ; kubectl apply -f UNE fois sur le hub

neltharion/               # = hub ; destination in-cluster
  infra/                  # un dossier AUTO-CONTENU par composant déployé :
                          #   <name>/<name>.app.yaml + values.yaml (Helm) + ressources annexes
    infra.bootstrap.yaml  # TIER 2 — découvre infra/*/*.app.yaml
    argocd/               # self-management (wave -1) + install inliné + overlay hub (UI, secrets)
    sealed-secrets/       # wave 0 (Helm, single-source) + README opérationnel
    traefik/              # wave 0 (Helm + values.yaml + namespace)
    cert-manager/         # wave 1 (Helm + values.yaml + ClusterIssuer + token scellé)
    external-dns/         # wave 1 (Helm + values.yaml + namespace + token scellé)
    local-path-provisioner/ # wave 1 (Kustomize, manifest upstream pinné + patches) — StorageClass par défaut
  apps/
    apps.bootstrap.yaml   # TIER 2 — découvre apps/*/*.app.yaml
    metrics-server/       # wave 2 (Helm, single-source) — metrics Kubernetes (kubelet-insecure-tls pour Talos)
    whoami/               # wave 3 (Kustomize, manifests inlinés) — PVC local-path pour tester le stockage
    monitoring/           # wave 4 (Helm kube-prometheus-stack) — Prometheus, Grafana (IngressRoute/cert), Alertmanager, node-exporter, dashboard volumes
```

## Bootstrap (one-time, impératif)

Le dépôt est privé : Argo le lit via une **deploy key SSH** stockée en SealedSecret
(`neltharion/infra/argocd/argocd-repo.sealed-secret.yaml`), appliquée dès l'étape 1.

> **Étape 0 obligatoire.** La repo-cred est scellée ; il faut le contrôleur sealed-secrets pour la
> déchiffrer, mais celui-ci n'arrive normalement qu'en wave 0 (qui a besoin de la cred pour cloner
> le repo). On installe donc sealed-secrets **à la main d'abord** ; Argo l'adopte ensuite. Détails :
> [`neltharion/infra/argocd/README.md`](neltharion/infra/argocd/README.md).

```bash
# 0. Installer le contrôleur sealed-secrets EN PREMIER (mêmes nom/namespace/version que la wave 0)
helm install sealed-secrets sealed-secrets \
  --repo https://bitnami-labs.github.io/sealed-secrets \
  --version 2.18.6 \
  --namespace sealed-secrets --create-namespace
kubectl wait --for=condition=available --timeout=120s deployment/sealed-secrets -n sealed-secrets

# 1. Installer Argo + credentials repo scellés (server-side obligatoire)
kubectl apply -k neltharion/infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer le tier-1 du cluster — Argo prend le relais (infra + apps bootstraps → composants)
kubectl apply -f bootstrap/neltharion.yaml
```

Après l'étape 4, tout passe par Git.

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — architecture détaillée, sync-waves, pièges du self-management, roadmap.
- [`bootstrap/README.md`](bootstrap/README.md) — procédure de bootstrap.
- [`neltharion/infra/argocd/README.md`](neltharion/infra/argocd/README.md) — bootstrap & self-management Argo, deploy key.
- [`neltharion/infra/sealed-secrets/README.md`](neltharion/infra/sealed-secrets/README.md) — kubeseal, backup/restore de clé.
- [`neltharion/infra/traefik/README.md`](neltharion/infra/traefik/README.md) — ingress hostPort, redirection HTTP→HTTPS, exposer une app.
- [`neltharion/infra/cert-manager/README.md`](neltharion/infra/cert-manager/README.md) — ClusterIssuer & token Cloudflare.
- [`neltharion/infra/external-dns/README.md`](neltharion/infra/external-dns/README.md) — sync DNS Cloudflare.
- [`neltharion/infra/local-path-provisioner/README.md`](neltharion/infra/local-path-provisioner/README.md) — StorageClass par défaut sur le disque data Talos.
- [`neltharion/apps/monitoring/README.md`](neltharion/apps/monitoring/README.md) — kube-prometheus-stack, Grafana (grafana.wittnerlab.com), stockage persistant & monitoring des volumes.
