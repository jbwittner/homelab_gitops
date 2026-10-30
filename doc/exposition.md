# Exposition (Gateway)

Navigateur → DNS AdGuard (`192.168.1.2`, hors dépôt) : rewrite `*.lan.wittner.tech` → `192.168.1.80` → Gateway de malygos → service. Hostname servi par kalecgos : rewrite exact → `192.168.1.85` (prioritaire sur le wildcard).

| Fichier | Rôle |
|---|---|
| `components/gateway/manifests/gateway.yaml` | Gateway `gateway/lan` (classe `cilium`) : HTTPS 443, `*.lan.wittner.tech`, routes de tous les namespaces |
| `components/gateway/manifests/certificate.yaml` | wildcard `*.lan.wittner.tech`, `letsencrypt-prod` ([certificats](certificats.md)) |
| `clusters/<nom>/gateway/manifests/kustomization.yaml` | IP fixe : malygos `192.168.1.80`, kalecgos `192.168.1.85` |
| `clusters/<nom>/gateway/gateway.app.yaml` | `gateway-<cluster-court>` |

| Hostname | Cluster | Route |
|---|---|---|
| `argocd.lan.wittner.tech` | malygos | `clusters/bleu-malygos/argocd/manifests/httproute.yaml` → `argocd-server:80` |
| `auth.lan.wittner.tech` | malygos | `clusters/bleu-malygos/authelia/manifests/httproute.yaml` → `authelia:9091` ([authelia](authelia.md)) |
| `openbao.lan.wittner.tech` | malygos | values du chart OpenBao (`server.gateway.httpRoute`) → `openbao-active:8200` |
| `homepage.lan.wittner.tech` | kalecgos, relayé par malygos | malygos : `external-services/manifests/homepage.yaml` → `192.168.1.85:443` ; kalecgos : `homepage/manifests/httproute.yaml` → `homepage:3000` ([homepage](homepage.md)) |
| `bankwiz-dev.lan.wittner.tech` | kalecgos, relayé par malygos | malygos : `external-services/manifests/bankwiz-dev.yaml` → `192.168.1.85:443` ; kalecgos : `bankwiz/dev/manifests/httproute.yaml` → `bankwiz:8080` ([bankwiz](bankwiz.md)) |
| `adguard`, `ha`, `pve-ysera`, `z2m`, `zyxel` `.lan.wittner.tech` | malygos → LAN | `clusters/bleu-malygos/external-services/manifests/` (section suivante) |

## Exposer un service

1. `HTTPRoute` (ou values du chart) : `parentRefs: [{name: lan, namespace: gateway}]`, hostname `<x>.lan.wittner.tech`.
2. malygos : rien d'autre (wildcard DNS). kalecgos : relais sur malygos, une entrée `external-services` vers `192.168.1.85:443` (modèle `homepage.yaml`) ; ou un rewrite AdGuard exact → `192.168.1.85`.

## Service hors cluster (malygos)

Machine du LAN (NAS, Proxmox…) servie par le Gateway de malygos : `clusters/bleu-malygos/external-services/manifests/<nom>.yaml`, ajouté à la `kustomization.yaml` (Application `external-services-malygos`, namespace `external-services`).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <nom>
spec:
  ports:
    - name: http
      port: 80
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: <nom>
  labels:
    kubernetes.io/service-name: <nom>                 # rattache au Service
    endpointslice.kubernetes.io/managed-by: argocd    # pas le contrôleur Kubernetes (il l'effacerait)
addressType: IPv4
ports:
  - name: http                                        # = nom du port du Service
    port: <port de la machine>
endpoints:
  - addresses: [<IP de la machine>]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <nom>
spec:
  parentRefs: [{name: lan, namespace: gateway}]
  hostnames: [<nom>.lan.wittner.tech]
  rules:
    - backendRefs: [{name: <nom>, port: 80}]
```

Backend en HTTPS seulement (Proxmox) : Gateway API n'a pas d'`insecureSkipVerify`. `BackendTLSPolicy` avec la CA du backend (certificat public en `.crt`, `*.pem` est exclu par `.gitignore`) et un `hostname` présent dans son certificat : modèle `pve-ysera.yaml`.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n gateway get gateway,certificate    # PROGRAMMED True, ADDRESS 192.168.1.80 ; READY True
kubectl --context admin@bleu-malygos get httproute -A
dig +short argocd.lan.wittner.tech                  # 192.168.1.80
curl -sI https://argocd.lan.wittner.tech            # server: envoy
```

`404` avec `server: envoy` : aucune HTTPRoute pour ce hostname sur ce Gateway (mauvais cluster ou route absente).
