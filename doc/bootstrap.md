# Bootstrap

Joué à la main, une fois par cluster, dans l'ordre. Ensuite, ArgoCD reprend la main.

Règle : le bootstrap n'applique que ce qui ne dépend de rien d'autre (CRDs, CNI, ArgoCD…). Gateway, certificats, routes : ArgoCD.

1. [Gateway API](bootstrap/01-gateway-api.md)
2. [Cilium](bootstrap/02-cilium.md)
3. [Sealed Secrets](bootstrap/03-sealed-secrets.md) (malygos)
4. ArgoCD — à venir
