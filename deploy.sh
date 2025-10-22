#!/bin/bash
# Automated Docker Deployment Script
#Error Handling
set -e
set -u
set -o pipefail

LOGFILE="deploy_$(date +%Y%m%d).log"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo "[ERROR] Script failed at line $LINENO"; exit 1' ERR
trap 'echo "[INFO] Script interrupted."; exit 2' INT

echo "Deployment started at $(date)"

# User input collection
read -p "Git Repo URL: " REPO_URL
read -s -p "Personal Access Token: " PAT; echo
read -p "SSH Username: " SSH_UNAME
read -p "SSH IP Address: " SSH_IP
read -p "SSH Key path [~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
read -p "Internal Container Application Port [8080]: " APP_PORT
APP_PORT=${APP_PORT:-8080}

# Local workspace setup
echo "Preparing local workspace..."
WORKDIR="$PWD/stagingarea"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

REPO=$(basename -s .git "$REPO_URL")
AUTH_URL="https://${PAT}@${REPO_URL#https://}"

if [ -d "$REPO/.git" ]; then
  echo "Repository exists. Pulling latest changes..."
  cd "$REPO"
  git pull || { echo "Git pull failed"; exit 20; }
else
  echo "Cloning repository..."
  git clone "$AUTH_URL" || { echo "Git clone failed"; exit 20; }
  cd "$REPO"
fi
echo "Repository ready."

# Verify Dockerfile or docker-compose.yml
if [[ ! -f Dockerfile && ! -f docker-compose.yml ]]; then
  echo "Error: No Dockerfile or docker-compose.yml found."
  exit 30
else
  echo "Docker build file detected."
fi

#Connectivity check
echo "Checking server connectivity..."
ping -c 2 "$SSH_IP" >/dev/null || {
  echo "Error: Server not reachable (ping failed)."
  exit 40
}
echo "Ping OK."

echo "Testing SSH access..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_UNAME@$SSH_IP" "echo SSH OK" >/dev/null || {
  echo "Error: SSH connection failed."
  exit 40
}
echo "SSH OK."

# Remote environment setup
echo "Setting up remote environment..."
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP" <<'EOF'
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo usermod -aG docker $USER
sudo systemctl enable --now docker
sudo systemctl enable --now nginx
docker --version
docker-compose --version
nginx -v
rm -rf ~/app && mkdir ~/app
EOF
echo "Remote environment ready."

# Transfer project files
echo "Transferring project files..."
scp -i "$SSH_KEY" -r ./* "$SSH_UNAME@$SSH_IP:~/app"

# Deploy Docker container
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP" <<EOF
cd ~/app
echo "Building Docker image..."
docker build -t hng1 .

echo "Stopping old container..."
docker rm -f hng1_container 2>/dev/null || true

echo "Running new container..."
docker run -d --name hng1_container -p 127.0.0.1:$APP_PORT:$APP_PORT hng1

echo "Checking container health..."
docker ps --filter "name=hng1_container"
docker logs --tail 10 hng1_container

echo "Testing container access..."
curl -I http://127.0.0.1:$APP_PORT | head -n 1
EOF

# Configure Nginx reverse proxy
echo "Configuring Nginx..."
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP" <<EOF
sudo bash -c 'cat > /etc/nginx/sites-available/app.conf <<NGINXCONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINXCONF'

sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
sudo nginx -t
sudo systemctl reload nginx
EOF

# Validate deployment
echo "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP" <<EOF
echo "Checking Docker service..."
sudo systemctl is-active --quiet docker && echo "Docker is running."

echo "Checking container..."
docker ps --filter "name=hng1_container"

echo "Checking Nginx service..."
sudo systemctl is-active --quiet nginx && echo "Nginx is running."

echo "Testing local proxy..."
curl -I http://127.0.0.1 | head -n 1

echo "Testing external proxy..."
curl -I http://$SSH_IP | head -n 1
EOF

echo "=== Deployment completed successfully at $(date) ==="
exit 0
