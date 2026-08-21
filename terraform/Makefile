# Terraform workflow shortcuts. Run from terraform/.
ENV ?= prod
DIR := envs/$(ENV)

.PHONY: help fmt validate test alloy-validate mirror init plan apply destroy output clean bootstrap

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

fmt: ## Rewrite all files to canonical format
	terraform fmt -recursive

validate: ## Validate every root module (no backend, no credentials needed)
	cd $(DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd bootstrap && terraform init -backend=false -input=false >/dev/null && terraform validate

test: ## Run terraform test for every module that has a tests/ directory
	@for m in modules/*/; do \
	  if [ -d "$$m/tests" ]; then \
	    printf '\033[36m==> %s\033[0m\n' "$$m"; \
	    ( cd "$$m" && terraform init -backend=false -input=false >/dev/null && terraform test ) || exit 1; \
	  fi; \
	done

alloy-validate: ## Render every .alloy template and validate it with the real Alloy binary (needs docker)
	../scripts/validate-alloy-configs.sh

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

destroy: ## Destroy the environment (do this between test runs — budget!)
	cd $(DIR) && terraform destroy

output: ## Print the machine-readable platform summary
	cd $(DIR) && terraform output -json platform | jq .

clean: ## Remove local provider caches and saved plans
	find . -type d -name '.terraform' -prune -exec rm -rf {} +
	find . -type f -name 'tfplan' -delete
