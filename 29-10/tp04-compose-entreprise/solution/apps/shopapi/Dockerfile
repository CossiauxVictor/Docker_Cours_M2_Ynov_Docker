# syntax=docker/dockerfile:1.7
# Dockerfile shopapi refait pour le TP01 (l'ancien est garde dans Dockerfile.legacy pour comparer)
#
# Etapes :
#   base     -> image node officielle epinglee + manifestes npm
#   deps     -> dependances de prod uniquement (npm ci --omit=dev)
#   test     -> dependances de dev + npm test + npm run lint (le build casse si les tests cassent)
#   runtime  -> alpine officielle + binaire node seulement (pas de npm/yarn/corepack), user node
#
# Images epinglees au tag precis. En prod on ajoute aussi @sha256:... pour figer le digest.

# ---------- base ----------
FROM node:20.20.2-alpine3.22 AS base
WORKDIR /app
# on copie que les manifestes : tant qu'ils bougent pas, la couche npm ci reste en cache
COPY package.json package-lock.json ./

# ---------- deps (prod) ----------
FROM base AS deps
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# ---------- test ----------
FROM base AS test
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts --no-audit --no-fund
COPY src ./src
COPY test ./test
RUN npm test && npm run lint

# ---------- runtime ----------
# meme branche alpine (3.22) que l'image node (musl identique), on recupere juste le binaire node.
# 3.22.7 = dernier patch : corrige 2 CVE HIGH openssl presentes dans 3.22.4 (vu au scan trivy du TP03)
# npm (16 Mo), yarn (5 Mo) et corepack servent a rien en prod -> ~75 Mo de gagne vs node:alpine
FROM alpine:3.22.7 AS runtime

ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/CossiauxVictor/Docker_Cours_M2_Ynov_Docker

# labels OCI (on ecrase aussi ceux herites de l'image de base)
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.22.7"

# libs C++ dont node a besoin + meme utilisateur node (uid 1000) que dans l'image officielle
RUN apk add --no-cache libstdc++=14.2.0-r6 libgcc=14.2.0-r6 \
 && addgroup -g 1000 node \
 && adduser -u 1000 -G node -s /bin/sh -D node

COPY --from=base /usr/local/bin/node /usr/local/bin/node

ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION}

WORKDIR /app

# fichiers proprietaire root : l'utilisateur node peut les lire mais pas les modifier
COPY --from=deps /app/node_modules ./node_modules
# astuce : package.json est pris depuis l'etape test et pas depuis le contexte.
# BuildKit ne construit que les etapes dont la cible depend, donc sans ca l'etape test
# serait sautee sur un build normal. La, si npm test echoue, l'image finale n'est pas produite.
COPY --from=test /app/package.json ./
COPY src ./src

USER node

EXPOSE 3000

# pas besoin de wget/curl : on utilise le fetch natif de node 20
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

# forme exec : node est le PID 1 et recoit directement le SIGTERM (le code gere deja l'arret propre)
CMD ["node", "src/server.js"]
