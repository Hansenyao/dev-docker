# Host-side entry points for the ai-dev container. Run these on macOS.
SHELL := /bin/bash
COMPOSE := docker compose
TEST_IMAGE := buildpack-deps:noble-scm
WORKSPACE := $(HOME)/ai-workspace
STATE := $(HOME)/.ai-dev

.PHONY: setup build up down shell check check-host rebuild vscode test-unit require-setup

setup:
	@scripts/host/setup

build:
	$(COMPOSE) build

up: require-setup
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

shell:
	docker exec -it -u ai-coder -w /workspace ai-dev bash

check: check-host
	docker exec -u ai-coder ai-dev ai-dev-check
	docker exec -u ai-coder ai-dev smoke-test

check-host:
	@scripts/host/check-file-sharing

rebuild: require-setup
	$(COMPOSE) build --pull
	$(COMPOSE) up -d --force-recreate

vscode:
	@scripts/host/ai-code

# Tests are streamed into a throwaway container with tar because Docker
# Desktop File Sharing does not include this repository.
test-unit:
	tar --no-xattrs -c scripts tests vscode | docker run --rm -i $(TEST_IMAGE) bash -c 'mkdir -p /src && cd /src && tar -x && bash tests/run.sh'

# Refuse to start without the mount sources; otherwise Docker would create
# them itself (or fail with an unclear error).
require-setup:
	@for d in "$(WORKSPACE)" "$(STATE)/claude" "$(STATE)/git" "$(STATE)/secrets"; do \
	  if [ ! -d "$$d" ]; then echo "Missing $$d - run 'make setup' first." >&2; exit 1; fi; \
	done
