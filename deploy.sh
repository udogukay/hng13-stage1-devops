#!/bin/bash
# 
# exit if any command fails
# unset variables = error
# if any pipe command fails, exit
set -e
set -u
set -o pipefail
#
# User input 
read -p "Git Repo URL:" REPO_URL
read -p "Personal Access Token: " PAT
read -p "SSH Username" SSH_UNAME
read -p "SSH IP Address" SSH_IP
read -p "SSH Key path" SSH_KEY
read -p "Internal Container Application Port" APP_PORT
#
# SSH into host and update/ install required appps
#
ssh -i "$SSH_KEY" "$SSH_UNAME@$SSH_IP" 
<<EOF
sudo apt update -y
sudo apt install -y docker.io nginx
sudo systemctl enable --now docker nginx
rm -rf ~/app && mkdir ~/appsudo apt update -y
sudo apt install -y docker.io nginx
sudo systemctl enable --now docker nginx
rm -rf ~/app && mkdir ~/app

EOF
