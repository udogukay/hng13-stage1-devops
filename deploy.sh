#!/bin/bash
#
#
#
# important error handling
set -e
set -u
set -o pipefail
#
LOGFILE="deploy_$(date +%Y%m%d).log"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo "[ERROR] Script failed at line \$LINENO"; exit 1' ERR
trap 'echo "[INFO] Script interrupted."; exit 2' INT

echo "Deployment started at $(date)"
#
#
# User input collection
read -p "Git Repo URL" REPO_URL
read -p "Personal Access Token " PAT
read -p "SSH Username" SSH_UNAME
read -p "SSH IP Address" SSH_IP
read -p "SSH Key path" SSH_KEY
read -p "Internal Container Application Port" APP_PORT
#
#
# Local Workspace prep
echo "Prepping Local Workspace..."
WORKDIR="$PWD/stagingarea"
REPO=$()
mkdir -p "$WORKDIR"
cd "$WORKDIR"
REPO=$(basename -s .git "$REPO_URL")
AUTH_URL="https://${PAT}@${REPO_URL#https://}"
echo "Cloning Repo..."
if [ -d "$REPO/.git" ]; then
  echo "Repository exists. Pulling latest changes..."
  cd "$REPO"
  git pull
else
  echo "Cloning repository..."
  git clone "$AUTH_URL"
  cd "$REPO"
fi
echo "done"

if [[ ! -f Dockerfile && ! -f docker-compose.yml ]]; then
  echo "Error: No Dockerfile or docker-compose.yml found"
  exit 1
else
    echo "Docker profile detected"
fi

echo "Local Workspace prep complete"
echo "Checking server connectivity..."
ping -c 2 "$SSH_HOST" >/dev/null || {
  echo "Error: Server not reachable (ping failed)."
  exit 1
}
echo "connectivity test passed"
# SSH into remote server and update/ install required appps
#
echo "updating remote env, prepping docker and nginx..."
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP"

<<EOF
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo usermod -aG docker \$USER
echo "Starting services..."
sudo systemctl enable --now docker
sudo systemctl enable --now nginx

docker --version
docker-compose --version
nginx -v

rm -rf ~/app && mkdir ~/app
EOF
echo "done"
echo "Transferring project files via scp..."
scp -i "$SSH_KEY" -r ./* "$SSH_UNAME@$SSH_IP:~/app"
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP"
<<EOF
cd ~/app
echo "Building Docker image..."
docker build -t hng1 .

docker rm -f hng1_container 2>/dev/null || true

echo "Running new container..."
docker run -d --name hng1_container -p 127.0.0.1:$APP_PORT:$APP_PORT app_image

echo "Checking container health..."
docker ps --filter "name=hng1_container"
docker logs --tail 10 hng1_container

echo "Testing app accessibility..."
curl -I http://127.0.0.1:$APP_PORT | head -n 1
EOF
echo "Configuring Nginx as reverse proxy..."
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_HOST" <<EOF
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

echo "Testing Nginx configuration..."
sudo nginx -t

echo "Reloading Nginx..."
sudo systemctl reload nginx
EOF

echo "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_HOST" <<EOF
echo "Checking Docker service..."
sudo systemctl is-active --quiet docker && echo "Docker is running."

echo "Checking container status..."
docker ps --filter "name=app_container"

echo "Checking Nginx service..."
sudo systemctl is-active --quiet nginx && echo "Nginx is running."

echo "Testing local proxy access..."
curl -I http://127.0.0.1 | head -n 1

echo "Testing external access (server public IP)..."
curl -I http://$SSH_HOST | head -n 1
EOF
echo "Validation complete."
