# Guide de déploiement Ansible - Netbird Server

Ce guide explique comment déployer Netbird Server sur plusieurs serveurs en utilisant Ansible.

## Prérequis

- Ansible 2.9+ installé sur la machine de contrôle
- Accès SSH avec clés publiques sur les serveurs cibles
- Privilèges sudo sur les serveurs cibles
- Debian 13 (Trixie) sur les serveurs cibles

## Structure des fichiers

```
netbird-installer/
├── install-netbird.sh          # Script d'installation
├── inventory.ini               # Inventaire Ansible
├── deploy-netbird.yml          # Playbook principal
└── group_vars/
    └── netbird_servers.yml     # Variables de groupe
```

## Configuration de l'inventaire

Créez un fichier `inventory.ini` :

```ini
[netbird_servers]
netbird-prod-1 ansible_host=192.168.1.100 ansible_user=debian
netbird-prod-2 ansible_host=192.168.1.101 ansible_user=debian
netbird-test ansible_host=192.168.1.150 ansible_user=debian

[netbird_servers:vars]
ansible_become=yes
ansible_become_method=sudo
ansible_python_interpreter=/usr/bin/python3
```

## Variables de configuration

Créez le fichier `group_vars/netbird_servers.yml` :

```yaml
---
# Configuration Netbird
netbird_domain: "netbird.example.com"
netbird_behind_proxy: true
netbird_listen_address: "127.0.0.1"
netbird_http_port: 8080
netbird_dashboard_port: 8081
netbird_signal_port: 10000
netbird_relay_port: 33073

# IP externe pour TURN (sera auto-détectée si non spécifiée)
# netbird_turn_ip: "203.0.113.50"

# Installation Docker
skip_docker_install: false

# Reverse proxy
configure_reverse_proxy: false
reverse_proxy_type: "nginx"  # nginx, caddy, traefik

# Certificats SSL (si configure_reverse_proxy=true)
use_letsencrypt: true
letsencrypt_email: "admin@example.com"
```

## Playbook Ansible

Créez le fichier `deploy-netbird.yml` :

```yaml
---
- name: Deploy Netbird Server
  hosts: netbird_servers
  become: yes
  vars:
    script_url: "https://raw.githubusercontent.com/tiagomatiastm-prog/netbird-installer/main/install-netbird.sh"
    install_script: "/tmp/install-netbird.sh"

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install required packages
      apt:
        name:
          - curl
          - ca-certificates
          - gnupg
          - lsb-release
        state: present

    - name: Download Netbird installation script
      get_url:
        url: "{{ script_url }}"
        dest: "{{ install_script }}"
        mode: '0755'

    - name: Check if Netbird is already installed
      stat:
        path: /opt/netbird/docker-compose.yml
      register: netbird_installed

    - name: Build installation command
      set_fact:
        install_command: >-
          {{ install_script }}
          --domain {{ netbird_domain }}
          --listen {{ netbird_listen_address }}
          --http-port {{ netbird_http_port }}
          --dashboard-port {{ netbird_dashboard_port }}
          --signal-port {{ netbird_signal_port }}
          --relay-port {{ netbird_relay_port }}
          --behind-proxy {{ netbird_behind_proxy }}
          {% if skip_docker_install %}--skip-docker{% endif %}
          {% if netbird_turn_ip is defined %}--turn-ip {{ netbird_turn_ip }}{% endif %}

    - name: Install Netbird Server
      shell: "{{ install_command }}"
      args:
        executable: /bin/bash
      register: install_result
      when: not netbird_installed.stat.exists

    - name: Display installation output
      debug:
        var: install_result.stdout_lines
      when: not netbird_installed.stat.exists

    - name: Wait for Netbird services to be ready
      wait_for:
        host: "{{ netbird_listen_address }}"
        port: "{{ netbird_dashboard_port }}"
        delay: 10
        timeout: 120
      when: not netbird_installed.stat.exists

    - name: Check Netbird service status
      systemd:
        name: netbird-server
        state: started
        enabled: yes
      register: service_status

    - name: Retrieve installation info
      slurp:
        src: /root/netbird-info.txt
      register: netbird_info
      changed_when: false

    - name: Display installation info
      debug:
        msg: "{{ netbird_info.content | b64decode }}"

    - name: Configure Nginx reverse proxy
      block:
        - name: Install Nginx
          apt:
            name: nginx
            state: present

        - name: Install Certbot for Let's Encrypt
          apt:
            name:
              - certbot
              - python3-certbot-nginx
            state: present
          when: use_letsencrypt

        - name: Create Nginx configuration for Netbird
          template:
            src: templates/nginx-netbird.conf.j2
            dest: /etc/nginx/sites-available/netbird
            mode: '0644'

        - name: Enable Nginx site
          file:
            src: /etc/nginx/sites-available/netbird
            dest: /etc/nginx/sites-enabled/netbird
            state: link

        - name: Test Nginx configuration
          command: nginx -t
          register: nginx_test
          changed_when: false

        - name: Reload Nginx
          systemd:
            name: nginx
            state: reloaded

        - name: Obtain Let's Encrypt certificate
          command: >
            certbot --nginx -d {{ netbird_domain }}
            --non-interactive --agree-tos
            --email {{ letsencrypt_email }}
            --redirect
          when: use_letsencrypt
          register: certbot_result

      when: configure_reverse_proxy and reverse_proxy_type == "nginx"

    - name: Configure UFW firewall
      block:
        - name: Install UFW
          apt:
            name: ufw
            state: present

        - name: Allow SSH
          ufw:
            rule: allow
            port: '22'
            proto: tcp

        - name: Allow Netbird ports
          ufw:
            rule: allow
            port: "{{ item.port }}"
            proto: "{{ item.proto }}"
          loop:
            - { port: "{{ netbird_http_port }}", proto: "tcp" }
            - { port: "{{ netbird_dashboard_port }}", proto: "tcp" }
            - { port: "{{ netbird_signal_port }}", proto: "tcp" }
            - { port: "{{ netbird_relay_port }}", proto: "tcp" }
            - { port: "{{ netbird_relay_port }}", proto: "udp" }
            - { port: "49152:65535", proto: "udp" }

        - name: Allow HTTP/HTTPS if using reverse proxy
          ufw:
            rule: allow
            port: "{{ item }}"
            proto: tcp
          loop:
            - "80"
            - "443"
          when: configure_reverse_proxy

        - name: Enable UFW
          ufw:
            state: enabled
            policy: deny

      when: ansible_facts['distribution'] == "Debian"

- name: Display deployment summary
  hosts: netbird_servers
  become: yes
  gather_facts: no
  tasks:
    - name: Show access information
      debug:
        msg:
          - "=========================================="
          - "Netbird Server deployed successfully!"
          - "=========================================="
          - "Host: {{ inventory_hostname }}"
          - "Dashboard: http://{{ netbird_listen_address }}:{{ netbird_dashboard_port }}"
          - "Management API: http://{{ netbird_listen_address }}:{{ netbird_http_port }}/api"
          - ""
          - "Check /root/netbird-info.txt for full details"
          - "=========================================="
```

## Template Nginx

Créez le fichier `templates/nginx-netbird.conf.j2` :

```nginx
# Netbird Server - Nginx Configuration
# Generated by Ansible

upstream netbird_dashboard {
    server {{ netbird_listen_address }}:{{ netbird_dashboard_port }};
}

upstream netbird_api {
    server {{ netbird_listen_address }}:{{ netbird_http_port }};
}

upstream netbird_signal {
    server {{ netbird_listen_address }}:{{ netbird_signal_port }};
}

server {
    listen 80;
    listen [::]:80;
    server_name {{ netbird_domain }};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect to HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{ netbird_domain }};

    # SSL Configuration (will be managed by Certbot)
    ssl_certificate /etc/letsencrypt/live/{{ netbird_domain }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ netbird_domain }}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/{{ netbird_domain }}/chain.pem;

    # SSL Security
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Dashboard
    location / {
        proxy_pass http://netbird_dashboard;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Management API
    location /api {
        proxy_pass http://netbird_api/api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Signal Server (WebSocket)
    location /signalexchange.SignalExchange/ {
        proxy_pass http://netbird_signal;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Déploiement

### 1. Vérifier la configuration

```bash
# Test de connectivité
ansible netbird_servers -i inventory.ini -m ping

# Vérifier les variables
ansible-inventory -i inventory.ini --list --yaml
```

### 2. Déployer sur tous les serveurs

```bash
ansible-playbook -i inventory.ini deploy-netbird.yml
```

### 3. Déployer sur un serveur spécifique

```bash
ansible-playbook -i inventory.ini deploy-netbird.yml --limit netbird-test
```

### 4. Mode dry-run (vérification)

```bash
ansible-playbook -i inventory.ini deploy-netbird.yml --check
```

### 5. Avec verbosité pour le debug

```bash
ansible-playbook -i inventory.ini deploy-netbird.yml -v
```

## Exemples de déploiement

### Production avec reverse proxy et HTTPS

```yaml
# group_vars/netbird_servers.yml
---
netbird_domain: "vpn.mycompany.com"
netbird_behind_proxy: true
netbird_listen_address: "127.0.0.1"
configure_reverse_proxy: true
reverse_proxy_type: "nginx"
use_letsencrypt: true
letsencrypt_email: "admin@mycompany.com"
```

```bash
ansible-playbook -i inventory.ini deploy-netbird.yml
```

### Test en local sans reverse proxy

```yaml
# group_vars/netbird_servers.yml
---
netbird_domain: "netbird.local"
netbird_behind_proxy: false
netbird_listen_address: "0.0.0.0"
configure_reverse_proxy: false
```

```bash
ansible-playbook -i inventory.ini deploy-netbird.yml --limit netbird-test
```

### Mise à jour des serveurs existants

```bash
# Arrêter les services
ansible netbird_servers -i inventory.ini -b -m systemd -a "name=netbird-server state=stopped"

# Mettre à jour les images Docker
ansible netbird_servers -i inventory.ini -b -m shell -a "cd /opt/netbird && docker compose pull"

# Redémarrer les services
ansible netbird_servers -i inventory.ini -b -m systemd -a "name=netbird-server state=started"
```

## Vérification post-déploiement

```bash
# Vérifier l'état des services
ansible netbird_servers -i inventory.ini -b -m systemd -a "name=netbird-server"

# Vérifier les conteneurs Docker
ansible netbird_servers -i inventory.ini -b -m shell -a "docker ps | grep netbird"

# Récupérer les informations de connexion
ansible netbird_servers -i inventory.ini -b -m shell -a "cat /root/netbird-info.txt"
```

## Gestion des secrets avec Ansible Vault

Pour sécuriser les mots de passe et secrets :

```bash
# Créer un fichier de variables chiffrées
ansible-vault create group_vars/netbird_secrets.yml

# Éditer le fichier
ansible-vault edit group_vars/netbird_secrets.yml

# Contenu du fichier
---
vault_letsencrypt_email: "admin@example.com"
vault_netbird_turn_ip: "203.0.113.50"

# Déployer avec le vault
ansible-playbook -i inventory.ini deploy-netbird.yml --ask-vault-pass
```

## Dépannage

### Erreur de connexion SSH

```bash
# Tester la connexion
ansible netbird_servers -i inventory.ini -m ping -u debian

# Vérifier les clés SSH
ssh-copy-id debian@192.168.1.100
```

### Erreur de privilèges sudo

```bash
# Tester sudo
ansible netbird_servers -i inventory.ini -b -m shell -a "whoami"

# Vérifier la configuration sudo sur le serveur
ssh debian@192.168.1.100 "sudo -l"
```

### Le service ne démarre pas

```bash
# Consulter les logs
ansible netbird_servers -i inventory.ini -b -m shell -a "journalctl -u netbird-server -n 50"

# Vérifier les conteneurs
ansible netbird_servers -i inventory.ini -b -m shell -a "docker compose -f /opt/netbird/docker-compose.yml logs"
```

## Sauvegarde avec Ansible

Créez un playbook `backup-netbird.yml` :

```yaml
---
- name: Backup Netbird Server
  hosts: netbird_servers
  become: yes
  vars:
    backup_dir: "/backup/netbird"
    backup_date: "{{ ansible_date_time.date }}"

  tasks:
    - name: Create backup directory
      file:
        path: "{{ backup_dir }}"
        state: directory
        mode: '0700'

    - name: Stop Netbird services
      systemd:
        name: netbird-server
        state: stopped

    - name: Create backup archive
      archive:
        path: /opt/netbird
        dest: "{{ backup_dir }}/netbird-backup-{{ inventory_hostname }}-{{ backup_date }}.tar.gz"
        format: gz

    - name: Start Netbird services
      systemd:
        name: netbird-server
        state: started

    - name: Fetch backup to local machine
      fetch:
        src: "{{ backup_dir }}/netbird-backup-{{ inventory_hostname }}-{{ backup_date }}.tar.gz"
        dest: "./backups/"
        flat: yes
```

Exécuter la sauvegarde :

```bash
ansible-playbook -i inventory.ini backup-netbird.yml
```

## Monitoring avec Ansible

Créez un playbook `monitor-netbird.yml` :

```yaml
---
- name: Monitor Netbird Server
  hosts: netbird_servers
  become: yes
  gather_facts: yes

  tasks:
    - name: Check service status
      systemd:
        name: netbird-server
      register: service_status

    - name: Check Docker containers
      shell: docker ps --filter "name=netbird" --format "table {{.Names}}\t{{.Status}}"
      register: containers_status
      changed_when: false

    - name: Check disk usage
      shell: df -h /opt/netbird
      register: disk_usage
      changed_when: false

    - name: Display monitoring results
      debug:
        msg:
          - "Host: {{ inventory_hostname }}"
          - "Service Active: {{ service_status.status.ActiveState }}"
          - "Containers:"
          - "{{ containers_status.stdout }}"
          - "Disk Usage:"
          - "{{ disk_usage.stdout }}"
```

## Ressources

- Documentation Ansible : https://docs.ansible.com/
- Documentation Netbird : https://docs.netbird.io/
- Best practices Ansible : https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html
