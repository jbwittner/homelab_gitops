# Exposition réseau

## Architecture

Cilium implémente **Gateway API**. Un `Gateway` partagé unique : **`shared-gw`**
(ns `gateway`, classe `cilium`), défini dans
[`bleu-kalecgos/infra/gateway-api/manifests/gateway.yaml`](../bleu-kalecgos/infra/gateway-api/manifests/gateway.yaml).

- **LB** : IP `192.168.1.80` allouée par `CiliumLoadBalancerIPPool` (pool `192.168.1.80-84`)
  et annoncée en **L2** — manifestes dans `bleu-kalecgos/infra/cilium/manifests/`.
- **TLS terminé au Gateway** : secrets `wildcard-*-tls` (ns `gateway`), émis par cert-manager
  (Let's Encrypt DNS-01 Cloudflare), référencés en `Terminate` par les listeners. Les backends
  sont joints en HTTP clair.
- La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer.

## Listeners (HTTPS :443)

| `sectionName` | Hostname | Secret TLS | Usage |
|---|---|---|---|
| `https-public` | `*.wittner.tech` | `wildcard-public-tls` | services exposés publiquement |
| `https-internal` | `*.lan.wittner.tech` | `wildcard-lan-tls` | services internes, tous clusters |
| `https-internal-kalecgos` | `*.kalecgos.lan.wittner.tech` | `wildcard-kalecgos-lan-tls` | services internes propres à ce cluster |

⚠️ Un wildcard ne couvre qu'**un** niveau. La règle vaut pour le certificat, le listener **et**
l'enregistrement DNS : `a.kalecgos.lan.wittner.tech` est couvert, `a.b.kalecgos.lan.wittner.tech`
ne l'est pas.

## Exposé aujourd'hui

| Hostname | Listener | Composant |
|---|---|---|
| `argocd.kalecgos.lan.wittner.tech` | `https-internal-kalecgos` | [argocd](../bleu-kalecgos/infra/argocd/README.md) |
| `grafana.kalecgos.lan.wittner.tech` | `https-internal-kalecgos` | [kube-prometheus-stack](../bleu-kalecgos/app/kube-prometheus-stack/README.md) |
| `authentik.wittner.tech` | `https-public` | [authentik](../bleu-kalecgos/app/authentik/README.md) |

Non exposés volontairement : Prometheus, Alertmanager (port-forward), Loki (API sans
authentification, jointe uniquement en intra-cluster).

## DNS

Le résolveur du réseau doit renvoyer les wildcards internes vers l'IP du LB
(`*.kalecgos.lan.wittner.tech → 192.168.1.80`). Les zones `*.lan` ne sont jamais publiées chez
Cloudflare : seul le TXT `_acme-challenge` du DNS-01 y transite, ce qui suffit à émettre un
certificat Let's Encrypt pour un nom qui n'est pas joignable depuis Internet.

## Exposer un service

Créer un `HTTPRoute` dans le `manifests/` du composant :

- `parentRefs` → `shared-gw` (ns `gateway`) + `sectionName` du listener adapté ;
- `group`/`kind`/`weight` **explicites** dans le `backendRef`, et le `matches` explicite dans la
  règle — sinon les defaults injectés par le CRD côté live créent un `OutOfSync` permanent ;
- backend en **HTTP clair** (le TLS est terminé au Gateway).

Modèle de référence :
[`argocd-httproute.yaml`](../bleu-kalecgos/infra/argocd/manifests/argocd-httproute.yaml).

## Vérifier

```bash
kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True, adresse LB
kubectl -n gateway get certificate           # les 3 wildcards READY=True
kubectl get httproute -A                     # Accepted / ResolvedRefs
```

Un listener en `ResolvedRefs=False` = son secret TLS manque (certificat pas encore émis).
Le header de réponse `server: envoy` confirme que le trafic passe bien par le proxy Cilium.
