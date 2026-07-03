# Postfix (relais SMTP)

Relais SMTP **interne** du host (stack Dokploy / Docker Compose), image `boky/postfix`.
**Non exposé sur l'hôte** : les apps clientes (Forgejo, authentik…) l'atteignent uniquement
via le réseau Docker partagé `messaging_net`, sur `messaging_postfix_mail_sender:587`.

## Services

| Conteneur | Image | Rôle |
|---|---|---|
| `messaging_postfix_certbot` | `certbot/dns-cloudflare` | obtient/renouvelle le cert Let's Encrypt (DNS-01 Cloudflare) puis le copie pour Postfix ; one-shot |
| `messaging_postfix_mail_sender` | `boky/postfix` | relais SMTP + OpenDKIM (STARTTLS, SASL) |

## Réseau

| Réseau | Type | Rôle |
|---|---|---|
| `messaging_net` | **externe** | partagé avec les apps clientes (Forgejo, authentik…) |

À créer une fois sur l'hôte :

```bash
docker network create messaging_net
```

Le conteneur `mail_sender` porte l'**alias réseau** `postfix.wittnerlab.com` (= CN du cert),
pour que les clients qui vérifient le TLS valident le handshake sans `--insecure`.

## Authentification SASL (multi-apps)

Un user SASL **dédié par app cliente**, déclaré dans `SMTP_USER` (format `user:pass`, séparés
par des espaces). Chaque user doit correspondre à la config de l'app :

| User | App cliente |
|---|---|
| `forgejo-noreply@wittnerlab.com` | [`source-control/forgejo`](../../source-control/forgejo/README.md) (`MAIL_USER`/`MAIL_PASSWD`) |
| `authentik-noreply@wittnerlab.com` | [`authentication/authentik`](../../authentication/authentik/README.md) (`MAILER_USER`/`MAILER_PASSWD`) |

## Certificat & DKIM

- **TLS** : certbot obtient le cert via DNS-01 Cloudflare (credentials `files/cloudflare.ini`,
  bind-mount Dokploy « Files/Mounts »), Postfix le consomme en lecture seule.
- **DKIM figée** (`DKIM_AUTOGENERATE=false`) : la clé vient d'un bind-mount
  (`files/wittnerlab.com.txt`) pour ne pas désynchroniser le TXT DNS à chaque redéploiement.

## Variables d'environnement

Copier `example.env` en `.env` (gitignored) et compléter :

| Variable | Rôle |
|---|---|
| `HOSTNAME` | FQDN du relais (= CN du cert, `postfix.wittnerlab.com`) |
| `ALLOWED_SENDER_DOMAINS` | domaines autorisés à émettre |
| `SMTP_USER` | users SASL `user:pass` (un par app cliente) |
| `LETSENCRYPT_EMAIL` | contact ACME |
| `LETSENCRYPT_SERVER` | endpoint ACME (staging par défaut dans l'exemple — basculer en prod) |
