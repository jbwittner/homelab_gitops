# Homepage

Page d'accueil du parc : `https://homepage.lan.wittner.tech`, sur kalecgos (pas de l'infra).

| Fichier | Rôle |
|---|---|
| `clusters/bleu-kalecgos/homepage/homepage.app.yaml` | `homepage-kalecgos` : manifestes simples, image officielle `ghcr.io/gethomepage/homepage` |
| `clusters/bleu-kalecgos/homepage/manifests/` | namespace, Deployment (`HOMEPAGE_ALLOWED_HOSTS`, probes TCP), Service, HTTPRoute (Gateway `.85`) |
| `clusters/bleu-kalecgos/homepage/manifests/config/` | config Homepage ([doc](https://gethomepage.dev/configs)), ConfigMap `homepage-config-<hash>` |

- Tuiles : `services.yaml`, liens statiques ; `siteMonitor` = point vert/rouge (requête HTTP depuis le pod).
- Pas d'intégration Kubernetes (`kubernetes.yaml` : `mode: disabled`), Docker ni Proxmox.
- Accès : le wildcard DNS `*.lan` mène à malygos, qui relaie vers la Gateway de kalecgos (`external-services/homepage.yaml`, TLS vérifié avec ISRG Root X1). Malygos arrêté = Homepage injoignable par son nom.

## Modifier

Éditer `manifests/config/*.yaml`, commit : nouvelle ConfigMap (hash), le pod redémarre. Nouveau hostname autorisé : `HOMEPAGE_ALLOWED_HOSTS` dans `deployment.yaml`. Version : tag de l'image dans `deployment.yaml` (Renovate).

## Vérifier

```sh
kubectl --context admin@bleu-kalecgos -n homepage get pods,httproute
curl -sI https://homepage.lan.wittner.tech | head -1      # 200
```

`Host validation failed` : hostname absent de `HOMEPAGE_ALLOWED_HOSTS`.
