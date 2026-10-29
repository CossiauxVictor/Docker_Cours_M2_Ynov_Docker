# Outillage equipe Shop SAS (TP04)
#   make up / make down / make logs        -> dev
#   make prod-up / make prod-down          -> prod (images du registre)
#   make migrate M=002-add-sku.sql
#   make test                              -> smoke test
#   make tools                             -> adminer (http://adminer.localhost)
# Sous Windows sans make : les commandes sont lisibles et copiables telles quelles dans git bash.

COMPOSE      := docker compose
COMPOSE_PROD := docker compose -f compose.yml -f compose.prod.yml

.PHONY: help secrets up down logs ps tools migrate test prod-config prod-up prod-down prod-test clean

help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

# genere le mot de passe BDD si absent (hexa -> pas de souci dans DATABASE_URL)
# tr -d '\r\n' : sous windows openssl sort un \r\n, le \r finissait dans le mot de passe (vecu...)
secrets:
	@mkdir -p secrets
	@test -s secrets/db_password.txt || (openssl rand -hex 24 | tr -d '\r\n' > secrets/db_password.txt && echo "secrets/db_password.txt cree")
	@test -f .env || cp .env.example .env
	@test -f apps/shop-worker/pip.conf || cp apps/shop-worker/pip.conf.example apps/shop-worker/pip.conf

up: secrets
	$(COMPOSE) up -d --build --wait
	$(COMPOSE) ps

down:
	$(COMPOSE) --profile tools --profile ops down

logs:
	$(COMPOSE) logs -f --tail 50

ps:
	$(COMPOSE) ps

tools: secrets
	$(COMPOSE) --profile tools up -d --wait

migrate:
	@test -n "$(M)" || (echo "usage : make migrate M=002-add-sku.sql" && exit 1)
	MIGRATION=$(M) $(COMPOSE) run --rm migrate

test:
	./smoke-test.sh

prod-config:
	$(COMPOSE_PROD) config

prod-up: secrets
	$(COMPOSE_PROD) up -d --wait
	$(COMPOSE_PROD) ps

prod-down:
	$(COMPOSE_PROD) down

prod-test:
	COMPOSE="$(COMPOSE_PROD)" ./smoke-test.sh

# ATTENTION : supprime les volumes (donc la base). Jamais en prod (cf TP05)
clean:
	$(COMPOSE) --profile tools --profile ops down -v
