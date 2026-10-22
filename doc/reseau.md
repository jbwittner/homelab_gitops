# Exposition réseau

## Architecture

Cilium implémente **Gateway API**. Le `Gateway` partagé unique est **`shared-gw`** (ns `gateway`,
classe `cilium`), défini dans
[`k8s/infra/gateway-api/manifests/gateway.yaml`](../k8s/infra/gateway-api/manifests/gateway.yaml).
Exposer un service = un `HTTPRoute` qui s'y attache.

- **LB** : une IP allouée par le `CiliumLoadBalancerIPPool` `bleu-kalecgos-pool`
  (`192.168.1.80-89`, [`ip-pool.yaml`](../k8s/infra/cilium/manifests/ip-pool.yaml)) et annoncée
  en **L2** (`bleu-kalecgos-l2`, `loadBalancerIPs: true`). En pratique `shared-gw` prend
  **`192.168.1.80`**.
- **TLS terminé au Gateway** : secrets `wildcard-public-tls`, `wildcard-lan-tls` et `wildcard-dev-lan-tls` (ns `gateway`),
  émis par cert-manager (Let's Encrypt DNS-01 Cloudflare,
  [`certificates.yaml`](../k8s/infra/cert-manager/manifests/certificates.yaml)) et référencés en
  `Terminate` par les listeners. Les backends sont joints en **HTTP clair**.
- La `GatewayClass cilium` est **auto-créée par le contrôleur Cilium** — ne pas la déclarer.

> [!NOTE]
> **Mono-cluster.** `gateway-api` et `cilium` sont des `Application` (destination `bleu-kalecgos`),
> pas des `ApplicationSet` : `shared-gw` n'existe que sur ce cluster. Le préfixe
> `bleu-kalecgos-` des objets Cilium (`namePrefix` du kustomize) est le vestige d'un découpage
> multi-cluster qui n'a jamais eu de second membre — il est conservé parce que le renommer
> obligerait à reprendre les `ignoreDifferences`, pas parce qu'un spoke existe.

## Listeners (HTTPS :443)

Les **trois** listeners de `shared-gw`, tous en `allowedRoutes.namespaces.from: All` :

| `sectionName` | Hostname | Secret TLS | Usage |
|---|---|---|---|
| `https-public` | `*.wittner.tech` | `wildcard-public-tls` | services exposés publiquement |
| `https-internal` | `*.lan.wittner.tech` | `wildcard-lan-tls` | services internes (LAN uniquement) |
| `https-dev` | `*.dev.lan.wittner.tech` | `wildcard-dev-lan-tls` | environnements de dev (LAN uniquement) |

⚠️ Un wildcard ne couvre qu'**un** niveau. La règle vaut pour le certificat **et**
l'enregistrement DNS : `grafana.lan.wittner.tech` est couvert, `a.b.lan.wittner.tech` ne l'est pas.
**Pas pour le listener**, et c'est le piège : un hostname de listener Gateway API `*.lan.wittner.tech`
matche aussi `a.b.lan.wittner.tech` — la route attachée à `https-internal` serait `Accepted`, puis
servie avec un certificat qui ne couvre pas le nom. D'où le listener `https-dev` et son propre
wildcard pour `*.dev.lan.wittner.tech` ; au SNI, le hostname le plus spécifique l'emporte.

## Exposé aujourd'hui

| Hostname | Listener | Composant |
|---|---|---|
| `argocd.lan.wittner.tech` | `https-internal` | [argocd](../k8s/infra/argocd/README.md) |
| `grafana.lan.wittner.tech` | `https-internal` | [kube-prometheus-stack](../k8s/app/kube-prometheus-stack/README.md) |
| `alertmanager.lan.wittner.tech` | `https-internal` | [kube-prometheus-stack](../k8s/app/kube-prometheus-stack/README.md) |
| `hermes.lan.wittner.tech` | `https-internal` | [hermes](../k8s/app/hermes/README.md) — dashboard (9119) |
| `hermes-api.lan.wittner.tech` | `https-internal` | [hermes](../k8s/app/hermes/README.md) — API (8642) |
| `bankwiz-api.dev.lan.wittner.tech` | `https-dev` | [bankwiz](../k8s/app/bankwiz/README.md) — API, environnement `dev` |

⚠️ **`argocd.lan.wittner.tech` n'est pas qu'une UI** : `/api/webhook` y est l'endpoint du webhook
« push » qui déclenche la sync immédiate au lieu du polling de 3 min
([argocd §Webhook](../k8s/infra/argocd/README.md)). ⚠️ Le nom étant en `*.lan`, un webhook
GitHub **ne peut pas** le joindre : GitHub livre depuis Internet, et aucune route publique n'aboutit
dans ce cluster (cf. §Chemin d'entrée public). Tant que rien n'est exposé, le polling est le seul
déclencheur.

⚠️ **Aucun service de ce cluster n'est public depuis le 2026-09-11**, et le listener `https-public`
n'a aucune route. Le listener reste déclaré — le certificat wildcard `*.wittner.tech` est émis et
renouvelé pour lui — mais il ne sert rien.

Non exposés volontairement : Prometheus (port-forward), Loki (API sans authentification, jointe
uniquement en intra-cluster).

**Deux hostnames servis AILLEURS que par ce cluster**, à ne pas chercher dans un `HTTPRoute` :

| Hostname | Servi par | Vu d'ici comme |
|---|---|---|
| `node-exporter-emeriss.lan.wittner.tech` | machine `vert-emeriss`, pile `node-exporter/` de `homelab_emeriss`, via le proxy `192.168.1.50` | cible `job="external-node"` de [hosts-monitoring](../k8s/app/hosts-monitoring/README.md) — la machine |
| `cadvisor-emeriss.lan.wittner.tech` | même machine, pile `cadvisor/` de `homelab_emeriss` | cible cAdvisor de hosts-monitoring — ses conteneurs |

⚠️ Les deux dépendent du reverse proxy et d'aucun objet de ce dépôt. Ils sont en
`*.lan.wittner.tech` : ils tombent donc sous la règle ci-dessous — non déclarés au proxy, ils
répondent **404**, et le symptôme dans le cluster est une cible Prometheus en erreur, pas une
alerte de réseau.

⚠️ **Le nom porte celui de la MACHINE, pas seulement du service**, et c'est délibéré : les piles
d'en face sont duplicables sur un autre hôte, et un nom générique ferait collision au premier second
exportateur — côté proxy, le second écrasant le premier en silence.

⚠️ **La règle Traefik n'existe qu'en un exemplaire**, dans `homelab_ysera/traefik/dynamic/`
(`node-exporter-emeriss.yml`, `cadvisor-emeriss.yml`), monté en lecture seule sur
`/etc/traefik-git` du CT 201. `homelab_emeriss` en gardait des « copies de référence » ; elles ont
été retirées le 2026-09-11 parce qu'elles avaient déjà **divergé dans les deux sens** — un router
servi sans copie, des copies sans router servi. **Constaté ce jour-là** : des cibles Prometheus en
`404` alors que les exportateurs tournaient et que les Secrets étaient bons. Un 404 sur une cible
désigne le reverse proxy, jamais le cluster.

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

⚠️ **Il n'aboutit plus dans ce cluster depuis le 2026-09-11.** Le chemin public — tunnel
Cloudflare puis routeur Traefik (`192.168.1.50`) — ne renvoie plus rien vers `shared-gw`. Ces
couplages ne sont vérifiables par aucun manifeste d'ici.

Conséquence pour ce dépôt : le chemin d'entrée public est **libre**. Exposer un service sur
`https-public` demande donc, en plus de l'`HTTPRoute`, une route côté tunnel et côté proxy — rien
n'en reste de préconfiguré.

## Exposer un service

Créer un `HTTPRoute` dans le `manifests/` du composant :

- `parentRefs` → `shared-gw` (ns `gateway`) + `sectionName` du listener adapté ;
- `group`/`kind`/`weight` et le `matches` **explicites** — plus obligatoires depuis que le
  server-side diff est actif (`controller.diff.server.side` dans
  [argocd](../k8s/infra/argocd/README.md), qui absorbe les defaults injectés par le CRD),
  mais gardés dans le modèle : ils documentent ce qui est réellement appliqué ;
- backend en **HTTP clair** (le TLS est terminé au Gateway) ;
- puis, pour un nom en `.lan`, **le déclarer au reverse proxy `192.168.1.50`**.

Modèle de référence :
[`grafana-httproute.yaml`](../k8s/app/kube-prometheus-stack/manifests/grafana-httproute.yaml).

## Vérifier

```bash
kubectl -n gateway get gateway shared-gw     # PROGRAMMED=True, adresse 192.168.1.80
kubectl -n gateway get certificate           # les 3 wildcards READY=True
kubectl get httproute -A                     # Accepted / ResolvedRefs
```

Un listener en `ResolvedRefs=False` = son secret TLS manque (certificat pas encore émis).
Le header de réponse `server: envoy` confirme que le trafic passe bien par le proxy Cilium.
Un **404** malgré tout ce qui précède au vert = le nom manque au reverse proxy.
