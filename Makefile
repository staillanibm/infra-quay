# ──────────────────────────────────────────────────────────────────────────────
# Quay registry management — Red Hat Quay Operator / OpenShift
# Requires: oc configured against the target cluster
# ──────────────────────────────────────────────────────────────────────────────

NAMESPACE   := quay
REGISTRY_CR := quay
SCRIPT_DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

OC := oc -n $(NAMESPACE)

# Overridable for smoke-test
QUAY_USER ?=
QUAY_PASS ?=
QUAY_ORG  ?= smoketest

.DEFAULT_GOAL := help
.PHONY: help deploy smoke-test teardown status fix-noobaa fix-noobaa-backingstore

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@printf "Usage: make <target> [VARIABLE=value ...]\n\n"
	@printf "Cluster lifecycle:\n"
	@printf "  deploy       Install Quay operator + registry instance\n"
	@printf "  smoke-test   Push and pull a test image (requires QUAY_USER= QUAY_PASS=)\n"
	@printf "  teardown     Delete the registry, operator, and namespace\n"
	@printf "  status       Show current state of the registry\n"
	@printf "  fix-noobaa               Raise NooBaa endpoint resource limits (fixes OOM on large image pushes)\n"
	@printf "  fix-noobaa-backingstore  Raise NooBaa PV-pool backing-store resource limits (fixes OOM on large blob writes)\n\n"
	@printf "Variables:\n"
	@printf "  QUAY_USER    Robot account name  (org+robotname)\n"
	@printf "  QUAY_PASS    Robot account token\n"
	@printf "  QUAY_ORG     Organisation for the test image (default: smoketest)\n\n"

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

deploy:
	@echo "==> [1/4] Creating namespace '$(NAMESPACE)'"
	@oc apply -f $(SCRIPT_DIR)namespace.yaml

	@echo "==> [2/4] Installing Quay operator (OperatorGroup + Subscription)"
	@oc apply -f $(SCRIPT_DIR)operator.yaml

	@echo "==> [3/4] Waiting for quay-operator CSV to reach Succeeded"
	@until $(OC) get csv -o json 2>/dev/null \
	    | jq -e '.items[] | select(.metadata.name | startswith("quay-operator")) | select(.status.phase == "Succeeded")' \
	    > /dev/null 2>&1; do \
	  printf "."; sleep 5; \
	done; echo " ready"

	@echo "==> [4/4] Deploying QuayRegistry"
	@oc apply -f $(SCRIPT_DIR)registry.yaml

	@echo "==> Waiting for QuayRegistry to become Available (~5-10 min)"
	@until $(OC) get quayregistry $(REGISTRY_CR) \
	    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
	    2>/dev/null | grep -q True; do \
	  printf "."; sleep 10; \
	done; echo " ready"

	@echo ""
	@$(MAKE) --no-print-directory status

smoke-test:
	@test -n "$(QUAY_USER)" || { echo "ERROR: QUAY_USER is required"; exit 1; }
	@test -n "$(QUAY_PASS)" || { echo "ERROR: QUAY_PASS is required"; exit 1; }

	$(eval QUAY_HOST := $(shell $(OC) get quayregistry $(REGISTRY_CR) \
	  -o jsonpath='{.status.registryEndpoint}' | sed 's|https://||'))
	@test -n "$(QUAY_HOST)" || { echo "ERROR: registry endpoint not available yet"; exit 1; }
	@echo "==> Registry: $(QUAY_HOST)"

	@echo "==> Storing smoke credentials in secret/quay-smoke-credentials"
	@$(OC) create secret generic quay-smoke-credentials \
	  --from-literal=host=$(QUAY_HOST) \
	  --from-literal=org=$(QUAY_ORG) \
	  --from-literal=username=$(QUAY_USER) \
	  --from-literal=password=$(QUAY_PASS) \
	  --dry-run=client -o yaml | $(OC) apply -f -

	@echo "==> Running smoke-test Job"
	@$(OC) delete job quay-smoke-test --ignore-not-found > /dev/null
	@oc apply -f $(SCRIPT_DIR)quay-smoke-test.yaml

	@until $(OC) get pod -l job-name=quay-smoke-test \
	  -o jsonpath='{.items[0].status.phase}' 2>/dev/null \
	  | grep -qE 'Succeeded|Failed'; do sleep 5; done

	@$(OC) logs -l job-name=quay-smoke-test --tail=20
	@$(OC) get pod -l job-name=quay-smoke-test \
	  -o jsonpath='{.items[0].status.phase}' | grep -q Succeeded \
	  && echo "==> Smoke test PASSED" \
	  || { echo "==> Smoke test FAILED"; exit 1; }

teardown:
	@echo "==> Deleting QuayRegistry"
	@oc delete -f $(SCRIPT_DIR)registry.yaml --ignore-not-found
	@echo "==> Uninstalling Quay operator"
	@oc delete -f $(SCRIPT_DIR)operator.yaml --ignore-not-found
	@echo "==> Deleting namespace '$(NAMESPACE)'"
	@oc delete -f $(SCRIPT_DIR)namespace.yaml --ignore-not-found
	@echo "==> Teardown complete"

status:
	@$(OC) get quayregistry $(REGISTRY_CR) 2>/dev/null || echo "(not found)"
	@echo ""
	@$(OC) get pods 2>/dev/null || true
	@echo ""
	@$(OC) get route -l quay-operator/quayregistry=$(REGISTRY_CR) 2>/dev/null || true

# ── Known-issue fixes ─────────────────────────────────────────────────────────

fix-noobaa:
	@echo "==> Raising NooBaa endpoint resource limits via StorageCluster (openshift-storage)"
	@echo "    (patching the NooBaa CR directly does not stick: ocs-operator resyncs"
	@echo "     NooBaa.spec.endpoints from StorageCluster.spec.multiCloudGateway on"
	@echo "     every reconcile and reverts direct edits within seconds. The patch"
	@echo "     also carries minCount/maxCount — omitting them zeroes out the"
	@echo "     NooBaa CR's endpoint counts and wedges the noobaa-operator reconcile"
	@echo "     loop with 'Invalid endpoint min count', which blocks the Deployment"
	@echo "     update entirely.)"
	@oc patch storagecluster ocs-external-storagecluster -n openshift-storage \
	  --type merge --patch-file $(SCRIPT_DIR)noobaa-endpoint-resources.yaml
	@echo "==> Waiting for the fix to settle (StorageCluster -> NooBaa CR -> Deployment -> pod"
	@echo "    is a multi-hop async sync with a transient error window in between; polling"
	@echo "    until the Deployment carries the new limits AND the pod is Ready AND no fresh"
	@echo "    reconcile error follows, instead of trusting a single point-in-time check)"
	@ok=""; \
	NB="oc -n openshift-storage"; \
	for i in $$(seq 1 24); do \
	  RES=$$($$NB get deployment noobaa-endpoint -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null); \
	  READY=$$($$NB get deployment noobaa-endpoint -o jsonpath='{.status.readyReplicas}' 2>/dev/null); \
	  DESIRED=$$($$NB get deployment noobaa-endpoint -o jsonpath='{.spec.replicas}' 2>/dev/null); \
	  if [ "$$RES" = "8Gi" ] && [ -n "$$READY" ] && [ "$$READY" = "$$DESIRED" ]; then \
	    sleep 5; \
	    ERR=$$($$NB logs deployment/noobaa-operator --since=10s 2>/dev/null | grep -i "Persistent Error" | tail -1); \
	    if [ -z "$$ERR" ]; then ok="yes"; break; fi; \
	    echo "    (memory limit is 8Gi but a fresh reconcile error just showed up — retrying)"; \
	  fi; \
	  printf "."; sleep 5; \
	done; echo ""; \
	if [ "$$ok" = "yes" ]; then \
	  echo "==> OK: noobaa-endpoint is at 8Gi memory limit, Ready, no active reconcile error"; \
	  $$NB get pod -l noobaa-s3=noobaa; \
	else \
	  echo "==> FAILED: noobaa-endpoint did not settle at the new limits within 2 minutes"; \
	  echo "    Current deployment resources:"; \
	  $$NB get deployment noobaa-endpoint -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo; \
	  echo "    Recent noobaa-operator errors:"; \
	  $$NB logs deployment/noobaa-operator --since=2m 2>/dev/null | grep -i "Persistent Error\|Temporary Error" | tail -10; \
	  exit 1; \
	fi

fix-noobaa-backingstore:
	@echo "==> Raising NooBaa PV-pool backing-store resource limits + redundancy (openshift-storage)"
	@echo "    (the endpoint fix alone is not enough: large blob writes go through the"
	@echo "     backing-store pod(s) noobaa-default-backing-store-noobaa-pod-*, which ODF"
	@echo "     sizes at 400Mi by default and which OOMKills mid-transfer, surfacing as"
	@echo "     an unrelated-looking podman/skopeo error: 'writing blob: uploading layer"
	@echo "     chunked: blob upload invalid'. With numVolumes: 1 (the ODF default) a"
	@echo "     single clean pod restart mid-push loses the transfer the same way, even"
	@echo "     without an OOM — numVolumes: 2 gives the pool redundancy against that.)"
	@oc patch backingstore noobaa-default-backing-store -n openshift-storage \
	  --type merge --patch-file $(SCRIPT_DIR)noobaa-backingstore-resources.yaml
	@echo "==> Waiting for both backing-store pods to roll with new limits and become Ready"
	@ok=""; \
	NB="oc -n openshift-storage"; \
	for i in $$(seq 1 36); do \
	  NAMES=$$($$NB get pod -l pool=noobaa-default-backing-store -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); \
	  COUNT=$$(echo $$NAMES | wc -w | tr -d ' '); \
	  if [ "$$COUNT" = "2" ]; then \
	    all_ok="yes"; \
	    for p in $$NAMES; do \
	      RES=$$($$NB get pod "$$p" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null); \
	      READY=$$($$NB get pod "$$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null); \
	      [ "$$RES" = "4Gi" ] && [ "$$READY" = "true" ] || all_ok="no"; \
	    done; \
	    if [ "$$all_ok" = "yes" ]; then ok="yes"; break; fi; \
	  fi; \
	  printf "."; sleep 5; \
	done; echo ""; \
	if [ "$$ok" = "yes" ]; then \
	  echo "==> OK: 2 backing-store pods at 4Gi memory limit, both Ready"; \
	  $$NB get pod -l pool=noobaa-default-backing-store; \
	else \
	  echo "==> FAILED: backing-store pool did not settle at 2 Ready pods with the new limits within 3 minutes"; \
	  $$NB get pod -l pool=noobaa-default-backing-store -o wide 2>/dev/null; \
	  echo "    Check PVC provisioning if only 1 pod ever appears:"; \
	  $$NB get pvc -l pool=noobaa-default-backing-store 2>/dev/null; \
	  exit 1; \
	fi
