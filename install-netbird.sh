#!/bin/bash
set -euo pipefail

#############################################
# Netbird Server Installer for Debian 13
# Description: Automated installation of Netbird self-hosted server (Management + Signal + Relay/TURN)
# Author: Tiago
# Date: 2025-11-07
#############################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
DEFAULT_DOMAIN="netbird.local"
DEFAULT_LISTEN_ADDRESS="127.0.0.1"
DEFAULT_HTTP_PORT="8080"
DEFAULT_DASHBOARD_PORT="8081"
DEFAULT_SIGNAL_PORT="10000"
DEFAULT_RELAY_PORT="33073"
DEFAULT_BEHIND_PROXY="true"
INSTALL_DIR="/opt/netbird"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_DIR="${INSTALL_DIR}/config"

# Initialize variables with defaults
DOMAIN="${DEFAULT_DOMAIN}"
LISTEN_ADDRESS="${DEFAULT_LISTEN_ADDRESS}"
HTTP_PORT="${DEFAULT_HTTP_PORT}"
DASHBOARD_PORT="${DEFAULT_DASHBOARD_PORT}"
SIGNAL_PORT="${DEFAULT_SIGNAL_PORT}"
RELAY_PORT="${DEFAULT_RELAY_PORT}"
BEHIND_PROXY="${DEFAULT_BEHIND_PROXY}"
TURN_EXTERNAL_IP=""
SKIP_DOCKER_INSTALL=false

# Help function
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Install Netbird self-hosted server (Management + Signal + Relay/TURN) via Docker.

OPTIONS:
    -d, --domain DOMAIN              Domain name for Netbird (default: ${DEFAULT_DOMAIN})
    -l, --listen ADDRESS             Listen address (default: ${DEFAULT_LISTEN_ADDRESS} for reverse proxy)
    -p, --http-port PORT             HTTP port for Management API (default: ${DEFAULT_HTTP_PORT})
    --dashboard-port PORT            Dashboard UI port (default: ${DEFAULT_DASHBOARD_PORT})
    --signal-port PORT               Signal server port (default: ${DEFAULT_SIGNAL_PORT})
    --relay-port PORT                Relay/TURN server port (default: ${DEFAULT_RELAY_PORT})
    --turn-ip IP                     External IP for TURN server (auto-detected if not provided)
    --behind-proxy [true|false]      Running behind reverse proxy (default: ${DEFAULT_BEHIND_PROXY})
    --skip-docker                    Skip Docker installation (use if already installed)
    -h, --help                       Show this help message

EXAMPLES:
    # Test installation with defaults (localhost)
    sudo $0

    # Production installation with domain
    sudo $0 --domain netbird.example.com --turn-ip 1.2.3.4

    # Custom ports behind reverse proxy
    sudo $0 --domain netbird.local --http-port 9000 --dashboard-port 9001

NOTES:
    - This script must be run as root
    - TURN server requires external IP for NAT traversal
    - If behind reverse proxy, configure HTTPS on your proxy (required for WebRTC)
    - Default credentials will be stored in /root/netbird-info.txt

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -l|--listen)
            LISTEN_ADDRESS="$2"
            shift 2
            ;;
        -p|--http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --dashboard-port)
            DASHBOARD_PORT="$2"
            shift 2
            ;;
        --signal-port)
            SIGNAL_PORT="$2"
            shift 2
            ;;
        --relay-port)
            RELAY_PORT="$2"
            shift 2
            ;;
        --turn-ip)
            TURN_EXTERNAL_IP="$2"
            shift 2
            ;;
        --behind-proxy)
            BEHIND_PROXY="$2"
            shift 2
            ;;
        --skip-docker)
            SKIP_DOCKER_INSTALL=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

# Detect actual user (not root when using sudo)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(eval echo ~${ACTUAL_USER})

print_info "Starting Netbird installation..."
print_info "Domain: ${DOMAIN}"
print_info "Listen Address: ${LISTEN_ADDRESS}"
print_info "Behind Reverse Proxy: ${BEHIND_PROXY}"

# Auto-detect external IP if not provided
if [[ -z "${TURN_EXTERNAL_IP}" ]]; then
    print_info "Detecting external IP for TURN server..."
    TURN_EXTERNAL_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "127.0.0.1")
    print_info "Detected external IP: ${TURN_EXTERNAL_IP}"
fi

# Install Docker if needed
if [[ "${SKIP_DOCKER_INSTALL}" == false ]]; then
    if ! command -v docker &> /dev/null; then
        print_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        print_info "Docker installed successfully"
    else
        print_info "Docker already installed, skipping..."
    fi
else
    print_info "Skipping Docker installation as requested"
fi

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    print_error "Docker is not running. Please start Docker and try again."
    exit 1
fi

# Create directories
print_info "Creating directories..."
mkdir -p "${DATA_DIR}"/{management,signal,relay,postgres}
mkdir -p "${CONFIG_DIR}"
chmod 755 "${INSTALL_DIR}"
chmod 755 "${DATA_DIR}"

# Generate secure passwords and secrets
print_info "Generating secure passwords and secrets..."
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
JWT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
IDP_MGMT_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
TURN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
POSTGRES_USER="netbird"
POSTGRES_DB="netbird"

# Set endpoints based on configuration
if [[ "${BEHIND_PROXY}" == "true" ]]; then
    NETBIRD_MGMT_API_ENDPOINT="https://${DOMAIN}/api"
    NETBIRD_DASHBOARD_ENDPOINT="https://${DOMAIN}"
    NETBIRD_SIGNAL_ENDPOINT="https://${DOMAIN}/signalexchange.SignalExchange/Send"
else
    NETBIRD_MGMT_API_ENDPOINT="http://${DOMAIN}:${HTTP_PORT}/api"
    NETBIRD_DASHBOARD_ENDPOINT="http://${DOMAIN}:${DASHBOARD_PORT}"
    NETBIRD_SIGNAL_ENDPOINT="http://${DOMAIN}:${SIGNAL_PORT}"
fi

# Create .env file
print_info "Creating environment configuration..."
cat > "${CONFIG_DIR}/.env" << EOF
# Netbird Configuration
# Generated on $(date)

# Domain Configuration
NETBIRD_DOMAIN=${DOMAIN}
NETBIRD_MGMT_API_ENDPOINT=${NETBIRD_MGMT_API_ENDPOINT}
NETBIRD_DASHBOARD_ENDPOINT=${NETBIRD_DASHBOARD_ENDPOINT}
NETBIRD_SIGNAL_ENDPOINT=${NETBIRD_SIGNAL_ENDPOINT}

# Network Configuration
LISTEN_ADDRESS=${LISTEN_ADDRESS}
HTTP_PORT=${HTTP_PORT}
DASHBOARD_PORT=${DASHBOARD_PORT}
SIGNAL_PORT=${SIGNAL_PORT}
RELAY_PORT=${RELAY_PORT}

# TURN/Relay Configuration
TURN_EXTERNAL_IP=${TURN_EXTERNAL_IP}
TURN_LISTEN_PORT=${RELAY_PORT}
TURN_PASSWORD=${TURN_PASSWORD}

# Database Configuration
POSTGRES_USER=netbird
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DB=netbird

# Security Secrets
JWT_SECRET=${JWT_SECRET}
IDP_MGMT_CLIENT_SECRET=${IDP_MGMT_CLIENT_SECRET}

# Reverse Proxy
BEHIND_REVERSE_PROXY=${BEHIND_PROXY}
EOF

chmod 600 "${CONFIG_DIR}/.env"

# Create docker-compose.yml
print_info "Creating Docker Compose configuration..."
cat > "${INSTALL_DIR}/docker-compose.yml" << 'EOFCOMPOSE'
version: '3.8'

services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: netbird-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - netbird-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Management Server
  management:
    image: netbirdio/management:latest
    container_name: netbird-management
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      NETBIRD_MGMT_API_ENDPOINT: ${NETBIRD_MGMT_API_ENDPOINT}
      NETBIRD_MGMT_SIGNAL_ENDPOINT: ${NETBIRD_SIGNAL_ENDPOINT}
      NETBIRD_STORE_ENGINE: postgres
      NETBIRD_STORE_ENGINE_POSTGRES_DSN: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable
      NETBIRD_HTTP_API_LISTEN_ADDR: 0.0.0.0:${HTTP_PORT}
      NETBIRD_AUTH_OIDC_CONFIGURATION_ENDPOINT: ""
      NETBIRD_USE_AUTH0: "false"
      NETBIRD_DISABLE_ANONYMOUS_METRICS: "true"
      NETBIRD_TURN_URI: turn:${TURN_EXTERNAL_IP}:${TURN_LISTEN_PORT}
      NETBIRD_TURN_USER: netbird
      NETBIRD_TURN_PASSWORD: ${TURN_PASSWORD}
      NETBIRD_SIGNAL_GRPC_LISTEN_ADDR: 0.0.0.0:10000
    volumes:
      - ./data/management:/var/lib/netbird
    ports:
      - "${LISTEN_ADDRESS}:${HTTP_PORT}:${HTTP_PORT}"
    networks:
      - netbird-network
    command: >
      sh -c "netbird-mgmt management --port ${HTTP_PORT} --log-level info --disable-anonymous-metrics"
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:${HTTP_PORT}/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Signal Server
  signal:
    image: netbirdio/signal:latest
    container_name: netbird-signal
    restart: unless-stopped
    environment:
      NETBIRD_SIGNAL_LISTEN_ADDR: 0.0.0.0:${SIGNAL_PORT}
      NETBIRD_LOG_LEVEL: info
    ports:
      - "${LISTEN_ADDRESS}:${SIGNAL_PORT}:${SIGNAL_PORT}"
    networks:
      - netbird-network
    command: >
      sh -c "netbird-signal run --port ${SIGNAL_PORT} --log-level info"

  # Dashboard (Web UI)
  dashboard:
    image: netbirdio/dashboard:latest
    container_name: netbird-dashboard
    restart: unless-stopped
    environment:
      NETBIRD_MGMT_API_ENDPOINT: ${NETBIRD_MGMT_API_ENDPOINT}
      NETBIRD_MGMT_GRPC_API_ENDPOINT: ${NETBIRD_MGMT_API_ENDPOINT}
      AUTH_AUDIENCE: netbird
      USE_AUTH0: "false"
      AUTH_SUPPORTED_SCOPES: "openid profile email api"
      NGINX_SSL_PORT: 443
      LETSENCRYPT_DOMAIN: ""
    ports:
      - "${LISTEN_ADDRESS}:${DASHBOARD_PORT}:80"
    networks:
      - netbird-network
    depends_on:
      - management

  # Coturn (TURN/STUN Server for relay)
  coturn:
    image: coturn/coturn:latest
    container_name: netbird-coturn
    restart: unless-stopped
    domainname: ${NETBIRD_DOMAIN}
    volumes:
      - ./data/relay:/var/lib/coturn
    network_mode: host
    command:
      - -n
      - --log-file=stdout
      - --external-ip=${TURN_EXTERNAL_IP}
      - --listening-port=${TURN_LISTEN_PORT}
      - --min-port=49152
      - --max-port=65535
      - --fingerprint
      - --lt-cred-mech
      - --user=netbird:${TURN_PASSWORD}
      - --realm=${NETBIRD_DOMAIN}
      - --no-cli
      - --no-dtls
      - --no-tls

networks:
  netbird-network:
    driver: bridge
EOFCOMPOSE

# Create systemd service for docker-compose
print_info "Creating systemd service..."
cat > /etc/systemd/system/netbird-server.service << EOF
[Unit]
Description=Netbird Server (Docker Compose)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_DIR}/.env
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start service
print_info "Starting Netbird services..."
systemctl daemon-reload
systemctl enable netbird-server.service
systemctl start netbird-server.service

# Wait for services to be ready
print_info "Waiting for services to start (this may take a minute)..."
sleep 20

# Check if services are running
if systemctl is-active --quiet netbird-server.service; then
    print_info "Netbird services started successfully!"
else
    print_error "Failed to start Netbird services"
    systemctl status netbird-server.service
    exit 1
fi

# Create info file
INFO_FILE="/root/netbird-info.txt"
print_info "Creating information file at ${INFO_FILE}..."

cat > "${INFO_FILE}" << EOF
========================================
  NETBIRD SERVER INSTALLATION INFO
========================================
Installation Date: $(date)
Domain: ${DOMAIN}

========================================
  ACCESS INFORMATION
========================================
Dashboard (Web UI): http://${LISTEN_ADDRESS}:${DASHBOARD_PORT}
Management API: http://${LISTEN_ADDRESS}:${HTTP_PORT}/api
Signal Server: ${LISTEN_ADDRESS}:${SIGNAL_PORT}
TURN/Relay Server: ${TURN_EXTERNAL_IP}:${RELAY_PORT}

$(if [[ "${BEHIND_PROXY}" == "true" ]]; then
    echo "REVERSE PROXY CONFIGURATION:"
    echo "  Configure your reverse proxy to forward:"
    echo "  - https://${DOMAIN} -> http://${LISTEN_ADDRESS}:${DASHBOARD_PORT} (Dashboard)"
    echo "  - https://${DOMAIN}/api -> http://${LISTEN_ADDRESS}:${HTTP_PORT}/api (API)"
    echo "  - wss://${DOMAIN}/signalexchange.SignalExchange/Send -> http://${LISTEN_ADDRESS}:${SIGNAL_PORT} (Signal)"
    echo ""
fi)

========================================
  AUTHENTICATION
========================================
Setup Type: Self-hosted (no external IDP)
First Admin User: Create via Dashboard on first access
Auth Method: Local authentication

========================================
  DATABASE CREDENTIALS
========================================
PostgreSQL Host: postgres (internal)
Database: ${POSTGRES_DB}
Username: ${POSTGRES_USER}
Password: ${DB_PASSWORD}

========================================
  TURN/RELAY CONFIGURATION
========================================
External IP: ${TURN_EXTERNAL_IP}
TURN Port: ${RELAY_PORT}
TURN User: netbird
TURN Password: ${TURN_PASSWORD}
UDP Port Range: 49152-65535 (must be open in firewall)

========================================
  SECURITY SECRETS
========================================
JWT Secret: ${JWT_SECRET}
IDP Management Client Secret: ${IDP_MGMT_CLIENT_SECRET}

========================================
  SYSTEM INFORMATION
========================================
Installation Directory: ${INSTALL_DIR}
Data Directory: ${DATA_DIR}
Configuration: ${CONFIG_DIR}/.env
Docker Compose: ${INSTALL_DIR}/docker-compose.yml

Service Management:
  Start:   sudo systemctl start netbird-server
  Stop:    sudo systemctl stop netbird-server
  Restart: sudo systemctl restart netbird-server
  Status:  sudo systemctl status netbird-server
  Logs:    sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f

========================================
  FIREWALL REQUIREMENTS
========================================
Required ports (open in firewall):
  - ${HTTP_PORT}/tcp (Management API)
  - ${DASHBOARD_PORT}/tcp (Dashboard)
  - ${SIGNAL_PORT}/tcp (Signal Server)
  - ${RELAY_PORT}/tcp+udp (TURN/STUN)
  - 49152-65535/udp (TURN relay range)

========================================
  CLIENT SETUP
========================================
1. Install Netbird client on devices
2. Configure setup key via Dashboard
3. Use setup key to connect clients

Setup URL: ${NETBIRD_DASHBOARD_ENDPOINT}

========================================
  NEXT STEPS
========================================
1. Access the Dashboard at http://${LISTEN_ADDRESS}:${DASHBOARD_PORT}
2. Create your first admin account
3. Generate setup keys for clients
4. Install Netbird client on devices
5. $(if [[ "${BEHIND_PROXY}" == "true" ]]; then echo "Configure your reverse proxy with HTTPS"; else echo "Consider setting up HTTPS with reverse proxy"; fi)

========================================
  TROUBLESHOOTING
========================================
View all container logs:
  sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f

View specific service logs:
  sudo docker logs netbird-management
  sudo docker logs netbird-signal
  sudo docker logs netbird-dashboard
  sudo docker logs netbird-coturn

Check container status:
  sudo docker ps | grep netbird

Restart all services:
  sudo systemctl restart netbird-server

========================================
  BACKUP
========================================
Important files to backup:
  - ${DATA_DIR}/ (all application data)
  - ${CONFIG_DIR}/.env (configuration)
  - ${INSTALL_DIR}/docker-compose.yml

Backup command:
  sudo tar czf netbird-backup-\$(date +%Y%m%d).tar.gz ${INSTALL_DIR}

========================================
EOF

chmod 600 "${INFO_FILE}"

# Display summary
print_info "========================================="
print_info "  NETBIRD INSTALLATION COMPLETE!"
print_info "========================================="
print_info ""
print_info "Dashboard URL: http://${LISTEN_ADDRESS}:${DASHBOARD_PORT}"
print_info "Management API: http://${LISTEN_ADDRESS}:${HTTP_PORT}/api"
print_info ""
print_info "Full details saved to: ${INFO_FILE}"
print_info ""
if [[ "${BEHIND_PROXY}" == "true" ]]; then
    print_warn "⚠ Configure your reverse proxy to forward traffic to Netbird"
    print_warn "⚠ HTTPS is required for WebRTC to work properly"
fi
print_info ""
print_info "Next steps:"
print_info "  1. Access the Dashboard to create admin account"
print_info "  2. Generate setup keys for client devices"
print_info "  3. Configure firewall to allow required ports"
print_info ""
print_info "Service management:"
print_info "  sudo systemctl status netbird-server"
print_info "  sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
print_info ""
print_info "========================================="
