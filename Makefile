.PHONY: build up down status logs shell reset restart onboard network-setup help \
       fly-init deploy fly-logs fly-status fly-console \
       format format-check lint lint-shell lint-docker setup

SANDBOX_NAME ?= clawd
WORKSPACE_DIR ?= $(shell pwd)
TEMPLATE_TAG ?= clawd-template:latest

help:
	@echo "Clawd - OpenClaw in Docker Sandbox"
	@echo ""
	@echo "Setup:"
	@echo "  make build          Build custom sandbox template"
	@echo "  make up             Create sandbox + start gateway"
	@echo "  make onboard        Run OpenClaw onboarding wizard"
	@echo ""
	@echo "Operations:"
	@echo "  make down           Stop sandbox"
	@echo "  make status         Check sandbox and gateway health"
	@echo "  make logs           Tail OpenClaw gateway logs"
	@echo "  make shell          Interactive shell in sandbox"
	@echo "  make restart        Restart gateway (no rebuild)"
	@echo "  make reset          Destroy and recreate sandbox"
	@echo ""
	@echo "Config:"
	@echo "  make network-setup  Apply network proxy rules"
	@echo ""
	@echo "Code Quality:"
	@echo "  make setup          Install pre-commit hooks"
	@echo "  make format         Auto-format (Prettier)"
	@echo "  make format-check   Check formatting (CI)"
	@echo "  make lint           Run all linters"
	@echo "  make lint-shell     Lint shell scripts (shellcheck)"
	@echo "  make lint-docker    Lint Dockerfiles (hadolint)"
	@echo ""
	@echo "Remote (Fly.io):"
	@echo "  make fly-init APP=<name>  Generate fly.toml from template"
	@echo "  make deploy               Deploy to Fly.io"
	@echo "  make fly-logs             Tail remote logs"
	@echo "  make fly-status           Check remote VM status"
	@echo "  make fly-console          SSH into remote VM"

build:
	@echo "Building sandbox template..."
	docker build -t $(TEMPLATE_TAG) template/

up: build
	@./scripts/sandbox-up.sh $(SANDBOX_NAME) $(WORKSPACE_DIR) $(TEMPLATE_TAG)

down:
	@./scripts/sandbox-down.sh $(SANDBOX_NAME)

status:
	@./scripts/sandbox-status.sh $(SANDBOX_NAME)

logs:
	@./scripts/sandbox-logs.sh $(SANDBOX_NAME)

shell:
	docker sandbox exec -it "$(SANDBOX_NAME)" bash

reset: down
	docker sandbox rm "$(SANDBOX_NAME)" 2>/dev/null || true
	@$(MAKE) up

onboard:
	docker sandbox exec -it \
		-e ANTHROPIC_API_KEY \
		-e OPENROUTER_API_KEY \
		-e TELEGRAM_BOT_TOKEN \
		-e OPENCLAW_GATEWAY_TOKEN \
		"$(SANDBOX_NAME)" openclaw onboard

restart:
	@./scripts/sandbox-up.sh "$(SANDBOX_NAME)" "$(WORKSPACE_DIR)" "$(TEMPLATE_TAG)"

network-setup:
	@./scripts/network-policy.sh $(SANDBOX_NAME)

# =============================================================================
# Code Quality
# =============================================================================

format:
	@if command -v pnpm >/dev/null 2>&1; then \
		pnpm format; \
	elif command -v npx >/dev/null 2>&1; then \
		npx prettier --write .; \
	else \
		echo "Error: pnpm or npx required. Install with: npm install -g pnpm"; false; \
	fi

format-check:
	@if command -v pnpm >/dev/null 2>&1; then \
		pnpm format:check; \
	elif command -v npx >/dev/null 2>&1; then \
		npx prettier --check .; \
	else \
		echo "Error: pnpm or npx required. Install with: npm install -g pnpm"; false; \
	fi

SHELL_SCRIPTS = $(wildcard scripts/*.sh remote/*.sh)
DOCKERFILES = template/Dockerfile remote/Dockerfile

lint: format-check lint-shell lint-docker

lint-shell:
	@command -v shellcheck >/dev/null 2>&1 || (echo "Error: shellcheck not found. Install: brew install shellcheck"; false)
	shellcheck -e SC1091 $(SHELL_SCRIPTS)

lint-docker:
	@command -v hadolint >/dev/null 2>&1 || (echo "Error: hadolint not found. Install: brew install hadolint"; false)
	hadolint --ignore DL3008 --ignore DL3013 $(DOCKERFILES)

setup:
	@command -v pre-commit >/dev/null 2>&1 || (echo "Error: pre-commit not found. Install: brew install pre-commit"; false)
	pre-commit install
	pre-commit install --hook-type pre-push
	@echo "Pre-commit hooks installed."

# =============================================================================
# Remote (Fly.io)
# =============================================================================

FLY_REGION ?= iad

fly-init:
	@./remote/fly-init.sh $(APP) $(FLY_REGION)

deploy:
	@./remote/deploy.sh

FLY_APP = $(shell test -f fly.toml && grep '^app' fly.toml | head -1 | sed 's/app *= *"\(.*\)"/\1/')

fly-logs:
	@test -n "$(FLY_APP)" || (echo "Error: fly.toml not found. Run: make fly-init APP=<name>" && false)
	fly logs -a $(FLY_APP)

fly-status:
	@test -n "$(FLY_APP)" || (echo "Error: fly.toml not found. Run: make fly-init APP=<name>" && false)
	fly status -a $(FLY_APP)

fly-console:
	@test -n "$(FLY_APP)" || (echo "Error: fly.toml not found. Run: make fly-init APP=<name>" && false)
	fly ssh console -a $(FLY_APP)
