# Certificats (cert-manager)

| Fichier | Rôle |
|---|---|
| `components/cert-manager/values.yaml` | CRDs par le chart (gardées à la désinstallation) ; DNS-01 vérifié sur 1.1.1.1 |
| `components/cert-manager/manifests/cloudflare-token.yaml` | `ExternalSecret` : jeton Cloudflare depuis `secret/cert-manager/cloudflare` |
| `components/cert-manager/manifests/clusterissuer-*.yaml` | `letsencrypt-staging`, `letsencrypt-prod` : ACME DNS-01 Cloudflare, zone `wittner.tech` |
| `clusters/<nom>/cert-manager/cert-manager.app.yaml` | `cert-manager-<cluster-court>` |

## Jeton Cloudflare (une fois)

Cloudflare → My Profile → API Tokens → Create Token → modèle « Edit zone DNS » :

| Champ | Valeur |
|---|---|
| Permissions | Zone · DNS · Edit |
| Zone Resources | Include · Specific zone · `wittner.tech` |

Écrire dans OpenBao sans afficher le jeton (CLI locale connectée à OpenBao) :

```sh
read -rs "CF?Jeton Cloudflare : "; echo
printf %s "$CF" | bao kv put secret/cert-manager/cloudflare api-token=-
unset CF
```

Rotation : nouveau jeton, même commande, supprimer l'ancien dans Cloudflare. ESO relit toutes les heures.

## Vérifier

```sh
kubectl --context admin@bleu-malygos -n cert-manager get externalsecret   # SecretSynced
kubectl --context admin@bleu-malygos get clusterissuer                    # READY True
```

Certificat jetable (staging, DNS-01 réel) :

```sh
kubectl --context admin@bleu-malygos create -f - <<'YAML'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: cm-test, namespace: default}
spec:
  secretName: cm-test
  dnsNames: [cm-test.lan.wittner.tech]
  issuerRef: {kind: ClusterIssuer, name: letsencrypt-staging}
YAML
kubectl --context admin@bleu-malygos -n default get certificate cm-test -w   # READY True (1-2 min)
kubectl --context admin@bleu-malygos -n default delete certificate,secret cm-test
```

Bloqué : `kubectl --context admin@bleu-malygos -n default describe challenge`.
