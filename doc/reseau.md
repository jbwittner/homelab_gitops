# Exposition réseau

## Architecture

Cilium implémente **Gateway API**. Le `Gateway` partagé unique est **`shared-gw`** (ns `gateway`,
classe `cilium`), défini dans
[`cluster/infra/gateway-api/manifests/gateway.yaml`](../cluster/infra/gateway-api/manifests/gateway.yaml).
Exposer un service = un `HTTPRoute` qui s'y attache.

- **LB** : une IP allouée par le `CiliumLoadBalancerIPPool` `bleu-kalecgos-pool`
  (`192.168.1.80-89`, [`ip-pool.yaml`](../cluster/infra/cilium/manifests/ip-pool.yaml)) et annoncée
  en **L2** (`bleu-kalecgos-l2`, `loadBalancerIPs: true`). En pratique `shared-gw` prend
  **`192.168.1.80`**.
- **TLS terminé au Gateway** : secrets `wildcard-public-tls` et `wildcard-lan-tls` (ns `gateway`),
  émis par cert-manager (Let's Encrypt DNS-01 Cloudflare,
  [`certificates.yaml`](../cluster/infra/cert-manager/manifests/certificates.yaml)) et référencés en
  `Terminate` par les listeners. Les backends sont joints en **HTTP clair**.
- La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer.

> [!NOTE]
> **Mono-cluster.** `gateway-api` et `cilium` sont des `Application` (destination `bleu-kalecgos`),
> pas des `ApplicationSet` : `shared-gw` n'existe que sur ce cluster. Le préfixe
> `bleu-kalecgos-` des objets Cilium (`namePrefix` du kustomize) est le vestige d'un découpage
> multi-cluster qui n'a jamais eu de second membre — il est conservé parce que le renommer
> obligerait à reprendre les `ignoreDifferences`, pas parce qu'un spoke existe.

## Listeners (HTTPS :443)

Les **deux** listeners de `shared-gw`, tous deux en `allowedRoutes.namespaces.from: All` :

| `sectionName` | Hostname | Secret TLS | Usage |
|---|---|---|---|
| `https-public` | `*.wittner.tech` | `wildcard-public-tls` | services exposés publiquement |
| `https-internal` | `*.lan.wittner.tech` | `wildcard-lan-tls` | services internes (LAN uniquement) |

⚠️ Un wildcard ne couvre qu'**un** niveau. La règle vaut pour le certificat, le listener **et**
l'enregistrement DNS : `grafana.lan.wittner.tech` est couvert, `a.b.lan.wittner.tech` ne l'est pas.

## Exposé aujourd'hui

| Hostname | Listener | Composant |
|---|---|---|
| `forgejo.wittner.tech` | `https-public` | [forgejo](../cluster/app/forgejo/README.md) |
| `argocd.lan.wittner.tech` | `https-internal` | [argocd](../cluster/infra/argocd/README.md) |
| `grafana.lan.wittner.tech` | `https-internal` | [kube-prometheus-stack](../cluster/app/kube-prometheus-stack/README.md) |
| `alertmanager.lan.wittner.tech` | `https-internal` | [kube-prometheus-stack](../cluster/app/kube-prometheus-stack/README.md) |
| `hermes.lan.wittner.tech` | `https-internal` | [hermes](../cluster/app/hermes/README.md) — dashboard (9119) |
| `hermes-api.lan.wittner.tech` | `https-internal` | [hermes](../cluster/app/hermes/README.md) — API (8642) |

**Un seul service est public** : Forgejo, et il ne l'est pas directement — cf. §Chemin d'entrée
public. Non exposés volontairement : Prometheus (port-forward), Loki (API sans authentification,
jointe uniquement en intra-cluster).

## DNS et reverse proxy

> [!IMPORTANT]
> **Tout hostname `*.lan.wittner.tech` doit être déclaré au reverse proxy du LAN
> (`192.168.1.50`).** Ce n'est pas optionnel et ce n'est pas du DNS : un `HTTPRoute` parfaitement
> sain, `Accepted`/`ResolvedRefs=True`, répond **404** tant que le nom n'y figure pas. C'est le
> premier réflexe quand un service fraîchement exposé ne répond pas, avant de suspecter le Gateway.

Le résolveur du réseau doit renvoyer `*.lan.wittner.tech` vers l'IP du LB, `192.168.1.80`. Si le
résolveur porte des entrées nominatives plutôt qu'un vrai wildcard, chaque nouveau nom est à créer
à la main.

Les zones `*.lan` ne sont **jamais** publiées chez Cloudflare : seul le TXT `_acme-challenge` du
DNS-01 y transite, ce qui suffit à émettre un certificat Let's Encrypt pour un nom qui n'est pas
joignable depuis Internet.

## Chemin d'entrée public

`forgejo.wittner.tech` n'est pas joint directement : le trafic passe par un **tunnel Cloudflare**
puis un routeur Traefik, hors de ce dépôt. Ces couplages ne sont vérifiables par aucun manifeste
d'ici — cf. [forgejo](../cluster/app/forgejo/README.md) §Points de couplage hors dépôt.

## Exposer un service

Créer un `HTTPRoute` dans le `manifests/` du composant :

- `parentRefs` → `shared-gw` (ns `gateway`) + `sectionName` du listener adapté ;
- `group`/`kind`/`weight` et le `matches` **explicites** — plus obligatoires depuis que le
  server-side diff est actif (`controller.diff.server.side` dans
  [argocd](../cluster/infra/argocd/README.md), qui absorbe les defaults injectés par le CRD),
  mais gardés dans le modèle : ils documentent ce qui est réellement appliqué ;
- backend en **HTTP clair** (le TLS est terminé au Gateway) ;
- puis, pour un nom en `.lan`, **le déclarer au reverse proxy `192.168.1.50`**.

Modèle de référence :
[`grafana-httproute.yaml`](../cluster/app/kube-prometheus-stack/manifests/grafana-httproute.yaml).

## Vérifier

```bash
kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True, adresse 192.168.1.80
kubectl -n gateway get certificate           # les 2 wildcards READY=True
kubectl get httproute -A                     # Accepted / ResolvedRefs
```

Un listener en `ResolvedRefs=False` = son secret TLS manque (certificat pas encore émis).
Le header de réponse `server: envoy` confirme que le trafic passe bien par le proxy Cilium.
Un **404** malgré tout ce qui précède au vert = le nom manque au reverse proxy.
