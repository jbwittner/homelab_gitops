# onyxia — Kubernetes + Argo CD (hub autonome)

Cluster piloté en **GitOps** par son **propre Argo CD** (hub **autonome**, indépendant de
neltharion). Même pattern app-of-apps à 3 niveaux et même layout **par-cluster auto-contenu**
que [`neltharion/`](../neltharion/README.md) — se référer à ce README pour la philosophie
détaillée (multi-source Helm, SealedSecrets par-cluster, pièges du self-management).

**Source de vérité** : ce dépôt **GitHub**. Push sur `main` → Argo reconcilie onyxia.

> État actuel : socle ingress + TLS en place (Argo, sealed-secrets, traefik, cert-manager). La
> partie apps est vide et se remplit composant par composant.
>
> ⚠️ **cert-manager n'émet pas encore de certs** : le token Cloudflare doit être scellé contre le
> contrôleur sealed-secrets d'onyxia — voir [`infra/cert-manager/README.md`](infra/cert-manager/README.md).

## Architecture

Organisation **par-cluster et auto-contenue** : tout vit sous `onyxia/{infra,apps}/`, un dossier
auto-contenu par composant déployé (sa présence = le composant tourne sur ce cluster) avec son
`<name>.app.yaml`, son `values.yaml` Helm éventuel et ses ressources annexes.

Déploiement via un **app-of-apps à 3 niveaux** :

- **Tier 1** — `onyxia/onyxia.yaml` (`kubectl apply -f` une fois sur le hub) découvre les deux
  bootstraps de partie via `directory.recurse + include: '*.bootstrap.yaml'`.
- **Tier 2** — `onyxia/infra/infra.bootstrap.yaml` et `onyxia/apps/apps.bootstrap.yaml`, chacun
  découvre ses composants via `recurse + include: '*.app.yaml'`.
- **Tier 3** — les `<name>.app.yaml` des composants (dont Argo lui-même, self-management).

Les deux suffixes distincts (`.bootstrap.yaml` / `.app.yaml`) empêchent les niveaux de se matcher
entre eux.

## Arborescence

```
onyxia/                     # = hub ; destination in-cluster (https://kubernetes.default.svc)
  onyxia.yaml               # TIER 1 — app-of-apps du cluster ; kubectl apply -f UNE fois sur le hub
  infra/
    infra.bootstrap.yaml    # TIER 2 — découvre infra/*/*.app.yaml
    argocd/                 # wave -1 self-management + install inliné (bootstrap ET self-management)
    sealed-secrets/         # wave 0 (Helm, single-source) — contrôleur de déchiffrement + README kubeseal
    traefik/                # wave 0 (Helm + values.yaml + namespace) — ingress hostPort 80/443, redirect HTTP→HTTPS
    cert-manager/           # wave 1 (Helm + values.yaml + ClusterIssuers prod+staging + token Cloudflare à sceller)
  apps/
    apps.bootstrap.yaml     # TIER 2 — découvre apps/*/*.app.yaml (aucun composant pour l'instant)
```

## Sync-wave (déployé)

| Wave | Composants |
|------|-----------|
| -1   | argocd (self-management) |
| 0    | sealed-secrets, traefik |
| 1    | cert-manager (+ ClusterIssuers Let's Encrypt prod+staging — token Cloudflare à sceller) |

## Roadmap (pas encore dans le repo)

À copier/adapter depuis `neltharion/` selon les besoins (external-dns, storage, monitoring, …).
Chaque ajout = un dossier auto-contenu `onyxia/<infra|apps>/<name>/` + push `main`.

> **SealedSecrets par-cluster.** Un SealedSecret est chiffré contre la clé du contrôleur d'un
> cluster donné. Quand `sealed-secrets` sera déployé sur onyxia, re-sceller chaque secret contre
> **sa** clé — ne pas réutiliser les SealedSecrets de neltharion.

## Bootstrap (one-time, impératif)

Le dépôt est **public** : Argo le clone en HTTPS anonyme, sans credential. **Argo s'installe en
premier**, puis déploie le reste. Détails : [`infra/argocd/README.md`](infra/argocd/README.md).

```bash
# 1. Installer Argo (server-side obligatoire — annotations CRD trop grosses pour le client-side)
kubectl apply -k onyxia/infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer le tier-1 du cluster — Argo prend le relais
kubectl apply -f onyxia/onyxia.yaml
```

Après l'étape 4, tout passe par Git.

## Ajouter une application

Même procédure que neltharion (cf. [`neltharion/README.md`](../neltharion/README.md) §« Ajouter une
application ») : créer `onyxia/<infra|apps>/<name>/` avec `<name>.app.yaml`, un `values.yaml` (Helm)
ou des manifests (Kustomize), annoter d'un `sync-wave` cohérent, push `main` ; le bootstrap tier-2
de la partie le capte.

## README par composant

- [`infra/argocd/`](infra/argocd/README.md) — bootstrap & self-management Argo (repo public, sans credential).
- [`infra/sealed-secrets/`](infra/sealed-secrets/README.md) — kubeseal, backup/restore de clé (par-cluster).
- [`infra/traefik/`](infra/traefik/README.md) — ingress hostPort, redirect HTTP→HTTPS, exposer une app.
- [`infra/cert-manager/`](infra/cert-manager/README.md) — ClusterIssuers Let's Encrypt & token Cloudflare (à sceller).
