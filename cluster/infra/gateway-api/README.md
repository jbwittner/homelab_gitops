# gateway-api

## Rôle

CRDs **Gateway API** (install upstream standard, épinglé) + le `Gateway` partagé **`shared-gw`**
du cluster. Toute exposition passe par un `HTTPRoute` rattaché à `shared-gw`
(cf. [doc/reseau.md](../../../doc/reseau.md)). Wave **-10** : c'est le premier composant déployé
par le tier-1.

## Fichiers

- `gateway-api.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/kustomization.yaml` — install upstream **épinglé ici** (source unique de la version)
- `manifests/namespace.yaml` — ns `gateway`
- `manifests/gateway.yaml` — `shared-gw`, classe `cilium`, 3 listeners HTTPS :443
  (`https-public`, `https-internal`, `https-internal-kalecgos`), TLS `Terminate`, secrets
  `wildcard-*-tls`, `allowedRoutes.namespaces.from: All`

## Contraintes

- **La `GatewayClass cilium` est auto-créée par le contrôleur Cilium** — ne pas la déclarer :
  une GatewayClass posée à la main reste `Pending`, Cilium ne réconcilie pas ce qu'il ne possède
  pas.
- `ServerSideApply=true` obligatoire (CRDs trop grosses pour un apply client-side).
- **Version couplée à celle de Cilium** : consulter la table de compatibilité upstream Cilium ↔
  Gateway API avant tout bump, et bumper les deux ensemble si nécessaire. Renovate propose les
  deux indépendamment : la cohérence est une décision humaine.
- À la **première pose** des CRDs, le contrôleur Gateway de Cilium ne les voit qu'après un
  restart de `cilium-operator` (one-shot de bootstrap, cf. runbook).
- Les secrets TLS vivent dans le ns `gateway` : ils sont produits par
  [`cert-manager`](../cert-manager/README.md), pas ici.

## Opérations

- **Exposer un service** : `HTTPRoute` → `shared-gw`, cf. [doc/reseau.md](../../../doc/reseau.md).
- **Vérifier** :
  ```bash
  kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True + adresse LB
  kubectl -n gateway describe gateway shared-gw   # état par listener (ResolvedRefs)
  kubectl get httproute -A
  ```
- **Upgrade** : bumper le tag dans `manifests/kustomization.yaml` selon la matrice Cilium.
