# Relais SMTP (Postfix → Resend)

Un relais par cluster, joignable des pods de son cluster seulement. Aucun port sur le LAN.

| | |
|---|---|
| Adresse (pods) | `smtp-relay.smtp-relay.svc.cluster.local:587`, sans authentification, sans TLS (STARTTLS non proposé) |
| Accepté de | `10.244.0.0/16` (pods du cluster) |
| Expéditeur | `*@wittner.tech` seulement (ex. `homelab@wittner.tech`) |
| Amont | `[smtp.resend.com]:587`, TLS obligatoire |
| File d'attente | `emptyDir` : perdue si le pod redémarre pendant une panne de Resend |
| Suivi | **aucun** : suivi des ouvertures et des clics désactivé par défaut chez Resend (par domaine), à laisser ainsi |

Pourquoi pas Brevo (premier choix) : il réécrit tous les liens des mails HTML vers son traceur, sans option pour le couper hors offre Enterprise.

| Fichier | Rôle |
|---|---|
| `components/smtp-relay/values.yaml` | chart `mail` (bokysan/docker-postfix), commun aux deux clusters |
| `components/smtp-relay/manifests/relayhost.yaml` | `ExternalSecret` : `secret/smtp-relay` (`username`, `password`) → `RELAYHOST_*` |
| `clusters/<nom>/smtp-relay/smtp-relay.app.yaml` | `smtp-relay-malygos`, `smtp-relay-kalecgos` |

## Resend (une fois)

1. Compte Resend → **Domains** → **Add Domain** → `wittner.tech`.
2. Cloudflare, zone `wittner.tech` : créer les enregistrements affichés par Resend (DKIM `resend._domainkey`, MX et TXT SPF sur `send`), en **DNS only** (nuage gris).
3. Resend → **Verify DNS Records** : domaine `Verified`.
4. Domaine → **Configuration** : *Click Tracking* et *Open Tracking* désactivés (défaut).
5. **API Keys** → **Create API Key**, permission *Sending access*, domaine `wittner.tech`.

## Identifiants dans OpenBao (une fois)

CLI locale connectée à OpenBao ([openbao](openbao.md)). Login SMTP Resend : `resend` littéralement.

```sh
read -rs "PW?Clé API Resend : "; echo
printf %s "$PW" | bao kv put secret/smtp-relay username=resend password=-
unset PW
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
  sh -c 'printf "Subject: test relais malygos\n\nok\n" | sendmail -f homelab@wittner.tech moi@example.com'   # remplacer le destinataire
kubectl --context admin@bleu-malygos -n smtp-relay logs smtp-relay-0 -c mail --tail 20   # status=sent (250 …)
```

Même chose avec `admin@bleu-kalecgos`.

## Brancher un service

| Paramètre | Valeur |
|---|---|
| Hôte, port | `smtp-relay.smtp-relay.svc.cluster.local`, `587` |
| Authentification | aucune |
| TLS / STARTTLS | désactivé côté client (le relais ne le propose pas) |
| From | `<service>@wittner.tech` |

| Branché | From | Config |
|---|---|---|
| Authelia | `auth@wittner.tech` | `clusters/bleu-malygos/authelia/manifests/config/configuration.yml` (`notifier.smtp`) |
| Alertmanager | `alertmanager@wittner.tech` | `clusters/bleu-malygos/kube-prometheus-stack/manifests/alertmanager-config.yaml`, modèle texte `alertmanager-templates.yaml` |
