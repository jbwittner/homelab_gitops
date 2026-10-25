# Exposition (Gateway)

Navigateur → proxy LAN `192.168.1.50` (tous les `*.lan.wittner.tech` y résolvent) → Gateway du cluster → service.

| Fichier | Rôle |
|---|---|
| `components/gateway/manifests/gateway.yaml` | Gateway `gateway/lan` (classe `cilium`) : HTTPS 443, `*.lan.wittner.tech`, routes de tous les namespaces |
| `components/gateway/manifests/certificate.yaml` | wildcard `*.lan.wittner.tech`, `letsencrypt-prod` ([certificats](certificats.md)) |
| `clusters/bleu-malygos/gateway/manifests/kustomization.yaml` | IP fixe `192.168.1.80` |
| `clusters/bleu-malygos/gateway/gateway.app.yaml` | `gateway-malygos` |

| Hostname | Cluster | Route |
|---|---|---|
| `argocd.lan.wittner.tech` | malygos | `clusters/bleu-malygos/argocd/manifests/httproute.yaml` → `argocd-server:80` |
| `bao.lan.wittner.tech` | malygos | values du chart OpenBao (`server.gateway.httpRoute`) → `openbao-active:8200` |

## Exposer un service

1. `HTTPRoute` (ou values du chart) : `parentRefs: [{name: lan, namespace: gateway}]`, hostname `<x>.lan.wittner.tech`.
2. Proxy `192.168.1.50` (hors dépôt) : déclarer le hostname, cible `<IP du Gateway>:443`, SNI et Host conservés.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n gateway get gateway,certificate    # PROGRAMMED True, ADDRESS 192.168.1.80 ; READY True
kubectl --context admin@bleu-malygos get httproute -A
curl -sI --resolve argocd.lan.wittner.tech:443:192.168.1.80 https://argocd.lan.wittner.tech   # direct Gateway
curl -sI https://argocd.lan.wittner.tech                                                       # via proxy
```

Direct OK mais via proxy `404` : hostname absent du proxy.
