# Stan's Robot Shop on EKS
#
# Convenience targets for the things you would otherwise type repeatedly.
# `make help` lists them.
#
# Nothing here is required -- every target is a thin wrapper around a
# command you could run by hand. The point is that the verification set is
# written down in one place, so a change to the chart is checked the same
# way every time rather than by whoever remembers.

SHELL := /bin/bash
.DEFAULT_GOAL := help

CHART      := EKS/helm
RELEASE    := robot-shop
NAMESPACE  := robot-shop
ECR_REPO   ?= robot-shop
TAG        ?= 2.1.1
ACCOUNT    ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
REGION     ?= us-east-1
ECR_PREFIX := $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com/$(ECR_REPO)
CLUSTER    ?= wisdom-eks
# image.repo is what the chart appends /rs-<service> to.
IMAGE_REPO ?= $(ECR_PREFIX)

# The ten services. mysql publishes as rs-mysql-db and mongo as rs-mongodb,
# so this is not derivable from the directory names.
SERVICES := cart catalogue dispatch mongodb mysql-db payment ratings shipping user web
# ratings is excluded from build: php:7.4-apache can no longer install
# packages from its own Debian archive. See docs/building.md and `make pull`.
BUILDABLE := cart catalogue dispatch mongodb mysql-db payment shipping user web

.PHONY: help
help: ## Show this help
	@echo "Stan's Robot Shop on EKS"
	@echo ""
	@echo "  registry: $(ECR_PREFIX)"
	@echo "  cluster:  $(CLUSTER)   region: $(REGION)   tag: $(TAG)"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- verify

.PHONY: verify
verify: lint render-check defaults links ## Everything CI checks, run locally

.PHONY: lint
lint: ## helm lint the chart
	helm lint $(CHART)

.PHONY: render
render: ## Print the rendered manifests at default values
	@helm template $(RELEASE) $(CHART) --namespace $(NAMESPACE)

.PHONY: render-check
render-check: ## Render every documented value combination and parse each
	@bash -c 'set -euo pipefail; \
	  render() { n="$$1"; shift; \
	    out=/tmp/rc-$$n.yaml; \
	    helm template $(RELEASE) $(CHART) --namespace $(NAMESPACE) "$$@" > "$$out" || { echo "  FAIL $$n"; exit 1; }; \
	    c=$$(python3 -c "import yaml,sys;print(len([d for d in yaml.safe_load_all(open(sys.argv[1])) if d]))" "$$out"); \
	    printf "  %-10s %s resources\n" "$$n" "$$c"; }; \
	  render defaults; \
	  render ecr       --set image.repo=$(IMAGE_REPO) --set image.version=$(TAG); \
	  render nodeport  --set nodeport=true; \
	  render openshift --set openshift=true --set ocCreateRoute=true; \
	  render eum       --set eum.key=abc123; \
	  render lbsvc     --set web.serviceType=LoadBalancer; \
	  render pullsec   --set "imagePullSecrets[0].name=regcred"; \
	  render commonlbl --set commonLabels.env=prod --set commonAnnotations.owner=platform; \
	  render pdb       --set podDisruptionBudgets[0].workload=web --set podDisruptionBudgets[0].maxUnavailable=1; \
	  render spread    --set mysql.topologySpreadConstraints[0].maxSkew=1 \
	                    --set mysql.topologySpreadConstraints[0].topologyKey=kubernetes.io/hostname \
	                    --set mysql.topologySpreadConstraints[0].whenUnsatisfiable=ScheduleAnyway; \
	  render optprobe  --set "redis.readinessProbe.exec.command[0]=redis-cli"; \
	  echo "  all render paths parse"'

.PHONY: defaults
defaults: ## Assert the defaults the docs claim
	@helm template $(RELEASE) $(CHART) --namespace $(NAMESPACE) | ./scripts/assert-defaults.py

.PHONY: links
links: ## Check relative links in the markdown resolve
	@./scripts/check-links.py

.PHONY: schema-check
schema-check: ## Confirm the schema rejects the inputs it should
	@bash -c 'set -euo pipefail; \
	  expect_fail() { d="$$1"; shift; \
	    if helm template $(RELEASE) $(CHART) --namespace $(NAMESPACE) "$$@" >/dev/null 2>&1; then \
	      echo "  FAIL schema accepted: $$d"; exit 1; \
	    else echo "  rejected: $$d"; fi; }; \
	  expect_fail "misspelled top-level key" --set msyql.resources.requests.memory=700Mi; \
	  expect_fail "misspelled nested key"    --set web.serviceTyp=LoadBalancer; \
	  expect_fail "bad serviceType"          --set web.serviceType=Foo; \
	  expect_fail "bad probe port"           --set cart.readinessProbe.httpGet.port=notanumber'

.PHONY: secrets
secrets: ## Fail if a credential-looking value has been committed
	@bash -c 'if git grep -nE "(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gho_[A-Za-z0-9]{20,})" -- . 2>/dev/null; then \
	  echo "  possible secret committed"; exit 1; else echo "  no credentials found"; fi'

# ---------------------------------------------------------------- images

.PHONY: login
login: ## Authenticate docker to this account's ECR
	aws ecr get-login-password --region $(REGION) \
	  | docker login --username AWS --password-stdin $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com

.PHONY: build
build: ## Build the nine buildable services
	@for s in $(BUILDABLE); do echo "==> build $$s"; \
	  docker build -t $(ECR_PREFIX)/rs-$$s:$(TAG) ./$$s || exit 1; done

.PHONY: push
push: login ## Create the repositories, then build and push all nine
	@for s in $(BUILDABLE); do \
	  aws ecr describe-repositories --repository-names $(ECR_REPO)/rs-$$s --region $(REGION) >/dev/null 2>&1 \
	    || aws ecr create-repository --repository-name $(ECR_REPO)/rs-$$s --region $(REGION) >/dev/null; \
	done; \
	$(MAKE) build; \
	for s in $(BUILDABLE); do echo "==> push rs-$$s:$(TAG)"; \
	  docker push $(ECR_PREFIX)/rs-$$s:$(TAG) || exit 1; done

.PHONY: pull
pull: ## Get the tenth service from its published image
	@echo "ratings cannot be built from source: php:7.4-apache apt 404."
	@echo "See docs/building.md for the options. Re-tagging the published image:"
	docker pull robotshop/rs-ratings:$(TAG)
	docker tag  robotshop/rs-ratings:$(TAG) $(ECR_PREFIX)/rs-ratings:$(TAG)
	docker push $(ECR_PREFIX)/rs-ratings:$(TAG)

# ---------------------------------------------------------------- deploy

.PHONY: deploy
deploy: ## Install or upgrade the release against ECR
	helm upgrade --install $(RELEASE) $(CHART) --namespace $(NAMESPACE) --create-namespace \
	  --set image.repo=$(IMAGE_REPO) --set image.version=$(TAG)

.PHONY: ingress
ingress: ## Apply the ALB ingress and wait for an address
	kubectl apply -f $(CHART)/ingress.yaml
	kubectl get ingress -n $(NAMESPACE) -w

.PHONY: status
status: ## Workloads, ingress address and the storefront's response
	@echo "== nodes ==";    kubectl get nodes -o wide
	@echo "== workloads =="; kubectl get deploy,sts -n $(NAMESPACE)
	@echo "== pods ==";      kubectl get pods -n $(NAMESPACE)
	@echo "== ingress ==";   kubectl get ingress -n $(NAMESPACE)
	@addr=$$(kubectl get ingress -n $(NAMESPACE) -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	  if [ -n "$$addr" ]; then echo "== storefront =="; \
	    curl -s -o /dev/null -w "  http://$$addr/ -> HTTP %{http_code}\n" --max-time 20 "http://$$addr/"; \
	  else echo "== storefront == no ingress address yet"; fi

# ---------------------------------------------------------------- teardown

.PHONY: uninstall
uninstall: ## Remove the release, keep the cluster
	helm uninstall $(RELEASE) -n $(NAMESPACE) || true

.PHONY: teardown
teardown: ## Delete the cluster, then the ECR repositories
	@echo "Deleting the cluster BEFORE removing the ALB controller."
	@echo "Orphaning the load balancer makes 'eksctl delete cluster' time out."
	eksctl delete cluster --name $(CLUSTER) --region $(REGION) --wait
	@echo ""
	@echo "Now the ECR repositories, which a cluster delete does not touch:"
	@for s in $(SERVICES); do \
	  aws ecr delete-repository --repository-name $(ECR_REPO)/rs-$$s --region $(REGION) --force 2>/dev/null \
	    && echo "  deleted $(ECR_REPO)/rs-$$s"; \
	done
