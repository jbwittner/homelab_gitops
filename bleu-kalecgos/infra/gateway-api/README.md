# gateway-api — bleu-kalecgos

## Rôle

CRDs **Gateway API** (install upstream standard épinglé) + le `Gateway` partagé **`shared-gw`**
du cluster. Toute exposition de service passe par un `HTTPRoute` rattaché à `shared-gw`.

## Source & versions

| Quoi | Valeur |
|---|---|
| Manifest upstream | `standard-install.yaml` v1.4.1 — kubernetes-sigs/gateway-api |
| Compat | Cilium 1.19 → v1.4.1 (1.18 → v1.3.0) — bumper avec Cilium |
| Namespace | `gateway` (porté par `manifests/namespace.yaml`) |
| Archétype | (c) kustomize seul |

## Fichiers

- `gateway-api.app.yaml` — Application (path → `manifests/`)
- `manifests/kustomization.yaml` — install upstream épinglé + namespace + gateway
- `manifests/namespace.yaml` — ns `gateway`
- `manifests/gateway.yaml` — `shared-gw`, classe `cilium`, 3 listeners HTTPS :443 :
  `https-public` (`*.wittner.tech`), `https-internal` (`*.lan.wittner.tech`),
  `https-internal-kalecgos` (`*.kalecgos.lan.wittner.tech`) — TLS `Terminate`,
  secrets `wildcard-*-tls`

## Dépendances & sync-wave

Wave **-10** (le plus tôt : CRDs requises par toute HTTPRoute, dont celle d'ArgoCD).
Dépend de : Cilium (la `GatewayClass cilium` est **auto-créée par le contrôleur** — ne pas la
déclarer). Requis par : cert-manager-config (secrets TLS dans ns `gateway`), toute app exposée.
`ServerSideApply=true` obligatoire (CRDs trop grosses).

## Opérations courantes

- **Exposer un service** : créer un `HTTPRoute` avec `parentRefs` → `shared-gw` (ns `gateway`)
  + `sectionName` du listener adapté ; `group/kind/weight` **explicites** dans le backendRef
  (sinon OutOfSync permanent — defaults CRD injectés côté live).
- **Vérifier** : `kubectl -n gateway get gateway shared-gw` → `PROGRAMMED=True`,
  adresse LB `192.168.1.80`.
- **Upgrade** : bumper le tag dans `manifests/kustomization.yaml` selon la matrice Cilium.
