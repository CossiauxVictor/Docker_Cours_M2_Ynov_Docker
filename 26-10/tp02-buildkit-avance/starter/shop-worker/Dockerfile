# syntax=docker/dockerfile:1.7
# shop-worker - TP02 (l'ancien Dockerfile est garde dans Dockerfile.legacy)
#
#   base     -> python slim epinglee + variables python
#   builder  -> venv /opt/venv avec les deps de prod (pip.conf en secret mount + cache pip)
#   test     -> deps de dev + ruff + pytest
#   runtime  -> base + venv + code, user non-root
#
# build : docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .

# ---------- base ----------
FROM python:3.12.15-slim-bookworm AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/opt/venv/bin:$PATH
WORKDIR /app

# ---------- builder ----------
FROM base AS builder
# TARGETARCH est rempli automatiquement par buildx (amd64, arm64...) :
# on s'en sert pour avoir un cache pip separe par archi (les wheels sont pas les memes)
ARG TARGETARCH
RUN python -m venv /opt/venv
COPY requirements.txt ./
# - secret : le pip.conf (avec le token du registre interne) est monte en tmpfs le temps du RUN
#   uniquement. Il apparait ni dans une couche, ni dans l'history, ni dans les metadata.
#   required=true -> le build plante si on oublie --secret (sinon pip partirait sur pypi.org en silence)
# - cache : /root/.cache/pip persiste entre les builds mais n'est jamais dans l'image
# DL3042 ignore volontaire : le cache pip est dans un cache mount BuildKit, il finit pas dans la couche
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf,required=true \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH},sharing=locked \
    pip install -r requirements.txt

# ---------- test ----------
FROM builder AS test
ARG TARGETARCH
COPY requirements-dev.txt ./
# DL3042 ignore volontaire : le cache pip est dans un cache mount BuildKit, il finit pas dans la couche
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf,required=true \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH},sharing=locked \
    pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
RUN ruff check worker tests \
 && python -m pytest -q -p no:cacheprovider tests

# ---------- runtime ----------
FROM base AS runtime

ARG VERSION=dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/CossiauxVictor/Docker_Cours_M2_Ynov_Docker
LABEL org.opencontainers.image.title="shop-worker" \
      org.opencontainers.image.description="Worker commandes Shop SAS (consomme orders:queue)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.base.name="docker.io/library/python:3.12.15-slim-bookworm"

# patch de secu en attendant que l'image python officielle soit reconstruite :
# CVE-2026-84782 (HIGH) dans libssl3/openssl 3.0.22-1~deb12u1, vue par la porte de release du TP03.
# version epinglee -> a retirer quand python:3.12.x-slim-bookworm embarque deb12u2
RUN apt-get update \
 && apt-get install -y --no-install-recommends --only-upgrade \
      libssl3=3.0.22-1~deb12u2 openssl=3.0.22-1~deb12u2 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 worker \
 && useradd --system --uid 10001 --gid worker --no-create-home --shell /usr/sbin/nologin worker

COPY --from=builder /opt/venv /opt/venv
# le code vient de l'etape test : ca force BuildKit a executer les tests meme sur un build "normal"
COPY --from=test /app/worker ./worker

USER 10001:10001
EXPOSE 9100

# le worker expose ses metriques prometheus sur 9100 : si ca repond, la boucle tourne
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2); sys.exit(0)"]

CMD ["python", "-m", "worker.main"]
