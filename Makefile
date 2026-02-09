.PHONY: build up down status logs shell reset restart onboard network-setup help \
       fly-init deploy fly-logs fly-status fly-console

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
