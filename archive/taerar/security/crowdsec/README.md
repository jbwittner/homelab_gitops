# Documentation

Il faut créer le network security_network avant de lancer les conteneurs.

```bash
docker network create security_network
```

Fichier `acquis.yaml`

```yaml
source: docker
container_name:
  - dokploy-traefik
labels:
  type: traefik
```

fichier `config.yaml` se situant dans le dossier `/etc/crowdsec` :

```yaml
common:
  log_media: stdout
  log_level: info
  log_dir: /var/log/
config_paths:
  config_dir: /etc/crowdsec/
  data_dir: /var/lib/crowdsec/data/
  simulation_path: /etc/crowdsec/simulation.yaml
  hub_dir: /etc/crowdsec/hub/
  index_path: /etc/crowdsec/hub/.index.json
  notification_dir: /etc/crowdsec/notifications/
  plugin_dir: /usr/local/lib/crowdsec/plugins/
crowdsec_service:
  acquisition_path: /etc/crowdsec/acquis.yaml
  acquisition_dir: /etc/crowdsec/acquis.d
  parser_routines: 1
plugin_config:
  user: nobody
  group: nobody
cscli:
  output: human
db_config:
  log_level: info
  type: postgres
  user: crowdsec_user
  password: crowd_pass_123
  db_name: crowdsec_db
  host: crowdsec-db
  port: 5432
  flush:
    max_items: 5000
    max_age: 7d
api:
  client:
    insecure_skip_verify: false
    credentials_path: /etc/crowdsec/local_api_credentials.yaml
  server:
    log_level: info
    listen_uri: 0.0.0.0:8080
    profiles_path: /etc/crowdsec/profiles.yaml
    trusted_ips:
      - 127.0.0.1
      - ::1
    online_client:
      credentials_path: /etc/crowdsec/online_api_credentials.yaml
    enable: true
prometheus:
  enabled: true
  level: full
  listen_addr: 0.0.0.0
  listen_port: 6060
```

Variables d'environnement à définir dans un fichier `.env` (non inclus dans le dépôt pour des raisons de sécurité) :

```env
CROWDSEC_DB_USER=crowdsec_user
CROWDSEC_DB_PASSWORD=crowd_pass_123
CROWDSEC_DB_NAME=crowdsec_db
```

# Cheatsheet

🛡️ Cheat Sheet CrowdSec (Docker)
📌 1. Gestion des Décisions (Bans & Débannissements)
C'est ici que tu gères les adresses IP bloquées ou autorisées.

Lister les décisions actives (les IP actuellement bannies) :

```bash
docker exec -it security_crowdsec_engine cscli decisions list
```

Bannir manuellement une IP (ex: pour 24h) :

```bash
docker exec -it security_crowdsec_engine cscli decisions add --ip 1.2.3.4 --duration 24h --reason "Ajout manuel"
```
*   **Bannir manuellement une plage d'IP (ex: un sous-réseau /24) :**

```bash
docker exec -it security_crowdsec_engine cscli decisions add --range 1.2.3.0/24 --duration 4h --reason "Plage suspecte"
```
*   **Débannir une IP spécifique :**

```bash
docker exec -it security_crowdsec_engine cscli decisions delete --ip 1.2.3.4
```
*   **Supprimer TOUTES les décisions actives (Remise à zéro des bans) :**

```bash
docker exec -it security_crowdsec_engine cscli decisions delete --all
```

---

## 🚨 2. Gestion des Alertes

Les alertes contiennent l'historique des attaques détectées par tes scénarios, même si le ban a expiré.

*   **Lister les dernières alertes générées :**
```bash
docker exec -it security_crowdsec_engine cscli alerts list
```
*   **Inspecter une alerte en détail (remplace `<ID>` par l'ID de l'alerte) :**

```bash
docker exec -it security_crowdsec_engine cscli alerts inspect <ID>
```
*   **Supprimer une alerte de la base de données :**
```bash
docker exec -it security_crowdsec_engine cscli alerts delete <ID>
```

---

## 📦 3. Gestion du Hub (Parsers, Scénarios, Collections)

Le Hub te permet d'installer des règles spécifiques pour tes services (Nginx, SSH, Traefik, etc.).

*   **Vérifier l'état de tes installations actuelles :**

```bash
docker exec -it security_crowdsec_engine cscli hub list
```
*   **Mettre à jour la liste des paquets disponibles sur le Hub :**
```bash
docker exec -it security_crowdsec_engine cscli hub update
```
*   **Mettre à jour tes scénarios et parsers déjà installés vers leur dernière version :**

```bash
docker exec -it security_crowdsec_engine cscli hub upgrade
```
*   **Installer une collection (ex: la collection Nginx) :**

```bash
docker exec -it security_crowdsec_engine cscli collections install crowdsecurity/nginx
```
*   **Supprimer une collection inutilisée :**

```bash
docker exec -it security_crowdsec_engine cscli collections remove crowdsecurity/nginx
```

---

## 🧱 4. Gestion des Bouncers (Remédiations)

Les bouncers sont les pare-feux qui appliquent concrètement les blocages décidés par CrowdSec.

*   **Lister les bouncers connectés à ton moteur :**

```bash
docker exec -it security_crowdsec_engine cscli bouncers list
```
*   **Ajouter un nouveau bouncer (génère une clé API) :**

```bash
docker exec -it security_crowdsec_engine cscli bouncers add mon_nouveau_bouncer
```
*   **Supprimer un bouncer :**

```bash
docker exec -it security_crowdsec_engine cscli bouncers delete mon_nouveau_bouncer
```

---

## 📊 5. Métriques & Diagnostics

Utile pour vérifier si CrowdSec "lit" bien tes fichiers de logs et si les scénarios se déclenchent.

*   **Afficher le tableau de bord des métriques (Super pratique pour débugger) :**
```bash
docker exec -it security_crowdsec_engine cscli metrics
```
*   **Suivre les logs du conteneur en temps réel :**
```bash
docker logs -f security_crowdsec_engine
```
*   **Redémarrer le moteur CrowdSec (nécessaire après certaines modifications de config) :**
```bash
docker restart security_crowdsec_engine
```