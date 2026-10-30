SHELL := /bin/bash
.DEFAULT_GOAL := help

# Settings from .env (COMPOSE_PROFILES, SECRETS_SOURCE, SECRETS_DIR, ...)
-include .env
# Service versions on staging, written by scripts/remote.sh on deploy
-include versions.env
export

# With IMAGE_TAG, build/skip.yml from `make images` keeps the services that have
# no image at all (neither built nor in GHCR) from starting. $(shell) and not
# $(wildcard): make caches directories at start and would miss the file that
# `make images` writes in the same run (make dev).
SKIP_FILE = $(if $(IMAGE_TAG),$(shell [ -f build/skip.yml ] && echo -f build/skip.yml))
COMPOSE = docker compose -f compose.yml $(SKIP_FILE)
comma := ,

# SRC=.. builds the services from your working copies next to pouw-deploy
# (../pouw-node, ...) instead of main from GitHub, tags them :local and runs
# them with the `network` profile. `make dev` and `make dev-test` set it.
ifdef SRC
IMAGE_TAG ?= local
# := and not ?=: make dev runs a sub-make, which inherits E2E_SRC=build/src
# exported by the parent
E2E_SRC := $(SRC)
override COMPOSE_PROFILES := $(if $(COMPOSE_PROFILES),$(COMPOSE_PROFILES)$(comma))network
TEST_PROFILES ?= network
endif

# Tests use neither profiles from .env nor ports on the host, so they do not
# collide with a running network on the same machine
TEST_PROJECT ?= pouw-test
TEST = COMPOSE_PROFILES=$(TEST_PROFILES) SECRETS_DIR=.secrets $(COMPOSE) -f compose.test.yml -p $(TEST_PROJECT)

# e2e/run.sh of the services from these clones (made by `make images`),
# with SRC from your working copies (set above)
E2E_SRC ?= build/src

# With IMAGE_TAG, service images from `make images` are used instead of :main from GHCR
ifdef IMAGE_TAG
NODE_VERSION := $(IMAGE_TAG)
INDEXER_VERSION := $(IMAGE_TAG)
WORKLOAD_VERSION := $(IMAGE_TAG)
DASHBOARD_VERSION := $(IMAGE_TAG)
DASHBOARD_HASURA_VERSION := $(IMAGE_TAG)
endif

.PHONY: help secrets up down restart seed ps logs check images test test-down dev dev-test

help: ## List of commands
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-10s %s\n", $$1, $$2 }'

dev: ## Build the services from ../pouw-* and start the whole network locally
	$(MAKE) images up SRC=..

dev-test: ## Build the services from ../pouw-* and test them in a separate copy
	$(MAKE) images test SRC=..

secrets: ## Prepare secrets (random locally, from pass on the server)
	@./scripts/secrets.sh

# With IMAGE_TAG the service images are local builds that are not in GHCR,
# so only missing images (Postgres, Grafana, ...) are pulled
up: secrets ## Start services according to COMPOSE_PROFILES
ifndef IMAGE_TAG
	$(COMPOSE) pull -q --ignore-buildable
endif
	$(COMPOSE) up -d --build --pull missing --remove-orphans --wait --wait-timeout 300

down: ## Stop services of all profiles (data is kept)
	$(COMPOSE) down --remove-orphans

restart: secrets ## Restart services, e.g. after a password change in pass
	$(COMPOSE) up -d --force-recreate --wait --wait-timeout 300

seed: ## Load the fixture blocks of pouw-indexer into the running network
	$(COMPOSE) --profile network exec -T indexer /bin/sh -c \
		'DATABASE_URL="postgres://pouw:$$(cat /run/secrets/postgres_password)@postgres:5432/pouw" exec pouw-indexer seed'

ps: ## Service status
	$(COMPOSE) ps

logs: ## Logs, e.g. make logs s=jenkins
	$(COMPOSE) logs -f --tail=200 $(s)

check: ## Validate compose for all profiles and the Prometheus config
	COMPOSE_PROFILES=jenkins,proxy,network,host-metrics $(COMPOSE) config -q
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" \
		--entrypoint promtool quay.io/prometheus/prometheus:v3.0.0 \
		check config /etc/prometheus/prometheus.yml

images: ## Build service images from main (or SRC=..), e.g. make images test IMAGE_TAG=local
	./scripts/build-images.sh

test: ## Smoke and e2e tests in a separate copy of the network (results in reports/)
	SECRETS_SOURCE=local SECRETS_DIR=.secrets ./scripts/secrets.sh
	$(TEST) up -d --wait --wait-timeout 300
	JUNIT_XML=reports/smoke.xml ./e2e/smoke.sh $(TEST_PROJECT)
	@failed=0; found=0; for t in $(E2E_SRC)/*/e2e/run.sh; do \
		[ -x "$$t" ] || continue; \
		found=1; echo "== $$t"; \
		JUNIT_DIR=reports "$$t" $(TEST_PROJECT) || failed=1; \
	done; \
	[ $$found = 1 ] || echo "WARNING: no e2e/run.sh in $(E2E_SRC)/*, only the smoke tests ran"; \
	exit $$failed

test-down: ## Remove the test copy of the network
	$(TEST) down -v --remove-orphans
