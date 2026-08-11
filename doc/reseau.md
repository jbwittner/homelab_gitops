# Exposition réseau

## Architecture

Cilium implémente **Gateway API**. Le `Gateway` partagé unique est **`shared-gw`** (ns `gateway`,
classe `cilium`), défini dans
[`cluster/infra/gateway-api/manifests/gateway.yaml`](../cluster/infra/gateway-api/manifests/gateway.yaml).
Exposer un service = un `HTTPRoute` qui s'y attache.

- **LB** : **une IP par cluster**, allouée par le `CiliumLoadBalancerIPPool` propre au cluster et
  annoncée en **L2** — manifestes dans `cluster/infra/cilium/<cluster>/manifests/`. Les plages des
  clusters sont **disjointes** ; valeurs dans [les fiches cluster](clusters/).
- **TLS terminé au Gateway** : secrets `wildcard-*-tls` (ns `gateway`), émis par cert-manager
  (Let's Encrypt DNS-01 Cloudflare), référencés en `Terminate` par les listeners. Les backends
  sont joints en HTTP clair.
- La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer.

> [!IMPORTANT]
> **`gateway-api` est aujourd'hui un composant mono-cluster** : c'est une `Application`
> (`destination.name: bleu-kalecgos`), donc `shared-gw` n'existe que sur le hub. Exposer un
> service depuis un second cluster suppose d'abord de **migrer `gateway-api` en `ApplicationSet`**
> (cf. [conventions.md](conventions.md)) : un `<cluster>/manifests/` par cluster, avec son propre
> `Gateway` et ses listeners. Tant que ce n'est pas fait, un `HTTPRoute` posé sur un spoke ne
> trouve aucun parent.

## Listeners (HTTPS :443)

Les trois listeners actuels de `shared-gw`, tous en `allowedRoutes.namespaces.from: All` :

| `sectionName` | Hostname | Secret TLS | Usage |
|---|---|---|---|
| `https-public` | `*.wittner.tech` | `wildcard-public-tls` | services exposés publiquement |
| `https-internal` | `*.lan.wittner.tech` | `wildcard-lan-tls` | services internes, non spécifiques à un cluster |
| `https-internal-kalecgos` | `*.kalecgos.lan.wittner.tech` | `wildcard-kalecgos-lan-tls` | services internes propres à `bleu-kalecgos` |

Le troisième suit le motif `https-internal-<cluster>` / `*.<cluster>.lan.wittner.tech` : un
cluster qui expose ses propres services ajoute son listener, son `Certificate` (dans
[`cert-manager-config`](../cluster/infra/cert-manager-config/README.md)) et son entrée DNS. Les
valeurs exactes de chaque cluster sont dans [sa fiche](clusters/).

⚠️ Un wildcard ne couvre qu'**un** niveau. La règle vaut pour le certificat, le listener **et**
l'enregistrement DNS : `a.kalecgos.lan.wittner.tech` est couvert, `a.b.kalecgos.lan.wittner.tech`
ne l'est pas.

## Exposé aujourd'hui

`bleu-kalecgos` est le seul cluster qui expose quoi que ce soit.

| Hostname | Listener | Composant |
|---|---|---|
| `argocd.lan.wittner.tech` | `https-internal-kalecgos` | [argocd](../cluster/infra/argocd/README.md) |
| `grafana.lan.wittner.tech` | `https-internal-kalecgos` | [kube-prometheus-stack](../cluster/app/kube-prometheus-stack/README.md) |
| `openbao.lan.wittner.tech` | `https-internal` | [openbao](../cluster/infra/openbao/README.md) |
| `authentik.wittner.tech` | `https-public` | [authentik](../cluster/app/authentik/README.md) |

Non exposés volontairement : Prometheus, Alertmanager (port-forward), Loki (API sans
authentification, jointe uniquement en intra-cluster).

## DNS

Le résolveur du réseau doit renvoyer le wildcard interne de chaque cluster vers l'IP du LB **de
ce cluster** (kalecgos : `*.kalecgos.lan.wittner.tech → 192.168.1.80` ; cf.
[les fiches](clusters/)).

Le wildcard **non spécifique à un cluster** `*.lan.wittner.tech` (listener `https-internal`) doit
lui aussi être résolu. Il n'appartient à aucun cluster par construction, mais `shared-gw`
n'existant que sur le hub, il pointe aujourd'hui vers `192.168.1.80` comme les autres. Son
premier utilisateur est [openbao](../cluster/infra/openbao/README.md) : si le résolveur porte des
entrées nominatives plutôt qu'un vrai wildcard, `openbao.lan.wittner.tech` est à créer à la main.

Les zones `*.lan` ne sont jamais publiées chez
Cloudflare : seul le TXT `_acme-challenge` du DNS-01 y transite, ce qui suffit à émettre un
certificat Let's Encrypt pour un nom qui n'est pas joignable depuis Internet.

## Exposer un service

Créer un `HTTPRoute` dans le `manifests/` du composant :

- `parentRefs` → `shared-gw` (ns `gateway`) + `sectionName` du listener adapté ;
- `group`/`kind`/`weight` **explicites** dans le `backendRef`, et le `matches` explicite dans la
  règle — sinon les defaults injectés par le CRD côté live créent un `OutOfSync` permanent ;
- backend en **HTTP clair** (le TLS est terminé au Gateway).

Modèle de référence :
[`argocd-httproute.yaml`](../cluster/infra/argocd/manifests/argocd-httproute.yaml).

## Vérifier

```bash
kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True, adresse LB
kubectl -n gateway get certificate           # les 3 wildcards READY=True
kubectl get httproute -A                     # Accepted / ResolvedRefs
```

Un listener en `ResolvedRefs=False` = son secret TLS manque (certificat pas encore émis).
Le header de réponse `server: envoy` confirme que le trafic passe bien par le proxy Cilium.
