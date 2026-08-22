# Terraform workflow shortcuts. Run from terraform/.
ENV ?= prod
DIR := envs/$(ENV)
PLATFORM_DIR := envs/prod-platform

.PHONY: help fmt validate aws-strings test alloy-validate lgtm-validate mirror init plan apply destroy output verify clean bootstrap \
        platform-init platform-plan platform-apply platform-destroy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

fmt: ## Rewrite all files to canonical format
	terraform fmt -recursive

validate: ## Validate every root module (no backend, no credentials needed)
	cd $(DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd $(PLATFORM_DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd bootstrap && terraform init -backend=false -input=false >/dev/null && terraform validate
	@$(MAKE) --no-print-directory aws-strings

aws-strings: ## Check descriptions and tag values against AWS API character sets
	@../scripts/check-aws-string-constraints.sh

test: ## Run terraform test for every module that has a tests/ directory
	@for m in modules/*/; do \
	  if [ -d "$$m/tests" ]; then \
	    printf '\033[36m==> %s\033[0m\n' "$$m"; \
	    ( cd "$$m" && terraform init -backend=false -input=false >/dev/null && terraform test ) || exit 1; \
	  fi; \
	done

alloy-validate: ## Render every .alloy template and validate it with the real Alloy binary (needs docker)
	../scripts/validate-alloy-configs.sh

lgtm-validate: ## Render the LGTM Helm values and template them against the real charts
	../scripts/validate-lgtm-values.sh

mirror: ## Mirror third-party charts and images into ECR (ADR 0005). Needs AWS credentials.
	../scripts/mirror-images.sh

bootstrap: ## Create the S3 state bucket (run once per account)
	cd bootstrap && terraform init && terraform apply

init: ## Initialise the environment against the S3 backend
	cd $(DIR) && terraform init -backend-config=backend.hcl -reconfigure

plan: ## Plan the environment
	cd $(DIR) && terraform plan -out=tfplan

apply: ## Apply the saved plan
	cd $(DIR) && terraform apply tfplan

destroy: ## Destroy the environment (do this between test runs — budget!). Run platform-destroy FIRST.
	cd $(DIR) && terraform destroy

# --- Stage 2: the Kubernetes layer (ADR 0008) ---------------------------------
# Apply order is load-bearing: envs/prod, then `make mirror`, then these.

platform-init: ## Initialise the Kubernetes layer against the S3 backend
	cd $(PLATFORM_DIR) && terraform init -backend-config=backend.hcl -reconfigure

platform-plan: ## Plan the Kubernetes layer (envs/prod must be applied and charts mirrored first)
	cd $(PLATFORM_DIR) && terraform plan -out=tfplan

platform-apply: ## Apply the Kubernetes layer
	cd $(PLATFORM_DIR) && terraform apply tfplan

platform-destroy: ## Destroy the Kubernetes layer. MUST run before `make destroy`.
	cd $(PLATFORM_DIR) && terraform destroy

verify: ## Print the end-to-end verification commands for the telemetry pipeline
	@cd $(PLATFORM_DIR) && terraform output -json verification | jq -r 'to_entries|sort_by(.key)|.[]|"\(.key):\n  \(.value)\n"' 

output: ## Print the machine-readable platform summary
	cd $(DIR) && terraform output -json platform | jq .

clean: ## Remove local provider caches and saved plans
	find . -type d -name '.terraform' -prune -exec rm -rf {} +
	find . -type f -name 'tfplan' -delete
