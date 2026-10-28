# Relais SMTP (Postfix → Brevo)

Un relais par cluster, joignable des pods de son cluster seulement. Aucun port sur le LAN.

| | |
|---|---|
| Adresse (pods) | `smtp-relay.smtp-relay.svc.cluster.local:587`, sans authentification, sans TLS |
| Accepté de | `10.244.0.0/16` (pods du cluster) |
| Expéditeur | `*@wittner.tech` seulement (ex. `homelab@wittner.tech`) |
| Amont | `[smtp-relay.brevo.com]:587`, TLS obligatoire |
| File d'attente | `emptyDir` : perdue si le pod redémarre pendant une panne de Brevo |

| Fichier | Rôle |
|---|---|
| `components/smtp-relay/values.yaml` | chart `mail` (bokysan/docker-postfix), commun aux deux clusters |
| `components/smtp-relay/manifests/brevo.yaml` | `ExternalSecret` : `secret/smtp-relay` (`username`, `password`) → `RELAYHOST_*` |
| `clusters/<nom>/smtp-relay/smtp-relay.app.yaml` | `smtp-relay-malygos`, `smtp-relay-kalecgos` |

## Brevo (une fois)

1. Compte Brevo → **Senders, Domains & Dedicated IPs** → **Domains** → ajouter `wittner.tech`.
2. Cloudflare, zone `wittner.tech` : créer les enregistrements affichés par Brevo (code de vérification, DKIM, DMARC).
   - CNAME DKIM en **DNS only** (nuage gris).
   - Un seul TXT SPF par nom : fusionner avec l'existant s'il y en a un.
3. Brevo → **Authenticate** : domaine vérifié et authentifié.
4. **SMTP & API** → **SMTP** → générer une clé SMTP. Login = l'identifiant affiché (`…@smtp-brevo.com`).

## Identifiants dans OpenBao (une fois)

CLI locale connectée à OpenBao ([openbao](openbao.md)) :

```sh
read -r "USER?Login SMTP Brevo : "
read -rs "PW?Clé SMTP Brevo : "; echo
printf %s "$PW" | bao kv put secret/smtp-relay username="$USER" password=-
unset USER PW
```

ESO relit toutes les heures. Postfix lit les identifiants au démarrage : après un changement, redémarrer les deux relais.

```sh
kubectl --context admin@bleu-malygos -n smtp-relay rollout restart sts/smtp-relay
kubectl --context admin@bleu-kalecgos -n smtp-relay rollout restart sts/smtp-relay
```

Idem après un changement de `config` dans `values.yaml` (ConfigMap lue au démarrage).

## Tester

```sh
kubectl --context admin@bleu-malygos -n smtp-relay exec smtp-relay-0 -c mail -- \
  sh -c 'printf "Subject: test relais malygos\n\nok\n" | sendmail -f homelab@wittner.tech jeanbaptiste.wittner@outlook.com'
kubectl --context admin@bleu-malygos -n smtp-relay logs smtp-relay-0 -c mail --tail 20   # status=sent (250 …)
```

Même chose avec `admin@bleu-kalecgos`.

## Brancher un service

| Paramètre | Valeur |
|---|---|
| Hôte, port | `smtp-relay.smtp-relay.svc.cluster.local`, `587` |
| Authentification | aucune |
| TLS / STARTTLS | désactivé côté client (le relais n'a pas de certificat) |
| From | `<service>@wittner.tech` |
