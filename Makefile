SCRIPTS := account-baseline.sh scripts/deploy.sh

.PHONY: help test lint fmt validate tflint cfn-lint checkov shellcheck demo

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

test: ## Script tests (fake AWS CLI) and terraform test (mocked provider)
	python3 -m pytest -q tests
	@terraform init -backend=false -input=false >/dev/null
	terraform test

lint: validate tflint cfn-lint checkov shellcheck ## Every linter CI runs

fmt: ## Format the Terraform files
	terraform fmt -recursive

validate: ## terraform fmt -check, then validate the module and examples
	terraform fmt -check -recursive
	@for d in . examples/*/; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && \
	  terraform -chdir=$$d validate -no-color >/dev/null && echo "valid: $$d" || exit 1; \
	done

tflint: ## tflint with the AWS ruleset
	@tflint --init >/dev/null
	tflint --recursive --config "$(CURDIR)/.tflint.hcl"

cfn-lint: ## Lint the CloudFormation template
	cfn-lint cloudformation/*.yaml

checkov: ## Static security scan of Terraform, CloudFormation and CI
	checkov --config-file .checkov.yaml -d . --skip-download

shellcheck: ## Lint the shell scripts
	shellcheck $(SCRIPTS)

demo: ## Run the script against the fake AWS CLI from the tests (no AWS account needed)
	@PATH="$(CURDIR)/tests/fake-aws:$$PATH" ./account-baseline.sh --profile demo \
	  --regions us-east-1,us-west-2 --delete-default-vpcs
