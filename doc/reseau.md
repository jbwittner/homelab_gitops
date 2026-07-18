# Exposition réseau

## Architecture

Cilium implémente **Gateway API**. Un `Gateway` partagé unique : **`shared-gw`**
(ns `gateway`, classe `cilium`), défini dans
[`bleu-kalecgos/infra/gateway-api/manifests/gateway.yaml`](../bleu-kalecgos/infra/gateway-api/manifests/gateway.yaml).

- **LB** : IP `192.168.1.80` allouée par `CiliumLoadBalancerIPPool` (pool `192.168.1.80-84`)
  et annoncée en **L2** — manifestes dans `bleu-kalecgos/infra/cilium/manifests/`.
- **Listeners** HTTPS :443 : `https-public` (`*.wittner.tech`), `https-internal`
  (`*.lan.wittner.tech`), `https-internal-kalecgos` (`*.kalecgos.lan.wittner.tech`).
- **TLS terminé au Gateway** : secrets `wildcard-*-tls` (ns `gateway`), émis par cert-manager
  (Let's Encrypt DNS-01 Cloudflare), référencés en `Terminate` par les listeners.

## Exposer un service

Créer un `HTTPRoute` dans le dossier du composant :

- `parentRefs` → `shared-gw` (ns `gateway`) + `sectionName` du listener adapté ;
- `group`/`kind`/`weight` **explicites** dans le `backendRef` — sinon les defaults CRD injectés
  côté live créent un `OutOfSync` permanent.

## Vérifier

```bash
kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True, adresse LB
kubectl get httproute -A
```
