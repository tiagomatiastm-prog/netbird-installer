# Netbird Server Installer

Installation automatisée d'un serveur Netbird self-hosted complet sur Debian 13.

## Description

Ce projet fournit un script d'installation automatique pour déployer une instance complète de Netbird self-hosted incluant :

- **Management Server** : API de gestion et orchestration
- **Dashboard** : Interface web pour administrer le réseau
- **Signal Server** : Coordination des pairs pour établir les connexions
- **Relay/TURN Server** : Serveur de relais pour traverser les NAT (coturn)
- **PostgreSQL** : Base de données pour stocker la configuration

Netbird est une solution VPN moderne basée sur WireGuard qui permet de créer des réseaux privés sécurisés (mesh VPN) avec une configuration simple.

## Caractéristiques

- Installation 100% automatisée via Docker Compose
- Support des variables d'environnement et arguments CLI
- Configuration par défaut pour tests en local
- Support reverse proxy (Nginx, Caddy, Traefik, HAProxy)
- Génération automatique des secrets et mots de passe
- Service systemd pour gestion automatique
- TURN/STUN server intégré pour traversée NAT
- Pas d'authentification externe requise (self-hosted complet)

## Prérequis

- Debian 13 (Trixie) - testé sur cette version
- Accès root (sudo)
- Connexion internet
- Ports disponibles :
  - 8080/tcp (Management API) - configurable
  - 8081/tcp (Dashboard) - configurable
  - 10000/tcp (Signal Server) - configurable
  - 33073/tcp+udp (TURN/STUN) - configurable
  - 49152-65535/udp (TURN relay range)
- IP publique pour le serveur TURN (si clients derrière NAT)

## Installation rapide

### Installation de test (localhost)

```bash
curl -fsSL https://raw.githubusercontent.com/tiagomatiastm-prog/netbird-installer/master/install-netbird.sh | sudo bash
```

### Installation personnalisée

```bash
# Télécharger le script
curl -fsSL -O https://raw.githubusercontent.com/tiagomatiastm-prog/netbird-installer/master/install-netbird.sh
chmod +x install-netbird.sh

# Installation avec domaine personnalisé
sudo ./install-netbird.sh --domain netbird.example.com --turn-ip 1.2.3.4

# Installation avec ports personnalisés
sudo ./install-netbird.sh --http-port 9000 --dashboard-port 9001 --signal-port 9002
```

## Options du script

```
Usage: ./install-netbird.sh [OPTIONS]

OPTIONS:
    -d, --domain DOMAIN              Domain name for Netbird (default: netbird.local)
    -l, --listen ADDRESS             Listen address (default: 127.0.0.1 for reverse proxy)
    -p, --http-port PORT             HTTP port for Management API (default: 8080)
    --dashboard-port PORT            Dashboard UI port (default: 8081)
    --signal-port PORT               Signal server port (default: 10000)
    --relay-port PORT                Relay/TURN server port (default: 33073)
    --turn-ip IP                     External IP for TURN server (auto-detected if not provided)
    --behind-proxy [true|false]      Running behind reverse proxy (default: true)
    --skip-docker                    Skip Docker installation (use if already installed)
    -h, --help                       Show this help message
```

## Exemples d'utilisation

### Test en local
```bash
sudo ./install-netbird.sh
```
Accès : http://127.0.0.1:8081

### Production avec reverse proxy
```bash
sudo ./install-netbird.sh \
  --domain netbird.mycompany.com \
  --turn-ip 203.0.113.50
```

### Sans reverse proxy (accès direct)
```bash
sudo ./install-netbird.sh \
  --domain netbird.example.com \
  --behind-proxy false \
  --listen 0.0.0.0
```

### Ports personnalisés
```bash
sudo ./install-netbird.sh \
  --http-port 9000 \
  --dashboard-port 9001 \
  --signal-port 9002 \
  --relay-port 33074
```

## Configuration reverse proxy

Si vous utilisez un reverse proxy (recommandé pour la production), vous devez configurer HTTPS car WebRTC requiert une connexion sécurisée.

### Exemple avec Nginx

```nginx
# Management API
location /api {
    proxy_pass http://127.0.0.1:8080/api;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Dashboard
location / {
    proxy_pass http://127.0.0.1:8081;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Signal Server (WebSocket)
location /signalexchange.SignalExchange/ {
    proxy_pass http://127.0.0.1:10000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

### Exemple avec Caddy

```caddy
netbird.example.com {
    # Dashboard
    reverse_proxy 127.0.0.1:8081

    # Management API
    handle /api* {
        reverse_proxy 127.0.0.1:8080
    }

    # Signal Server
    handle /signalexchange.SignalExchange/* {
        reverse_proxy 127.0.0.1:10000
    }
}
```

## Configuration du pare-feu

### UFW (Ubuntu/Debian)
```bash
# Management API
sudo ufw allow 8080/tcp

# Dashboard
sudo ufw allow 8081/tcp

# Signal Server
sudo ufw allow 10000/tcp

# TURN/STUN
sudo ufw allow 33073/tcp
sudo ufw allow 33073/udp
sudo ufw allow 49152:65535/udp
```

### iptables
```bash
# Management API
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

# Dashboard
iptables -A INPUT -p tcp --dport 8081 -j ACCEPT

# Signal Server
iptables -A INPUT -p tcp --dport 10000 -j ACCEPT

# TURN/STUN
iptables -A INPUT -p tcp --dport 33073 -j ACCEPT
iptables -A INPUT -p udp --dport 33073 -j ACCEPT
iptables -A INPUT -p udp --dport 49152:65535 -j ACCEPT
```

## Utilisation

### Première connexion

1. Accédez au Dashboard (http://127.0.0.1:8081 par défaut)
2. Créez votre premier compte administrateur
3. Générez une clé de setup pour vos clients
4. Installez le client Netbird sur vos appareils

### Installation du client Netbird

#### Linux
```bash
# Debian/Ubuntu
curl -fsSL https://pkgs.netbird.io/install.sh | sh

# Connecter le client
netbird up --setup-key YOUR_SETUP_KEY
```

#### Windows
```powershell
# Via winget
winget install netbird

# Via installer
# Téléchargez depuis https://netbird.io/downloads
```

#### macOS
```bash
# Via Homebrew
brew install netbird

# Connecter le client
netbird up --setup-key YOUR_SETUP_KEY
```

#### Android / iOS
- Téléchargez l'app depuis le Play Store ou App Store
- Configurez avec votre URL de serveur et clé de setup

### Gestion du service

```bash
# Démarrer
sudo systemctl start netbird-server

# Arrêter
sudo systemctl stop netbird-server

# Redémarrer
sudo systemctl restart netbird-server

# Statut
sudo systemctl status netbird-server

# Logs de tous les conteneurs
sudo docker compose -f /opt/netbird/docker-compose.yml logs -f

# Logs d'un service spécifique
sudo docker logs netbird-management
sudo docker logs netbird-signal
sudo docker logs netbird-dashboard
sudo docker logs netbird-coturn
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Reverse Proxy (Optional)             │
│                    (Nginx/Caddy/Traefik)                │
│                         HTTPS                           │
└────────────────┬────────────────────────────────────────┘
                 │
    ┌────────────┼────────────┬─────────────┐
    │            │            │             │
┌───▼───┐   ┌───▼──┐   ┌─────▼────┐   ┌────▼─────┐
│ Dash  │   │ API  │   │  Signal  │   │  TURN    │
│ board │   │ Mgmt │   │  Server  │   │  Server  │
│:8081  │   │:8080 │   │  :10000  │   │  :33073  │
└───────┘   └──┬───┘   └──────────┘   └──────────┘
               │
          ┌────▼──────┐
          │ PostgreSQL│
          │   :5432   │
          └───────────┘

           Client Devices
        (Desktop/Mobile/Server)
              │
              └──> WireGuard VPN Mesh Network
```

## Fichiers importants

- `/opt/netbird/` - Répertoire d'installation
- `/opt/netbird/docker-compose.yml` - Configuration Docker Compose
- `/opt/netbird/config/.env` - Variables d'environnement (secrets)
- `/opt/netbird/data/` - Données persistantes
  - `management/` - Données du serveur de management
  - `signal/` - Données du signal server
  - `relay/` - Données du TURN server
  - `postgres/` - Base de données PostgreSQL
- `/root/netbird-info.txt` - Informations de connexion et secrets
- `/etc/systemd/system/netbird-server.service` - Service systemd

## Sauvegarde

### Sauvegarde complète
```bash
# Arrêter les services
sudo systemctl stop netbird-server

# Créer l'archive
sudo tar czf netbird-backup-$(date +%Y%m%d).tar.gz /opt/netbird

# Redémarrer les services
sudo systemctl start netbird-server
```

### Restauration
```bash
# Arrêter les services
sudo systemctl stop netbird-server

# Restaurer l'archive
sudo tar xzf netbird-backup-20250107.tar.gz -C /

# Redémarrer les services
sudo systemctl start netbird-server
```

## Désinstallation

```bash
# Arrêter et désactiver le service
sudo systemctl stop netbird-server
sudo systemctl disable netbird-server

# Supprimer les conteneurs
cd /opt/netbird
sudo docker compose down -v

# Supprimer les fichiers
sudo rm -rf /opt/netbird
sudo rm /etc/systemd/system/netbird-server.service
sudo rm /root/netbird-info.txt

# Recharger systemd
sudo systemctl daemon-reload
```

## Dépannage

### Les conteneurs ne démarrent pas

```bash
# Vérifier les logs
sudo docker compose -f /opt/netbird/docker-compose.yml logs

# Vérifier l'état des conteneurs
sudo docker ps -a | grep netbird

# Redémarrer tous les services
sudo systemctl restart netbird-server
```

### Le Dashboard n'est pas accessible

```bash
# Vérifier que le conteneur dashboard est running
sudo docker ps | grep netbird-dashboard

# Vérifier les logs du dashboard
sudo docker logs netbird-dashboard

# Vérifier que le port est bien en écoute
sudo ss -tlnp | grep 8081
```

### Les clients ne peuvent pas se connecter

1. Vérifiez que le TURN server est accessible depuis l'extérieur :
```bash
# Vérifier que coturn écoute sur le bon port
sudo ss -ulnp | grep 33073
```

2. Vérifiez la configuration de l'IP externe du TURN :
```bash
# Dans /opt/netbird/config/.env
grep TURN_EXTERNAL_IP /opt/netbird/config/.env
```

3. Vérifiez que les ports UDP 49152-65535 sont ouverts dans le pare-feu

### Base de données PostgreSQL

```bash
# Vérifier que PostgreSQL fonctionne
sudo docker exec netbird-postgres pg_isready

# Se connecter à la base
sudo docker exec -it netbird-postgres psql -U netbird -d netbird

# Vérifier les tables
\dt
```

## Sécurité

- Tous les secrets sont générés automatiquement de manière sécurisée
- Les mots de passe sont stockés dans `/root/netbird-info.txt` (chmod 600)
- La configuration `.env` a des permissions restrictives (chmod 600)
- Il est **fortement recommandé** d'utiliser HTTPS en production
- Changez les secrets par défaut pour un environnement de production
- Configurez un pare-feu pour limiter l'accès aux ports nécessaires

## Mise à jour

```bash
# Arrêter les services
sudo systemctl stop netbird-server

# Mettre à jour les images Docker
cd /opt/netbird
sudo docker compose pull

# Redémarrer les services
sudo systemctl start netbird-server
```

## Support et documentation

- Documentation officielle Netbird : https://docs.netbird.io/
- Self-hosted guide : https://docs.netbird.io/selfhosted/selfhosted-guide
- GitHub Netbird : https://github.com/netbirdio/netbird
- Issues de ce projet : https://github.com/tiagomatiastm-prog/netbird-installer/issues

## Licence

MIT License - voir LICENSE pour plus de détails.

## Auteur

Tiago - 2025

## Contributeurs

Contributions bienvenues ! N'hésitez pas à ouvrir une issue ou un pull request.
