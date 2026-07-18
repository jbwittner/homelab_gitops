# gateway-api

## Rôle

CRDs **Gateway API** (install upstream standard épinglé) + le `Gateway` partagé **`shared-gw`**
du cluster. Toute exposition passe par un `HTTPRoute` rattaché à `shared-gw`
(cf. [doc/reseau.md](../../../doc/reseau.md)).

## Fichiers

- `gateway-api.app.yaml` — Application (archétype (c), path → `manifests/`)
- `manifests/kustomization.yaml` — install upstream **épinglé ici** + matrice de compat Cilium
- `manifests/namespace.yaml` — ns `gateway`
- `manifests/gateway.yaml` — `shared-gw`, classe `cilium`, listeners HTTPS :443
  (`https-public`, `https-internal`, `https-internal-kalecgos`), TLS `Terminate`,
  secrets `wildcard-*-tls`

## Contraintes

- Dépend de Cilium : la `GatewayClass cilium` est **auto-créée par le contrôleur** — ne pas la
  déclarer.
- `ServerSideApply=true` obligatoire (CRDs trop grosses).
- Version des CRDs couplée à la version de Cilium — bumper ensemble selon la matrice dans
  `manifests/kustomization.yaml`.

## Opérations

- **Exposer un service** : `HTTPRoute` → `shared-gw`, cf. [doc/reseau.md](../../../doc/reseau.md).
- **Vérifier** : `kubectl -n gateway get gateway shared-gw` → `PROGRAMMED=True` + adresse LB.
- **Upgrade** : bumper le tag dans `manifests/kustomization.yaml` selon la matrice Cilium.
