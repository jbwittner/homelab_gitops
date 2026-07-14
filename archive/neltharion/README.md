# neltharion — Kubernetes + Argo CD (hub)

Cluster **Talos / Kubernetes 1.36** (ingress **Traefik**) piloté en **GitOps** par un
**Argo CD central** (le *hub*). Conçu **multi-cluster** (hub/spoke) : les `Application` vivent
toutes sur le hub, leurs workloads atterrissent sur le cluster cible (in-cluster pour le hub,
`destination.name: <cluster>` pour les spokes). Aujourd'hui le seul cluster est **neltharion**,
qui fait aussi office de hub.

**Source de vérité** : ce dépôt **GitHub**. Boucle de sync : push sur `main` → Argo détecte le
changement → reconcilie le cluster.

## Architecture

Organisation **par-cluster et auto-contenue** (pas de tree `components/` partagé) : tout vit
sous `neltharion/{infra,apps}/`, un dossier **auto-contenu par composant déployé** (sa présence
= le composant tourne sur ce cluster) avec son `<name>.app.yaml`, son `values.yaml` Helm fusionné
et ses ressources annexes (namespace, sealed-secrets, ClusterIssuer). Un 2ᵉ cluster = on **copie**
le dossier `<cluster>/` et on l'adapte (duplication assumée pour un layout simple et plat).

Déploiement via un **app-of-apps à 3 niveaux** :

- **Tier 1** — `neltharion/neltharion.yaml` (`kubectl apply -f` une fois sur le hub) découvre les
  deux bootstraps de partie via `directory.recurse + include: '*.bootstrap.yaml'`.
- **Tier 2** — `neltharion/infra/infra.bootstrap.yaml` et `neltharion/apps/apps.bootstrap.yaml`,
  chacun découvre ses composants via `recurse + include: '*.app.yaml'`.
- **Tier 3** — les `<name>.app.yaml` des composants (dont Argo lui-même, self-management).

Les deux suffixes distincts (`.bootstrap.yaml` / `.app.yaml`) empêchent les niveaux de se
matcher entre eux : le glob est testé sur le chemin relatif complet (`*` traverse `/`), donc
`*.bootstrap.yaml` au tier 1 ne capte que les deux part-bootstraps et `*.app.yaml` au tier 2 ne
capte que les composants (values, kustomizations, sealed-secrets restent hors des deux).

Les composants Helm utilisent une `Application` **multi-source native** : la source chart charge
un `valueFiles` local (`$src/neltharion/<infra|apps>/<name>/values.yaml`) et une 2ᵉ source git
(`ref: src`) rend les ressources annexes (namespace, sealed-secrets) que le chart ne produit pas.
Le single-source est utilisé là où il n'y a rien en plus (sealed-secrets, apps Kustomize).

> **SealedSecrets par-cluster.** Un SealedSecret est chiffré contre la clé du contrôleur d'un
> cluster donné ; chaque cluster fait donc tourner son propre `sealed-secrets` et garde ses
> secrets re-scellés sous `<cluster>/`.

## Arborescence

```
neltharion/               # = hub ; destination in-cluster (https://kubernetes.default.svc)
  neltharion.yaml         # TIER 1 — app-of-apps du cluster ; kubectl apply -f UNE fois sur le hub
  infra/                  # un dossier AUTO-CONTENU par composant déployé :
                          #   <name>/<name>.app.yaml + values.yaml (Helm) + ressources annexes
    infra.bootstrap.yaml  # TIER 2 — découvre infra/*/*.app.yaml
    argocd/               # self-management (wave -1) + install inliné + overlay hub (UI, secrets)
    sealed-secrets/       # wave 0 (Helm, single-source) + README opérationnel
    traefik/              # wave 0 (Helm + values.yaml + namespace)
    cert-manager/         # wave 1 (Helm + values.yaml + ClusterIssuers prod+staging + token scellé)
    external-dns/         # wave 1 (Helm + values.yaml + namespace + token scellé)
    local-path-provisioner/ # wave 1 (Kustomize, manifest upstream pinné + patches) — StorageClass par défaut
  apps/
    apps.bootstrap.yaml   # TIER 2 — découvre apps/*/*.app.yaml
    metrics-server/       # wave 2 (Helm, single-source) — metrics K8s (kubelet-insecure-tls pour Talos)
    cnpg/                 # wave 2 (Helm, single-source) — opérateur CloudNativePG
    forgejo/              # wave 3 (Kustomize, manifests bruts) — forge Git + registry, CNPG Cluster, PVC 50Gi, SSH 2222
    whoami/               # wave 3 (Kustomize, manifests inlinés) — PVC local-path (test stockage)
    monitoring/           # wave 4 (Helm kube-prometheus-stack) — Prometheus, Grafana, Alertmanager, node-exporter
    renovate/             # wave 5 (Kustomize) — Renovate self-hosted (CLI), 1 CronJob (GitHub)
  examples/               # pédagogique only — exemples de manifestes (secret/sealed-secret) ; rien n'est déployé d'ici
```

Chaque composant est un dossier auto-contenu : `<name>.app.yaml` porte le boilerplate (repoURL,
syncPolicy, destination), `values.yaml` (à la racine du dossier) les values Helm fusionnées, et
les autres fichiers les ressources Kustomize annexes. `<name>.app.yaml` et `values.yaml` sont
ignorés à la fois par le glob tier-2 (`*.app.yaml`) et par le `kustomization.yaml` du dossier
(qui liste ses ressources explicitement). Les placeholders plaintext `*.secret.yaml` (gitignored,
pour régénérer via kubeseal) vivent à côté de leurs `*.sealed-secret.yaml`.

## Sync-wave (déployé)

| Wave | Composants |
|------|-----------|
| -1   | argocd (self-management) |
| 0    | sealed-secrets, traefik |
| 1    | cert-manager (+ ClusterIssuer), external-dns, local-path-provisioner (StorageClass par défaut) |
| 2    | metrics-server, cnpg (opérateur) |
| 3    | forgejo (forge Git + registry — CNPG Cluster, PVC 50Gi, SSH via entrypoint Traefik TCP 2222) |
| 3    | whoami (app de test) |
| 4    | monitoring (kube-prometheus-stack : Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics) |
| 5    | renovate (Renovate self-hosted CLI en CronJob nocturne — PRs de mise à jour) |

## Roadmap (pas encore dans le repo)

| Wave | Composants |
|------|-----------|
| 3    | authentik (SSO/OIDC — **archivé** sous [`archive/neltharion/authentik/`](../archive/neltharion/authentik/README.md) ; re-sceller les secrets avant sync) |
| 4    | postfix |

## Bootstrap (one-time, impératif)

Le dépôt est **public** sur GitHub : Argo le clone en HTTPS anonyme, sans credential. Aucun
SealedSecret n'est donc requis pour démarrer — **Argo s'installe en premier**, puis déploie tout
le reste (sealed-secrets inclus, en wave 0). Plus de dépendance circulaire à briser à la main :
l'ordre est simplement Argo, puis le tier-1. Détails : [`infra/argocd/README.md`](infra/argocd/README.md).

```bash
# 1. Installer Argo (server-side obligatoire — annotations CRD trop grosses pour le client-side)
kubectl apply -k neltharion/infra/argocd --server-side --force-conflicts

# 2. Attendre qu'Argo soit prêt
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# 4. Appliquer le tier-1 du cluster — Argo prend le relais (infra + apps bootstraps → composants,
#    dont sealed-secrets en wave 0)
kubectl apply -f neltharion/neltharion.yaml
```

Après l'étape 4, tout passe par Git.

### Onboarding d'un cluster spoke

1. Enregistrer le spoke comme **cluster secret** Argo sur le hub (scellé), nommé `<cluster>`.
2. **Copier** tout le dossier `neltharion/` vers `<cluster>/`, adapter chaque `<name>.app.yaml`
   (`destination.name: <cluster>`), les deux `*.bootstrap.yaml` (nom + `path`), les `values.yaml`,
   et **re-sceller** chaque secret contre la clé du contrôleur du spoke.
   > ⚠️ Les noms d'Application sont **globaux** dans le namespace `argocd` du hub. `neltharion`,
   > `neltharion-infra`, `neltharion-apps` sont préfixés par cluster, mais pas les noms de
   > composants (`argocd`, `traefik`, …) — en copiant, les préfixer par le cluster (ou s'appuyer
   > sur `destination.name`) pour éviter les collisions.
3. `cp neltharion/neltharion.yaml <cluster>/<cluster>.yaml`, adapter nom + `path`, puis
   `kubectl apply -f <cluster>/<cluster>.yaml` sur le hub.

## Ajouter une application

1. Créer le dossier `neltharion/<infra|apps>/<name>/` avec `<name>.app.yaml`
   (`argoproj.io/v1alpha1 Application`). Tout le composant vit ici.
2. Helm : `values.yaml` à la racine du dossier + ressources annexes Kustomize (namespace,
   sealed-secrets, issuers) avec un `kustomization.yaml`. Kustomize : manifests dans le dossier,
   listés dans `kustomization.yaml`.
3. Helm : `valueFiles` → fichier local unique (`$src/neltharion/<infra|apps>/<name>/values.yaml`)
   + source `ref: src` dont le `path` est le dossier composant (pour les annexes). Single-source
   suffit s'il n'y a rien en plus.
4. Annoter avec un `sync-wave` cohérent avec la table ci-dessus.
5. Pousser sur `main` ; le bootstrap tier-2 de la partie (`recurse + include: '*.app.yaml'`) le capte.

## Pièges du self-management

- `prune: false` sur l'Application `argocd` — ne jamais changer ; Argo supprimerait ses propres composants.
- `ServerSideApply=true` doit matcher l'apply manuel du bootstrap — sinon `OutOfSync` permanent.
- Après la première sync automatique, repo-server et controller peuvent redémarrer une fois : normal.
- Pour des diffs persistants sur webhooks/CRDs, ajouter un `ignoreDifferences` ciblé.

### Activations Argo prévues

L'UI Argo est déjà exposée via `argocd-ingress-route.yaml` + `argocd-certificate.yaml` (actifs
dans `infra/argocd/kustomization.yaml`). Reste sur la roadmap : patches SSO Authentik
(`argocd-cm`, `argocd-rbac-cm`) à ajouter une fois Authentik (re)déployé. Le repo étant public,
Argo le clone sans credential — aucun SealedSecret repo/webhook n'est requis au bootstrap.

## Compat K8s 1.36

Le cluster tourne en Kubernetes 1.36 (bleeding-edge). `infra/argocd/kustomization.yaml` pinne le
manifest d'install upstream via un tag versionné (actuellement `v3.4.3`). Si les pods Argo
crash-loop avec des erreurs d'API après une montée de version, bumper vers le dernier patch
stable d'Argo — mettre à jour le tag là.

## Commandes utiles

> **La CLI `argocd` n'est pas installée.** Utiliser uniquement `kubectl`.

```bash
# Statut des applications
kubectl get applications -n argocd

# Sync status / conditions d'une app
kubectl get application monitoring -n argocd -o jsonpath='{.status.conditions}' | jq .
kubectl get application monitoring -n argocd -o jsonpath='{.status.sync.status}'

# Resync manuel (patch du champ operation)
kubectl patch application <name> -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Logs des composants Argo
kubectl logs -n argocd deploy/argocd-repo-server
kubectl logs -n argocd statefulset/argocd-application-controller
```

## README par composant

- [`infra/argocd/`](infra/argocd/README.md) — bootstrap & self-management Argo (repo public, sans credential).
- [`infra/sealed-secrets/`](infra/sealed-secrets/README.md) — kubeseal, backup/restore de clé.
- [`infra/traefik/`](infra/traefik/README.md) — ingress hostPort, redirection HTTP→HTTPS, exposer une app.
- [`infra/cert-manager/`](infra/cert-manager/README.md) — ClusterIssuers Let's Encrypt (prod+staging) & token Cloudflare.
- [`infra/external-dns/`](infra/external-dns/README.md) — sync DNS Cloudflare.
- [`infra/local-path-provisioner/`](infra/local-path-provisioner/README.md) — StorageClass par défaut.
- [`apps/monitoring/`](apps/monitoring/README.md) — kube-prometheus-stack, Grafana, stockage persistant.
- [`apps/forgejo/`](apps/forgejo/README.md) — Forgejo (forge Git + registry), CNPG, secret admin, SSH 2222.
- [`apps/renovate/`](apps/renovate/README.md) — Renovate self-hosted (CLI) en CronJob, PAT GitHub scellé.
