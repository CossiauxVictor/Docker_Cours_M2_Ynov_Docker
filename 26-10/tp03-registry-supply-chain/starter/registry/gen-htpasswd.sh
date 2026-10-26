#!/usr/bin/env bash
# gen-htpasswd.sh : genere auth/htpasswd (bcrypt, obligatoire pour registry:2) avec les 2 comptes du TP
# les mots de passe peuvent etre surcharges par variables d'env
set -euo pipefail
CI_PASSWORD="${CI_PASSWORD:-ci-push-2024}"
DEV_PASSWORD="${DEV_PASSWORD:-dev-pull-2024}"
mkdir -p auth
{
  docker run --rm --entrypoint htpasswd httpd:2.4.65-alpine -Bbn ci  "$CI_PASSWORD"
  docker run --rm --entrypoint htpasswd httpd:2.4.65-alpine -Bbn dev "$DEV_PASSWORD"
} | sed '/^$/d' > auth/htpasswd
echo "auth/htpasswd genere :"
cut -d: -f1 auth/htpasswd
