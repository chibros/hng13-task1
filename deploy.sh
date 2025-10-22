#!/usr/bin/env bash

#==========================================

#DevOps Stage 1 - Automated Deployment Script

#POSIX/Bash script (requires bash)

#Features: input collection + validation, logging, idempotency,

#remote preparation (Docker / Buildx / Compose / Nginx),

#transfer, build, deploy, Nginx reverse-proxy, health checks,

#--cleanup flag to remove deployed resources.

#==========================================

set -euo pipefail IFS=$'\n\t'

#----------------------------

#Globals

#-----------------------------

LOG_DIR="./logs"
mkdir -p "$LOG_DIR" 
LOGFILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log" 
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo "[ERROR] Unexpected failure. See $LOGFILE" >&2; exit 1' ERR 
trap 'echo "Interrupted by user" >&2; exit 130' INT

echo "==========================================" 
echo "Automated deployment script - $(date)" 
echo "Logs: $LOGFILE" 
echo "=========================================="

usage() { 
  cat <<EOF Usage: $0 [--cleanup]

  This script automates deployment of a Dockerized app to a remote server. It will prompt for the required inputs. Use --cleanup to remove deployed resources on the remote host. 
EOF exit 1 
}

CLEANUP=false 
if [ "${1-}" = "--cleanup" ]; 
then CLEANUP=true 
fi

#-----------------------------

#Read/gather inputs (with defaults and validation)

#-----------------------------

read_input() { 
  read -r -p "Enter GitHub repository URL (https://...git): " REPO_URL 
  REPO_URL=${REPO_URL:-}

  read -r -p "Enter GitHub Personal Access Token (PAT): " PAT 
  PAT=${PAT:-}

  read -r -p "Enter branch name [main]: " BRANCH 
  BRANCH=${BRANCH:-main}

  read -r -p "Enter remote server username [ubuntu]: " REMOTE_USER 
  REMOTE_USER=${REMOTE_USER:-ubuntu}

  read -r -p "Enter remote server IP or hostname: " REMOTE_HOST 
  REMOTE_HOST=${REMOTE_HOST:-}

  read -r -p "Enter path to SSH private key (absolute or ~/...): " SSH_KEY 
  SSH_KEY=${SSH_KEY:-}

  read -r -p "Enter application internal port (container) [80]: " APP_PORT 
  APP_PORT=${APP_PORT:-80}

  echo echo "Summary of inputs:" 
  echo "  Repo: $REPO_URL" 
  echo "  Branch: $BRANCH" 
  echo "  Remote: $REMOTE_USER@$REMOTE_HOST" 
  echo "  SSH key: $SSH_KEY" 
  echo "  App port: $APP_PORT" 
  echo 
}

validate_inputs() { 
  err=false 
  if [ -z "$REPO_URL" ]; then echo "[ERROR] Repo URL is required"; err=true; fi 
  if [ -z "$PAT" ]; then echo "[ERROR] GitHub PAT is required"; err=true; fi 
  if [ -z "$REMOTE_HOST" ]; then echo "[ERROR] Remote host is required"; err=true; fi 
  if [ -z "$SSH_KEY" ]; then echo "[ERROR] SSH key path is required"; err=true; fi 
  if [ ! -f "${SSH_KEY/#~/$HOME}" ]; then echo "[ERROR] SSH key file not found: $SSH_KEY"; err=true; fi 
  if [ "$err" = true ]; then echo "Fix the errors above and re-run."; exit 2; fi 
}

#-----------------------------

#Helper: run remote commands (single SSH connection)

#-----------------------------

remote_run() { 
  local cmd="$1" 
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${SSH_KEY/#~/$HOME}" "$REMOTE_USER@$REMOTE_HOST" "$cmd" 
  }

#Check SSH connectivity

ssh_check() { 
  echo "[INFO] Checking SSH connectivity to $REMOTE_USER@$REMOTE_HOST..." 
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${SSH_KEY/#~/$HOME}" "$REMOTE_USER@$REMOTE_HOST" "echo OK" >/dev/null 2>&1; 
  then echo "[ERROR] SSH connection failed. Verify SSH key, user and host."; exit 3 
  fi 
  echo "[OK] SSH connectivity verified." 
}

#-----------------------------

#Remote preparation: install Docker CE, buildx, compose plugin, nginx

#-----------------------------

remote_prepare() { 
  echo "[INFO] Preparing remote host..." 
  read -r -d '' PREP <<REMOTE set -e

# update

sudo apt-get update -y

# install packages required for docker repo

sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

# add docker repo key

sudo install -m 0755 -d /etc/apt/keyrings 
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# add docker repo

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null 
sudo apt-get update -y

# install docker + plugins + nginx

sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nginx

# ensure services enabled

sudo systemctl enable --now docker 
sudo systemctl enable --now nginx

# add user to docker group

sudo usermod -aG docker "$USER"

# ensure correct permissions for /home/$USER

sudo mkdir -p /home/$USER/app || true 
REMOTE

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY/#~/$HOME}" "$REMOTE_USER@$REMOTE_HOST" "$PREP"

echo "[OK] Remote host prepared (Docker, Buildx, Compose plugin, Nginx installed)." 
}

#-----------------------------

#Transfer project files idempotently using rsync or scp

#-----------------------------

transfer_files() { 
  echo "[INFO] Transferring project files to remote host..."

  #Use rsync if available

  if command -v rsync >/dev/null 2>&1; 
  then 
  rsync -avz --delete --exclude ".git" -e "ssh -i ${SSH_KEY/#\~/$HOME} -o StrictHostKeyChecking=no" . "$REMOTE_USER@$REMOTE_HOST:~/app"
  else
    # fallback to tar+ssh
    tar -czf /tmp/deploy_archive.tar.gz --exclude .git .
    scp -i "${SSH_KEY/#\~/$HOME}" /tmp/deploy_archive.tar.gz "$REMOTE_USER@$REMOTE_HOST:~/deploy_archive.tar.gz"
    remote_run "mkdir -p ~/app && tar -xzf ~/deploy_archive.tar.gz -C ~/app && rm ~/deploy_archive.tar.gz"
    rm -f /tmp/deploy_archive.tar.gz
  fi
  echo "[OK] Files transferred to ~/app on remote host."
}
  
#-----------------------------

# Remote deploy: build and run container (supports Dockerfile or docker-compose.yml)

#-----------------------------

remote_deploy() {
  echo "[INFO] Deploying application on remote host..."
  # Remote commands handle idempotency
  read -r -d '' DEPLOY_CMDS <<'REMOTE'
set -e
cd ~/app
# ensure branch is checked out (if git repo was transferred as .git, otherwise skip)
if [ -d .git ]; then
  git fetch --all --prune
  git checkout "$BRANCH" || git checkout -b "$BRANCH" origin/"$BRANCH" || true
  git pull origin "$BRANCH" || true
fi
# prefer docker-compose if present
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  sudo -v
  sudo docker compose down --remove-orphans || true
  sudo docker compose up -d --build
else
  # Build image idempotently
  IMAGE_NAME="deployed_app"
  sudo docker build -t "$IMAGE_NAME" .
  # remove old container if exists
  if sudo docker ps -a --format '{{.Names}}' | grep -q "^deployed_app$"; then
    sudo docker rm -f deployed_app || true
  fi
  sudo docker run -d --name deployed_app -p 127.0.0.1:${APP_PORT}:${APP_PORT} "$IMAGE_NAME" || true
fi
REMOTE

  # send variables and run on remote
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY/#\~/$HOME}" "$REMOTE_USER@$REMOTE_HOST" "APP_PORT=${APP_PORT} BRANCH=${BRANCH} bash -s" <<'ENDSSH'
'"$DEPLOY_CMDS"'
ENDSSH

  echo "[OK] Remote deployment commands executed."
}

# -----------------------------
# Configure Nginx reverse proxy to forward 80 to container port
# -----------------------------
configure_nginx() {
  echo "[INFO] Configuring Nginx reverse proxy on remote host..."
  read -r -d '' NGINX_CONF <<'NGINX'
server {
    listen 80;
    server_name _;

    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://127.0.0.1:APP_PORT;
    }
}
NGINX

  # replace placeholder and write file remotely
  NGINX_CONF_ESCAPED="$(echo "$NGINX_CONF" | sed "s/APP_PORT/${APP_PORT}/g" | sed -e 's/\$/\$\$/g')"
  remote_run "sudo bash -c 'cat > /etc/nginx/sites-available/deployed_app <<\'EOF\'
$NGINX_CONF_ESCAPED
EOF
'"
  remote_run "sudo ln -sf /etc/nginx/sites-available/deployed_app /etc/nginx/sites-enabled/deployed_app"
  remote_run "sudo nginx -t && sudo systemctl reload nginx"
  echo "[OK] Nginx configured and reloaded."
}

# -----------------------------
# Validation: check docker service, container health, nginx
# -----------------------------
validate_deploy() {
  echo "[INFO] Validating deployment..."
  remote_run "sudo systemctl is-active --quiet docker && echo 'docker:running' || echo 'docker:failed'"
  remote_run "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true"
  remote_run "curl -sS -I http://127.0.0.1:${APP_PORT} | head -n 5" || true
  remote_run "sudo systemctl is-active --quiet nginx && echo 'nginx:running' || echo 'nginx:failed'"
  echo "[OK] Validation commands executed. Inspect above output for detailed status."
}

# -----------------------------
# Cleanup function for --cleanup
# -----------------------------

remote_cleanup() {
  echo "[INFO] Running remote cleanup..."
  read -r -d '' CLEANUP_CMDS <<REMOTE
set -e
cd ~
sudo docker compose down --rmi all --volumes || true
sudo docker rm -f deployed_app || true
sudo docker image rm -f deployed_app || true
sudo rm -rf ~/app || true
sudo rm -f /etc/nginx/sites-available/deployed_app || true
sudo rm -f /etc/nginx/sites-enabled/deployed_app || true
sudo nginx -t || true
sudo systemctl reload nginx || true
REMOTE
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY/#\~/$HOME}" "$REMOTE_USER@$REMOTE_HOST" "$CLEANUP_CMDS"
  echo "[OK] Remote cleanup completed."
}

# -----------------------------
# Main flow
# -----------------------------
read_input
validate_inputs
ssh_check

if [ "$CLEANUP" = true ]; then
  remote_cleanup
  echo "Cleanup finished. Exiting."
  exit 0
fi

remote_prepare
transfer_files
remote_deploy
configure_nginx
validate_deploy

echo "=========================================="
echo "Deployment finished. Access your app at: http://$REMOTE_HOST"
echo "Logs saved to: $LOGFILE"
echo "=========================================="

exit 0