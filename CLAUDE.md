# homelab_gitops — instructions projet

## Règle GitOps — NON négociable

**Interdit de pousser des données au cluster hors GitOps.**

- Toute ressource (Application, Deployment, Service, Gateway, HTTPRoute, ConfigMap, Secret, cert TLS…)
  doit vivre dans Git et être appliquée par **ArgoCD**, jamais par un `kubectl apply/create` impératif.
- `kubectl` en écriture est réservé au **bootstrap initial d'ArgoCD** (cf. `bleu-kalecgos/infra/argocd/README.md`)
  et au **debug read-only** (`get`, `describe`, `logs`, `diff`). Rien d'autre.
- **Secrets** : jamais de `kubectl create secret` ni de Secret en clair dans Git. Utiliser
  **SealedSecrets** (`bleu-kalecgos/infra/sealed-secrets/`) — chiffrer avec `kubeseal`, committer le
  `SealedSecret`, laisser le contrôleur déchiffrer dans le cluster.
- Une modif = éditer le manifeste, commit, push. ArgoCD (self-heal) converge. Pas de dérive manuelle.

Si un état a été créé impérativement en dépannage (ex. secret self-signed temporaire), il doit être
**remplacé par son équivalent GitOps** (SealedSecret) puis supprimé du cluster.

## Structure

- `bleu-kalecgos/` — cluster (app-of-apps). Tier 1 `cluster.yaml` → `*.bootstrap.yaml` → `*.app.yaml`.
- `bleu-kalecgos/infra/<name>/<name>.app.yaml` — composant infra (découvert par glob `*.app.yaml`).
  ⚠️ Suffixe **exact** `.app.yaml` requis, sinon non découvert.
- `bleu-kalecgos/app/` — applications.
- `archive/` — anciens clusters/composants, hors périmètre actif.

## Exposition réseau

Cilium Gateway API. `Gateway` partagé `shared-gw` (ns `gateway`), classe `cilium`. Exposer un service =
créer un `HTTPRoute` (`parentRef` → `shared-gw`, `sectionName` du listener). LB via
`CiliumLoadBalancerIPPool` + L2 announce. TLS terminé au Gateway (secrets `wildcard-*-tls`, scellés).
