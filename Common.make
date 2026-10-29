# -----------------------------------------------------------------------------------------------------------
# Common Makefile — go-remote
# -----------------------------------------------------------------------------------------------------------
# A hardened container around one local git repo, served over BitBang: Herdr's web UI for agent chat and a
# terminal (GR_UI=web), or BitBang's own terminal on a tmux session (GR_UI=shell). The go-remote CLI in cli/ does
# the work; the run, url, attach and logs targets wrap it, building it first when needed.
#
# By convention (Code Red):
#  - targets that are called by the user
#    - are named 'target-name'
#    - have a .PHONY directive with a short "##" comment that describes the target
#  - "##" comments are automatically detected by the help target and displayed in the help message
#  - utility targets that are used by other targets
#    - are named 'target_name'
#    - are listed in .PHONY (no "##" comment — hidden from make help)
#
# Choosing a workspace: run and run-detached mount REPO=/path/to/repo, or the current directory when REPO
# is not given. The other targets take REPO too, and fall back to the only workspace when exactly one exists.
#
# Must stay compatible with GNU Make 3.81 (the macOS default): no .ONESHELL, no $(file ...).
# -----------------------------------------------------------------------------------------------------------

.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

PROJECT_NAME := go-remote
SHELL := /bin/bash

COMMON_MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))
LOGGER := source $(COMMON_MAKEFILE_DIR)scripts/log.bash &&
CHECKENV_SCRIPT := $(COMMON_MAKEFILE_DIR)scripts/checkenv.bash
SCRIPTS_DIR := $(COMMON_MAKEFILE_DIR)scripts

IMAGE := go-remote:latest
E2E_IMAGE := go-remote-e2e:latest
HOME_VOLUME := $(or $(GR_HOME_VOLUME),go-remote-home)
QR ?= true
BIN_DIR ?= $(HOME)/.local/bin

# go-remote for this host, built in Docker by `make cli` into dist/, and rebuilt when its sources change
GR_OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
GR_ARCH := $(if $(filter arm64 aarch64,$(shell uname -m)),arm64,x64)
GO_REMOTE := $(COMMON_MAKEFILE_DIR)dist/go-remote-$(GR_OS)-$(GR_ARCH)
GR_SOURCES := $(shell find "$(COMMON_MAKEFILE_DIR)cli/src" "$(COMMON_MAKEFILE_DIR)ingress" -name '*.ts' 2>/dev/null) \
	$(addprefix $(COMMON_MAKEFILE_DIR),package.json bun.lock cli/Dockerfile skills/go-remote/SKILL.md)
GR_RUN := GR_ROOT="$(COMMON_MAKEFILE_DIR)" "$(GO_REMOTE)"
GR_QR_FLAG := $(if $(filter false False FALSE no 0,$(QR)),--no-qr)

DOCKER_COMPOSE := docker compose
COMPOSE := $(DOCKER_COMPOSE) --project-directory "$(COMMON_MAKEFILE_DIR)" -f "$(COMMON_MAKEFILE_DIR)docker-compose.yml"

# The agent user's uid/gid. Docker Desktop maps bind-mount ownership on its own, so 1000 is fine on
# macOS. On Linux the container must use the host uid to write to the mounted repo.
UNAME_S := $(shell uname -s)
STAT_MODE := $(if $(filter Darwin,$(UNAME_S)),stat -f '%Lp',stat -c '%a')

ifeq ($(UNAME_S),Darwin)
USER_UID := 1000
USER_GID := 1000
else
USER_UID := $(shell id -u)
USER_GID := $(shell id -g)
ifeq ($(USER_UID),0)
USER_UID := 1000
USER_GID := 1000
endif
endif

# make bump-version X.Y.Z: the version is an argument, not a goal, so it gets a rule that does nothing.
ifeq ($(firstword $(MAKECMDGOALS)),bump-version)
BUMP_VERSION := $(word 2,$(MAKECMDGOALS))
ifneq ($(wordlist 3,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS)),)
$(error Usage: make bump-version [X.Y.Z])
endif
ifneq ($(BUMP_VERSION),)
.PHONY: $(BUMP_VERSION)
$(BUMP_VERSION):
	@:
endif
endif

# -----------------------------------------------------------------------------------------------------------
# Workspace selection
#
# Each repo gets its own compose project, go-remote-<repo directory name>. Its label go-remote.repo
# records the mounted path, which is how targets find workspaces without REPO.
# -----------------------------------------------------------------------------------------------------------

REPO ?=

# run and run-detached mount the shell's current directory when REPO is not given. PWD, not CURDIR, so
# make -C <this dir> run still mounts the directory it was called from. Other targets keep an empty REPO,
# which means "the only workspace" (or every workspace, for down).
ifeq ($(strip $(REPO)),)
ifneq ($(filter run run-detached,$(MAKECMDGOALS)),)
REPO := $(or $(PWD),$(CURDIR))
endif
endif

REPO_EXPANDED := $(patsubst ~%,$(HOME)%,$(strip $(REPO)))
REPO_PATH := $(if $(REPO_EXPANDED),$(shell cd "$(REPO_EXPANDED)" 2>/dev/null && pwd -P))

go_remote_project = go-remote-$(shell printf '%s' "$$(basename "$(1)")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')

# Recursive on purpose: docker is only asked when a target actually needs the list.
WORKSPACE_PROJECTS = $(shell docker ps -a --filter label=go-remote.repo \
	--format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u)

ifneq ($(REPO_EXPANDED),)
PROJECT := $(call go_remote_project,$(or $(REPO_PATH),$(REPO_EXPANDED)))
else
PROJECT = $(if $(filter 1,$(words $(WORKSPACE_PROJECTS))),$(WORKSPACE_PROJECTS))
endif

# -----------------------------------------------------------------------------------------------------------
# Help (default target)
#
# This will display any PHONY target in the Makefile that has a comment that
# starts with '##'.
# -----------------------------------------------------------------------------------------------------------

.PHONY: help build cli install-cli check run run-detached url login attach ping logs down clean clean-home
.PHONY: upgrade test unit e2e lint format format-check bump-version
.PHONY: check_docker check_buildx check_env check_env_perms check_project_repo check_image require_repo export_ca
.PHONY: check_dprint check_shfmt check_mbake check_shellcheck check_formatters

.PHONY: help ## Show this help message
help:
	@$(LOGGER) log_banner
	@$(LOGGER) log_info "Available make targets ($(PROJECT_NAME)):"
	@echo ""
	@grep -E \
		'^.PHONY: .*?## .*$$' $(MAKEFILE_LIST) | \
		sort | \
		awk 'BEGIN {FS = ".PHONY: |## "}; {printf "  %-22s - %s\n", $$2, $$3}'
	@echo ""
	@$(LOGGER) log_info "Quick start"
	@$(LOGGER) log_dim "make build && make run REPO=~/src/my-repo"
	@$(LOGGER) log_dim "make install-cli && go-remote start ~/src/my-repo   # the CLI, for agent handoff and more"

# -----------------------------------------------------------------------------------------------------------
# Check environment and tools targets
# -----------------------------------------------------------------------------------------------------------

# Check Docker, the daemon and Compose v2 are available
check_docker:
	@if ! command -v docker >/dev/null 2>&1; then \
		$(LOGGER) log_error "Docker is not installed."; \
		exit 1; \
	fi
	@if ! docker info >/dev/null 2>&1; then \
		$(LOGGER) log_error "The Docker daemon is not running. Start Docker Desktop (or dockerd) and retry."; \
		exit 1; \
	fi
	@if ! docker compose version >/dev/null 2>&1; then \
		$(LOGGER) log_error "Docker Compose v2 ('docker compose') is required."; \
		exit 1; \
	fi
	@$(LOGGER) log_info_dim "docker $$(docker version -f '{{.Server.Version}}') and compose $$(docker compose version --short) are available."

# Check the Buildx plugin is installed. Only targets that build need it: the legacy builder does not set TARGETARCH,
# and cli and unit pass BuildKit-only flags
check_buildx:
	@if ! docker buildx version >/dev/null 2>&1; then \
		$(LOGGER) log_error "Docker Buildx (BuildKit) is required: the legacy builder does not set TARGETARCH."; \
		$(LOGGER) log_indent log_dim "macOS with Homebrew: brew install docker-buildx, then link it into ~/.docker/cli-plugins (brew prints the command)."; \
		$(LOGGER) log_indent log_dim "Linux: install docker-buildx-plugin from Docker's apt or dnf repository."; \
		exit 1; \
	fi
	@$(LOGGER) log_info_dim "buildx $$(docker buildx version | awk '{print $$2}') is available."

# Create .env from .env.example if needed (owner-only), and check every key has a value
check_env:
	@cd "$(COMMON_MAKEFILE_DIR)"; \
	created=0; \
	[ -f .env ] || created=1; \
	$(CHECKENV_SCRIPT) .env && { [ "$$created" = 0 ] || chmod 600 .env; }

# .env holds API keys and a GitHub token, so it should be readable by its owner only
check_env_perms:
	@cd "$(COMMON_MAKEFILE_DIR)"; \
	[ -f .env ] || exit 0; \
	perms=$$($(STAT_MODE) .env); \
	case "$$perms" in \
		*00) $(LOGGER) log_info_dim ".env is private (mode $$perms)." ;; \
		*) $(LOGGER) log_warning ".env is readable by other users (mode $$perms). Fix with: chmod 600 .env" ;; \
	esac

# REPO defaults to the current directory, so this catches an explicit REPO= only; go-remote checks it is a single,
# mountable repository
require_repo:
	@if [ -z "$(REPO_EXPANDED)" ]; then \
		$(LOGGER) log_error "Pass the repo to mount, e.g. make run REPO=~/src/my-repo"; \
		exit 1; \
	fi

# The project name is the repo's directory name, so two repos can share it: refuse to stop another repo's workspace
check_project_repo:
	@[ -n "$(REPO_EXPANDED)" ] || exit 0; \
	repo="$(or $(REPO_PATH),$(REPO_EXPANDED))"; \
	existing=$$(docker ps -a --filter label=com.docker.compose.project=$(PROJECT) --format '{{.Label "go-remote.repo"}}' | head -n 1); \
	if [ -n "$$existing" ] && [ "$$existing" != "$$repo" ]; then \
		$(LOGGER) log_error "$(PROJECT) serves $$existing, not $$repo. Stop it with: make down REPO=$$existing"; \
		exit 1; \
	fi

# Check the image has been built
check_image:
	@if ! docker image inspect $(IMAGE) >/dev/null 2>&1; then \
		$(LOGGER) log_error "Image $(IMAGE) not found. Build it with: make build"; \
		exit 1; \
	fi
.PHONY: check ## Verify Docker, Buildx, .env and its permissions
check:
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Checking dependencies"
	@$(MAKE) check_docker
	@$(MAKE) check_buildx
	@$(MAKE) check_env
	@$(MAKE) check_env_perms
	@$(LOGGER) log_success "Check complete"

# -----------------------------------------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------------------------------------

# Export a Zscaler root CA into certs/ when the host has one
export_ca:
	@$(SCRIPTS_DIR)/export-ca.bash

.PHONY: build ## Build the go-remote image (trusts a Zscaler root CA when the host has one)
build: check_docker check_buildx export_ca
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Building $(IMAGE) (agent uid $(USER_UID), gid $(USER_GID))"
	@docker build \
		--build-arg USER_UID=$(USER_UID) \
		--build-arg USER_GID=$(USER_GID) \
		-t $(IMAGE) \
		"$(COMMON_MAKEFILE_DIR)"
	@$(LOGGER) log_success "Built $(IMAGE)"

.PHONY: cli ## Build go-remote for macOS and Linux into dist/ after its unit tests, in Docker
cli: check_docker check_buildx export_ca
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Building go-remote into dist/"
	@docker build --target dist --output "type=local,dest=$(COMMON_MAKEFILE_DIR)dist" \
		-f "$(COMMON_MAKEFILE_DIR)cli/Dockerfile" "$(COMMON_MAKEFILE_DIR)"
	@touch "$(COMMON_MAKEFILE_DIR)"dist/go-remote-*
	@$(LOGGER) log_success "Built $$(cd "$(COMMON_MAKEFILE_DIR)dist" && ls go-remote-* | tr '\n' ' ')"

$(GO_REMOTE): $(GR_SOURCES)
	@$(MAKE) cli

.PHONY: install-cli ## Install go-remote, and gr linked to it, into BIN_DIR (default ~/.local/bin), set to use this checkout
install-cli: $(GO_REMOTE)
	@mkdir -p "$(BIN_DIR)"
	@install -m 0755 "$(GO_REMOTE)" "$(BIN_DIR)/go-remote"
	@if [ "$(UNAME_S)" = Darwin ] && ! codesign --verify "$(BIN_DIR)/go-remote" >/dev/null 2>&1; then \
		codesign --force --sign - "$(BIN_DIR)/go-remote"; \
	fi
	@"$(BIN_DIR)/go-remote" setup --root "$(COMMON_MAKEFILE_DIR)"
	@$(LOGGER) log_success "Installed $$("$(BIN_DIR)/go-remote" --version) as $(BIN_DIR)/go-remote"
	@gr="$(BIN_DIR)/gr"; \
	if [ -L "$$gr" ] && [ "$$(readlink "$$gr")" = go-remote ]; then :; \
	elif [ -e "$$gr" ] || [ -L "$$gr" ]; then \
		if [ -e "$$gr.bak" ] || [ -L "$$gr.bak" ]; then \
			$(LOGGER) log_warning "$$gr is not go-remote and $$gr.bak exists, so gr is not linked; left both as they are"; \
			exit 0; \
		fi; \
		mv "$$gr" "$$gr.bak" && $(LOGGER) log_warning "Moved the $$gr that was there to $$gr.bak"; \
	fi; \
	ln -sfn go-remote "$$gr" && $(LOGGER) log_success "Linked $$gr to go-remote"; \
	printf '%s\n' "$$PATH" | tr ':' '\n' | while IFS= read -r dir; do \
		[ -n "$$dir" ] && [ -f "$$dir/gr" ] && [ -x "$$dir/gr" ] && [ ! "$$dir/gr" -ef "$$gr" ] && \
			$(LOGGER) log_warning "$$dir/gr is also on PATH; whichever comes first runs as gr, so use go-remote to be sure"; \
	done; true
	@case ":$$PATH:" in \
		*":$(BIN_DIR):"*) ;; \
		*) $(LOGGER) log_warning "$(BIN_DIR) is not on PATH; add it in your shell profile" ;; \
	esac
	$(if $(filter upgrade,$(MAKECMDGOALS)),,@$(LOGGER) log_info_dim "Next: go-remote install-skill adds /go-remote to Claude Code, Codex and Cursor")

.PHONY: install-skill ## Install the /go-remote skill for Claude Code, Codex and Cursor
install-skill: $(GO_REMOTE)
	@$(GR_RUN) install-skill$(if $(filter upgrade,$(MAKECMDGOALS)), --embedded)

# The CLI, its built-in skill and the image change together: a new CLI on an old image starts agents the old way.
# So under upgrade nothing is installed until the image builds, even with make -j, and the skill is the CLI's own
# copy rather than whatever skills.sh publishes. Running workspaces keep their image until they restart, and
# restarting one ends its phone sessions, so they are only listed.
ifneq ($(filter upgrade,$(MAKECMDGOALS)),)
install-cli install-skill: build
endif

.PHONY: upgrade ## Build the image and install the CLI and the /go-remote skill from this checkout (git pull first)
upgrade: build install-cli install-skill
	@$(LOGGER) log_success "go-remote $$("$(BIN_DIR)/go-remote" --version | awk '{print $$2}'), its skill and the image are up to date"
	@image=$$(docker image inspect -f '{{.Id}}' $(IMAGE)); \
	stale=$$(docker ps --filter label=go-remote.repo --filter label=com.docker.compose.service=workspace \
		--format '{{.ID}} {{.Label "com.docker.compose.project"}}' | while read -r id project; do \
			[ "$$(docker inspect -f '{{.Image}}' "$$id")" = "$$image" ] || printf '%s ' "$$project"; \
		done); \
	if [ -n "$$stale" ]; then \
		$(LOGGER) log_warning "Still on the old image until they restart: $${stale% }"; \
		$(LOGGER) log_indent log_dim "go-remote stop <name>, then go-remote start in its repo. Stopping one ends its phone sessions."; \
	fi

# -----------------------------------------------------------------------------------------------------------
# Run targets
# -----------------------------------------------------------------------------------------------------------

.PHONY: run-detached ## Start a workspace for REPO and show its QR code (QR=false prints the link only)
run-detached: require_repo $(GO_REMOTE)
	@$(LOGGER) log_separator
	@$(GR_RUN) start "$(REPO_EXPANDED)" $(GR_QR_FLAG)
	@$(LOGGER) log_info_dim "Here: make attach REPO=$(REPO)   New QR code: make url REPO=$(REPO)   Stop: make down REPO=$(REPO)"

.PHONY: run ## Start a workspace for REPO, show its QR code, then follow its logs until Ctrl+C stops it
run: run-detached
	@$(LOGGER) log_separator
	@$(LOGGER) log_info_dim "Following logs. Ctrl+C stops the workspace (make run-detached leaves it running)."
	@trap '$(MAKE) down REPO="$(REPO_PATH)"' EXIT; \
	trap 'exit 130' INT TERM; \
	$(GR_RUN) logs "$(REPO_EXPANDED)" --tail 0

.PHONY: url ## Show a fresh QR code and pairing link for a workspace (QR=false prints the link only)
url: $(GO_REMOTE)
	@$(GR_RUN) qr $(if $(REPO_EXPANDED),"$(REPO_EXPANDED)") $(GR_QR_FLAG)

.PHONY: login ## Sign Claude Code (or AGENT=codex or AGENT=cursor) in, once for every workspace
login: $(GO_REMOTE)
	@$(GR_RUN) login $(filter claude codex cursor,$(AGENT)) $(if $(REPO_EXPANDED),"$(REPO_EXPANDED)")

.PHONY: attach ## Open the workspace's Herdr terminal UI (or tmux session, in the shell mode) here
attach: $(GO_REMOTE)
	@$(GR_RUN) attach $(if $(REPO_EXPANDED),"$(REPO_EXPANDED)")

.PHONY: logs ## Follow a workspace's logs, with its URL taken out
logs: $(GO_REMOTE)
	@$(GR_RUN) logs $(if $(REPO_EXPANDED),"$(REPO_EXPANDED)")

.PHONY: ping ## List workspaces with their repo and BitBang listener health
ping: check_docker
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "$(PROJECT_NAME) workspaces"
	@ids=$$(docker ps -aq --filter label=go-remote.repo); \
	if [ -z "$$ids" ]; then \
		$(LOGGER) log_info_dim "None. Start one with: make run REPO=~/src/my-repo"; \
		exit 0; \
	fi; \
	docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "go-remote.repo"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' $$ids | \
	while IFS='|' read -r project repo state health; do \
		echo ""; \
		$(LOGGER) log "$$project"; \
		$(LOGGER) log_indent log_dim "$$repo"; \
		case "$$state/$$health" in \
			running/healthy) $(LOGGER) log_indent log_success "Running; BitBang listener is registered" ;; \
			running/starting) $(LOGGER) log_indent log_warning "Starting" ;; \
			running/*) $(LOGGER) log_indent log_error "Running, but the listener failed its last check (the watchdog restarts it)" ;; \
			*) $(LOGGER) log_indent log_error "Not running ($$state). See make logs REPO=$$repo" ;; \
		esac; \
	done

# Stopping a workspace ends its phone sessions, so stopping all of them asks first, as go-remote stop does. It does not
# call go-remote: that would build the CLI, which needs Buildx, and stopping must work without it.
.PHONY: down ## Stop REPO's workspace, or every workspace after asking when REPO is not given (YES=1 skips the question)
down: check_docker check_project_repo
	@projects="$(if $(REPO_EXPANDED),$(PROJECT),$(WORKSPACE_PROJECTS))"; \
	if [ -z "$$projects" ]; then \
		$(LOGGER) log_info_dim "No workspaces to stop."; \
		exit 0; \
	fi; \
	if [ -z "$(REPO_EXPANDED)" ] && [ "$(YES)" != 1 ]; then \
		names=$$(printf '%s\n' $$projects | paste -sd ',' - | sed 's/,/, /g'); \
		if [ ! -t 0 ]; then \
			$(LOGGER) log_error "Not stopping $$names without asking"; \
			$(LOGGER) log_indent log_dim "Pass YES=1 to stop them, or REPO= to stop one."; \
			exit 1; \
		fi; \
		read -r -p "Stop every workspace ($$names)? Their phone sessions end. [y/N] " answer; \
		case "$$answer" in \
			[yY] | [yY][eE][sS]) ;; \
			*) $(LOGGER) log_info_dim "Nothing stopped."; exit 0 ;; \
		esac; \
	fi; \
	for project in $$projects; do \
		repo=$$(docker ps -a --filter label=com.docker.compose.project=$$project --format '{{.Label "go-remote.repo"}}' | head -n 1); \
		$(LOGGER) log_info "Stopping $$project"; \
		GR_REPO="$${repo:-/nonexistent}" $(COMPOSE) -p "$$project" down --remove-orphans; \
	done

# -----------------------------------------------------------------------------------------------------------
# Clean targets
# -----------------------------------------------------------------------------------------------------------

.PHONY: clean ## Stop every workspace; remove the images, dist/, exported CAs and .env backups (keeps logins)
clean: check_docker
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Cleaning $(PROJECT_NAME) resources"
	@$(MAKE) down REPO=
	@$(LOGGER) log_indent log_dim "Removing images $(IMAGE) and $(E2E_IMAGE)..."
	@docker image rm $(IMAGE) $(E2E_IMAGE) >/dev/null 2>&1 || true
	@$(LOGGER) log_indent log_dim "Removing dist/, exported CAs and .env backup files..."
	@rm -rf "$(COMMON_MAKEFILE_DIR)dist"
	@rm -f "$(COMMON_MAKEFILE_DIR)"certs/*.crt "$(COMMON_MAKEFILE_DIR).env.bak" "$(COMMON_MAKEFILE_DIR).env.new"
	@$(LOGGER) log_success "Clean complete. Logins and shell history stay in the $(HOME_VOLUME) volume (make clean-home removes them)."

.PHONY: clean-home ## Delete the home volume with agent logins, shell history and git config (asks first)
clean-home: check_docker
	@if ! docker volume inspect $(HOME_VOLUME) >/dev/null 2>&1; then \
		$(LOGGER) log_info_dim "Volume $(HOME_VOLUME) does not exist."; \
		exit 0; \
	fi; \
	if [ -n "$$(docker ps -aq --filter volume=$(HOME_VOLUME))" ]; then \
		$(LOGGER) log_error "Volume $(HOME_VOLUME) is in use. Stop the workspaces first: make down"; \
		exit 1; \
	fi; \
	read -r -p "Delete $(HOME_VOLUME), including agent logins and shell history? [y/N] " answer; \
	case "$$answer" in \
		[yY]) docker volume rm $(HOME_VOLUME) >/dev/null && $(LOGGER) log_success "Deleted $(HOME_VOLUME)" ;; \
		*) $(LOGGER) log_info_dim "Kept $(HOME_VOLUME)" ;; \
	esac

# -----------------------------------------------------------------------------------------------------------
# Test targets
# -----------------------------------------------------------------------------------------------------------

.PHONY: test ## Smoke-test the image in a throwaway container (needs make build; never touches .env)
test: check_docker check_image
	@USER_UID=$(USER_UID) USER_GID=$(USER_GID) $(SCRIPTS_DIR)/smoke-test.bash

.PHONY: unit ## Type-check and unit-test go-remote and go-remote-ingress, in Docker
unit: check_docker check_buildx export_ca
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Type-checking and unit-testing the TypeScript"
	@docker build --target test --no-cache-filter test \
		-f "$(COMMON_MAKEFILE_DIR)cli/Dockerfile" "$(COMMON_MAKEFILE_DIR)"
	@$(LOGGER) log_success "Unit tests passed"

.PHONY: e2e ## Phone end-to-end test through a real BitBang URL, in a throwaway workspace (REPO= tests that one)
e2e: check_docker check_buildx check_image export_ca $(GO_REMOTE)
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Building the Playwright test image"
	@docker build -q -t $(E2E_IMAGE) -f "$(COMMON_MAKEFILE_DIR)e2e/Dockerfile" "$(COMMON_MAKEFILE_DIR)" >/dev/null
	@GO_REMOTE="$(GO_REMOTE)" E2E_IMAGE=$(E2E_IMAGE) $(SCRIPTS_DIR)/e2e.bash $(if $(REPO_EXPANDED),$(PROJECT))

# -----------------------------------------------------------------------------------------------------------
# Lint and format targets
# -----------------------------------------------------------------------------------------------------------

# Check dprint is installed
check_dprint:
	@if ! dprint --version >/dev/null 2>&1; then \
		$(LOGGER) log_error "dprint is not installed. Run: brew install dprint"; \
		exit 1; \
	else \
		$(LOGGER) log_info_dim "$$(dprint --version) is installed."; \
	fi

# Check shfmt is installed
check_shfmt:
	@if ! shfmt --version >/dev/null 2>&1; then \
		$(LOGGER) log_error "shfmt is not installed. Run: brew install shfmt"; \
		exit 1; \
	else \
		$(LOGGER) log_info_dim "shfmt $$(shfmt --version) is installed."; \
	fi

# Check mbake is installed
check_mbake:
	@if ! mbake --version >/dev/null 2>&1; then \
		$(LOGGER) log_error "mbake is not installed. Run: uv tool install mbake"; \
		exit 1; \
	else \
		$(LOGGER) log_info_dim "$$(mbake --version) is installed."; \
	fi

# Check shellcheck is installed
check_shellcheck:
	@if ! shellcheck --version >/dev/null 2>&1; then \
		$(LOGGER) log_error "shellcheck is not installed. Run: brew install shellcheck"; \
		exit 1; \
	else \
		$(LOGGER) log_info_dim "shellcheck $$(shellcheck --version | awk '/^version:/ {print $$2}') is installed."; \
	fi

# Check dprint and its Exec-plugin formatter dependencies
check_formatters:
	@$(MAKE) check_dprint
	@$(MAKE) check_shfmt
	@$(MAKE) check_mbake

.PHONY: format ## Format all supported files
format:
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Checking formatting dependencies"
	@$(MAKE) check_formatters
	@$(LOGGER) log_separator
	@FORMAT_FILE_COUNT=$$(cd "$(COMMON_MAKEFILE_DIR)" && dprint file-paths --config dprint.json | wc -l | tr -d '[:space:]'); \
	$(LOGGER) log_info "Formatting files with dprint ($$FORMAT_FILE_COUNT files)"
	@cd "$(COMMON_MAKEFILE_DIR)" && dprint fmt --config dprint.json --incremental=false

.PHONY: format-check ## Verify formatting without modifying files
format-check:
	@$(LOGGER) log_separator
	@$(LOGGER) log_info "Checking formatting dependencies"
	@$(MAKE) check_formatters
	@$(LOGGER) log_separator
	@FORMAT_FILE_COUNT=$$(cd "$(COMMON_MAKEFILE_DIR)" && dprint file-paths --config dprint.json | wc -l | tr -d '[:space:]'); \
	$(LOGGER) log_info "Checking formatting with dprint ($$FORMAT_FILE_COUNT files)"
	@cd "$(COMMON_MAKEFILE_DIR)" && dprint check --config dprint.json --incremental=false

.PHONY: lint ## Check formatting, run shellcheck, and validate docker-compose.yml
lint: format-check
	@echo ""
	@$(LOGGER) log_info "Running linters"
	@$(MAKE) check_shellcheck
	@cd "$(COMMON_MAKEFILE_DIR)" && shellcheck -x -S warning scripts/*.bash docker/*.bash
	@$(LOGGER) log_indent log_success "shellcheck passed"
	@GR_REPO=/nonexistent/go-remote-lint $(COMPOSE) --env-file "$(COMMON_MAKEFILE_DIR).env.example" config -q
	@$(LOGGER) log_indent log_success "docker-compose.yml is valid"
	@$(LOGGER) log_success "All checks passed"

# -----------------------------------------------------------------------------------------------------------
# Version
#
# VERSION is the single source. Any other file that comes to carry the version goes in bump-version.bash.
# -----------------------------------------------------------------------------------------------------------

.PHONY: bump-version ## Set VERSION (make bump-version X.Y.Z) and sync it into package.json
bump-version:
	@$(LOGGER) log_info "Syncing the version"
	@"$(SCRIPTS_DIR)/bump-version.bash" $(if $(BUMP_VERSION),"$(BUMP_VERSION)")
	@$(LOGGER) log_success "The version is $$(cat "$(COMMON_MAKEFILE_DIR)VERSION")"