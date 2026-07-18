# cert-manager-config — bleu-kalecgos

`ClusterIssuer` Let's Encrypt (DNS-01 Cloudflare) + `Certificate` wildcard. cert-manager remplit les
Secret TLS `wildcard-*-tls` dans le namespace `gateway` (consommés par le `Gateway` Cilium `shared-gw`).

- **Issuer** : `letsencrypt-prod` (ACME prod, DNS-01).
- **Certificats** : `*.wittner.tech`, `*.lan.wittner.tech`, `*.kalecgos.lan.wittner.tech`.
- **Secret token** : `cloudflare-api-token` (ns `cert-manager`, clé `api-token`) — **SealedSecret**, jamais en clair.

## Ajouter le token API Cloudflare (SealedSecret)

> Règle GitOps : aucun secret en clair au cluster ni dans Git. Le token est chiffré par `kubeseal`
> contre le contrôleur sealed-secrets ; seul le `SealedSecret` chiffré est committé.

### Pré-requis

1. **Token API Cloudflare** avec les permissions :
   - `Zone : DNS : Edit`
   - `Zone : Zone : Read`
   - scope : la zone `wittner.tech` (ou toutes les zones).
   Créer sur https://dash.cloudflare.com/profile/api-tokens.
2. Contrôleur **sealed-secrets** en marche (`kubectl get deploy -n sealed-secrets`).
3. `kubeseal` installé (`brew install kubeseal`).

### Sceller

**1.** Créer le Secret en clair — fichier temporaire local `/tmp/cloudflare-api-token.secret.yaml`
(⚠️ **NE JAMAIS committer** ce fichier). Copier-coller, remplacer `<CLOUDFLARE_API_TOKEN>` :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: <CLOUDFLARE_API_TOKEN>
```

**2.** Sceller — **depuis la racine du projet** :

```bash
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=sealed-secrets \
  --format yaml \
  < bleu-kalecgos/infra/cert-manager-config/manifests/cloudflare-api-token.secret.yaml \
  > bleu-kalecgos/infra/cert-manager-config/manifests/cloudflare-api-token.sealed.yaml
```

**3.** Supprimer le fichier en clair :

```bash
rm /tmp/cloudflare-api-token.secret.yaml
```

Le fichier produit (`cloudflare-api-token.sealed.yaml`) :
- `metadata.name: cloudflare-api-token`, `namespace: cert-manager` → matche `apiTokenSecretRef` du ClusterIssuer.
- `spec.encryptedData.api-token` chiffré → déchiffré par le contrôleur en Secret natif.

### Activer

Ajouter le fichier aux resources kustomize, committer, pousser :

```bash
# manifests/kustomization.yaml — décommenter / ajouter :
#   - cloudflare-api-token.sealed.yaml
git add bleu-kalecgos/infra/cert-manager-config/manifests/cloudflare-api-token.sealed.yaml
git commit -m "feat(cert-manager): add sealed Cloudflare API token"
git push
```

ArgoCD sync → controller déchiffre `cloudflare-api-token` → cert-manager résout le DNS-01 →
Let's Encrypt émet les wildcards → `wildcard-*-tls` remplis → `shared-gw` passe `Programmed`.

### Vérifier

```bash
kubectl get sealedsecret,secret -n cert-manager | grep cloudflare-api-token
kubectl get certificate -n gateway
kubectl describe certificate wildcard-kalecgos-lan-tls -n gateway   # events DNS-01 / issuance
kubectl get clusterissuer letsencrypt-prod -o wide
```

> **Rotation** : régénérer le token côté Cloudflare, re-sceller (même commande), commit/push.
> L'ancien Secret est écrasé au prochain sync.
