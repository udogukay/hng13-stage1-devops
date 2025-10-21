#!/bin/bash
# 
# exit if any command fails
# unset variables = error
# if any pipe command fails, exit
set -e
set -u
set -o pipefail
#
# 
read -p "Git Repo URL:" REPO_URL
