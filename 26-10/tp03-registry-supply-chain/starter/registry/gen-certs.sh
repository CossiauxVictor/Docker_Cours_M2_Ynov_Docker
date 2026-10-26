#!/usr/bin/env bash
# gen-certs.sh : CA interne Shop SAS + certificat serveur pour registry.local
# usage : ./gen-certs.sh [dossier_sortie]   (defaut ./certs)
# Sous Windows/Git Bash l'option -subj "/CN=..." se fait convertir en chemin windows par MSYS,
# donc le plus simple c'est de le lancer dans un conteneur :
#   docker run --rm -v "$PWD:/w" -w /w alpine:3.22.4 sh -c 'apk add -q bash openssl && bash gen-certs.sh'
set -euo pipefail

OUT="${1:-./certs}"
DAYS_CA=3650
DAYS_SRV=397          # max accepte par les navigateurs pour un certif serveur
CN="registry.local"
mkdir -p "$OUT"
cd "$OUT"

# 1) CA interne (a garder precieusement : qui a ca.key peut signer un faux registry.local)
if [[ ! -f ca.key ]]; then
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS_CA" \
    -subj "/C=FR/O=Shop SAS/OU=Plateforme/CN=Shop SAS Internal CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out ca.crt
  echo "[ok] CA creee"
else
  echo "[skip] CA deja presente, je la reutilise"
fi

# 2) cle + CSR du serveur
openssl genrsa -out registry.key 2048
openssl req -new -key registry.key -subj "/C=FR/O=Shop SAS/CN=${CN}" -out registry.csr

# 3) signature par la CA avec les SAN (sans SAN, Go/Docker refuse le certif : le CN est ignore depuis Go 1.15)
cat > registry.ext <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${CN},DNS:registry,DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in registry.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days "$DAYS_SRV" -sha256 -extfile registry.ext -out registry.crt
rm -f registry.csr registry.ext

chmod 600 ca.key registry.key
chmod 644 ca.crt registry.crt
# le registry tourne en root dans l'image officielle, mais au cas ou on le passe en non-root
chmod 644 registry.key 2>/dev/null || true

openssl verify -CAfile ca.crt registry.crt
openssl x509 -in registry.crt -noout -subject -issuer -dates -ext subjectAltName
