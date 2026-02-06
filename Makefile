.PHONY: build up down status logs shell reset restart onboard network-setup help

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
