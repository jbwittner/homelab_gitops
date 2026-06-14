# Forgejo

Forge Git (stack Dokploy / Docker Compose) : `forgejo` + base PostgreSQL `db`.

## Réseaux

| Réseau | Type | Rôle |
|---|---|---|
| `forgejo_net` | bridge interne | `forgejo` ↔ `db` |
| `messaging_net` | **externe** | joindre le relais SMTP Postfix (`messaging_postfix_mail_sender`) |

Le réseau `messaging_net` est partagé avec la stack `messaging/postfix`. Il doit être créé
**une seule fois** sur le host avant de lancer les stacks :

```bash
docker network create messaging_net
```

## Envoi de mails (SMTP via Postfix)

Le bloc `[mailer]` du `compose.yaml` relaie les mails (notifications, reset password, …) via le
relais Postfix de `messaging/postfix` :

- `SMTP_ADDR=messaging_postfix_mail_sender`, `SMTP_PORT=587`, `PROTOCOL=smtp+starttls`.
- Authentification SASL : `MAIL_USER` / `MAIL_PASSWD` (`example.env`). Ce couple doit exister
  dans `SMTP_USER` côté Postfix (`messaging/postfix/example.env`) — par défaut le user dédié
  `forgejo-noreply@wittnerlab.com`.
- `FORCE_TRUST_SERVER_CERT=true` : on se connecte par nom de conteneur alors que le cert
  Let's Encrypt de Postfix a pour CN `postfix.wittnerlab.com` ; la liaison reste chiffrée
  (STARTTLS) mais on accepte ce cert interne.

### Tester l'envoi depuis le conteneur Forgejo

Une fois les deux stacks démarrées (et `messaging_net` créé), l'admin peut déclencher un mail
de test depuis l'UI Forgejo : **Site Administration → Configuration → Test Email**.

## Variables d'environnement

Voir `example.env` (à copier en `.env` et compléter) : credentials PostgreSQL et SMTP.
