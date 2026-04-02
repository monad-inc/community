#!/usr/bin/env bash
#
# Monad Helm Chart Pre-Flight Check
# Validates that the target Kubernetes environment has everything needed
# before running helm install/upgrade.
#
# Usage:
#   ./preflight-check.sh [OPTIONS]
#
# Options:
#   -n, --namespace NAMESPACE       Target namespace (default: monad)
#   -f, --values VALUES_FILE        Path to values-override.yaml file
#   -v, --verbose                   Show detailed output for each check
#   --install-prereqs               Install missing prerequisites (operators, CRDs, namespace)
#   -y, --yes                       Skip interactive confirmations
#   -h, --help                      Show this help message
#
set -uo pipefail

# --- Defaults ---
NAMESPACE="monad"
VALUES_FILE=""
VERBOSE=false
INSTALL_PREREQS=false
SKIP_CONFIRM=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Counters ---
PASS=0
FAIL=0
WARN=0
INSTALLED=0

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -f|--values) VALUES_FILE="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=true; shift ;;
    --install-prereqs) INSTALL_PREREQS=true; shift ;;
    -y|--yes) SKIP_CONFIRM=true; shift ;;
    -h|--help)
      sed -n '2,/^$/s/^# \?//p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Helpers ---
pass()    { ((PASS++));      printf "  ${GREEN}PASS${NC}  %s\n" "$1"; }
fail()    { ((FAIL++));      printf "  ${RED}FAIL${NC}  %s\n" "$1"; }
warn()    { ((WARN++));      printf "  ${YELLOW}WARN${NC}  %s\n" "$1"; }
fixed()   { ((INSTALLED++)); printf "  ${GREEN}FIXED${NC} %s\n" "$1"; }
info()    { if $VERBOSE; then printf "        %s\n" "$1"; fi; }
section() { printf "\n${BLUE}=== %s ===${NC}\n" "$1"; }

confirm() {
  if $SKIP_CONFIRM; then return 0; fi
  printf "  ${YELLOW}?${NC}     %s [y/N] " "$1"
  read -r answer
  [[ "$answer" =~ ^[Yy] ]]
}

print_summary() {
  printf "\n${BLUE}=== Summary ===${NC}\n"
  local parts="${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${WARN} warnings${NC}"
  if [ "$INSTALLED" -gt 0 ]; then
    parts="${parts}  ${GREEN}${INSTALLED} installed${NC}"
  fi
  printf "  %b\n\n" "$parts"
  if [ "$FAIL" -gt 0 ]; then
    printf "${RED}Pre-flight check failed.${NC} Address the failures above before deploying.\n"
  elif [ "$WARN" -gt 0 ]; then
    printf "${YELLOW}Pre-flight check passed with warnings.${NC} Review warnings before deploying.\n"
  else
    printf "${GREEN}All pre-flight checks passed.${NC} Ready to deploy.\n"
  fi
}

version_gte() {
  # Returns 0 if $1 >= $2 (semver-ish comparison)
  printf '%s\n%s' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -C
}

# --- Parse values file for config detection ---
VALUES_ROUTING_ENABLED=false
VALUES_INGRESS_ENABLED=false
VALUES_CNPG_ENABLED=true
VALUES_HOSTNAME="chart-example.local"
VALUES_IMAGE_REPO=""

if [ -n "$VALUES_FILE" ] && [ -f "$VALUES_FILE" ]; then
  # Detect hostname
  CUSTOM_HOST=$(grep -A1 '^hostnames:' "$VALUES_FILE" 2>/dev/null | tail -1 | sed 's/.*- //' | tr -d ' "' || true)
  if [ -n "$CUSTOM_HOST" ]; then
    VALUES_HOSTNAME="$CUSTOM_HOST"
  fi
  # Detect routing mode
  if grep -qE '^\s*routing:\s*$' "$VALUES_FILE" 2>/dev/null; then
    if grep -A1 'routing:' "$VALUES_FILE" 2>/dev/null | grep -qE 'enabled:\s*true'; then
      VALUES_ROUTING_ENABLED=true
    fi
  fi
  # Detect ingress mode
  if grep -A1 'ingress:' "$VALUES_FILE" 2>/dev/null | grep -qE 'enabled:\s*true'; then
    VALUES_INGRESS_ENABLED=true
  fi
  # Detect CNPG disabled (external Postgres)
  if grep -A2 'cnpg:' "$VALUES_FILE" 2>/dev/null | grep -qE 'enabled:\s*false'; then
    VALUES_CNPG_ENABLED=false
  fi
  # Detect image repository
  VALUES_IMAGE_REPO=$(grep -A1 '^image:' "$VALUES_FILE" 2>/dev/null | grep 'repository:' | awk '{print $2}' | tr -d '"' || true)
fi

# ============================================================
section "CLI Tools"
# ============================================================

# Helm
if command -v helm &>/dev/null; then
  HELM_VER=$(helm version --short 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$HELM_VER" ] && version_gte "$HELM_VER" "3.0.0"; then
    pass "helm installed (v${HELM_VER})"
  else
    fail "helm version ${HELM_VER:-unknown} — Helm 3.x required"
  fi
else
  fail "helm is not installed"
fi

# kubectl
if command -v kubectl &>/dev/null; then
  KUBECTL_VER=$(kubectl version --client 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  pass "kubectl installed (v${KUBECTL_VER})"
else
  fail "kubectl is not installed"
fi

# ============================================================
section "Helm Registry Access"
# ============================================================

# Detect which registry is being used
if [ -n "$VALUES_IMAGE_REPO" ]; then
  REGISTRY_HOST=$(echo "$VALUES_IMAGE_REPO" | cut -d'/' -f1)
else
  REGISTRY_HOST="registry-1.docker.io"
fi

# Check helm registry login by looking at docker/helm config files
HELM_LOGGED_IN=false
if [ -f "$HOME/.config/helm/registry/config.json" ] && grep -q "$REGISTRY_HOST" "$HOME/.config/helm/registry/config.json" 2>/dev/null; then
  HELM_LOGGED_IN=true
elif [ -f "$HOME/.docker/config.json" ] && grep -q "$REGISTRY_HOST" "$HOME/.docker/config.json" 2>/dev/null; then
  HELM_LOGGED_IN=true
fi

if $HELM_LOGGED_IN; then
  pass "helm registry credentials found for ${REGISTRY_HOST}"
else
  warn "no helm registry credentials for ${REGISTRY_HOST} — run: helm registry login ${REGISTRY_HOST}"
  info "run: helm registry login ${REGISTRY_HOST} --username monadinc"
fi

# ============================================================
section "Cluster Connectivity"
# ============================================================

CLUSTER_REACHABLE=false
if kubectl cluster-info &>/dev/null; then
  CLUSTER_REACHABLE=true
  CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")

  # --- Cluster confirmation ---
  printf "\n"
  printf "  ${BOLD}Current cluster context:${NC}\n"
  printf "    ${BOLD}%s${NC}\n" "$CONTEXT"
  printf "\n"

  if ! $SKIP_CONFIRM; then
    printf "  ${YELLOW}?${NC}     Is this the correct cluster? [y/N] "
    read -r answer
    if ! [[ "$answer" =~ ^[Yy] ]]; then
      printf "\n${RED}Aborted.${NC} Switch to the correct cluster with: kubectl config use-context <context>\n"
      printf "Available contexts:\n"
      kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /'
      exit 1
    fi
  fi

  pass "kubectl can reach cluster (context: ${CONTEXT})"

  # Kubernetes version
  K8S_VER=$(kubectl version 2>&1 | grep -i 'server' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$K8S_VER" ]; then
    if version_gte "$K8S_VER" "1.19.0"; then
      pass "kubernetes server version ${K8S_VER} (>= 1.19)"
    elif version_gte "$K8S_VER" "1.14.0"; then
      warn "kubernetes server version ${K8S_VER} — 1.19+ recommended for full networking API support"
    else
      fail "kubernetes server version ${K8S_VER} — minimum 1.14 required"
    fi
  fi
else
  fail "kubectl cannot reach cluster — check kubeconfig and context"
  printf "\n${YELLOW}Skipping remaining cluster checks (no connectivity).${NC}\n"
fi

if ! $CLUSTER_REACHABLE; then
  print_summary
  exit 1
fi

# ============================================================
section "Namespace"
# ============================================================

if kubectl get namespace "$NAMESPACE" &>/dev/null; then
  pass "namespace '${NAMESPACE}' exists"
else
  if confirm "Namespace '${NAMESPACE}' does not exist. Create it?"; then
    if kubectl create namespace "$NAMESPACE" 2>/dev/null; then
      fixed "created namespace '${NAMESPACE}'"
    else
      fail "failed to create namespace '${NAMESPACE}'"
    fi
  else
    fail "namespace '${NAMESPACE}' does not exist"
  fi
fi

# ============================================================
section "RBAC Permissions"
# ============================================================

if kubectl auth can-i create deployments -n "$NAMESPACE" &>/dev/null; then
  pass "can create deployments in ${NAMESPACE}"
else
  fail "cannot create deployments in ${NAMESPACE}"
fi

if kubectl auth can-i create secrets -n "$NAMESPACE" &>/dev/null; then
  pass "can create secrets in ${NAMESPACE}"
else
  fail "cannot create secrets in ${NAMESPACE}"
fi

if kubectl auth can-i create customresourcedefinitions &>/dev/null; then
  pass "can create CRDs (cluster-scoped)"
else
  fail "cannot create CRDs — required for Pipeline, PipelineNode, Organization resources"
fi

if kubectl auth can-i create clusterroles &>/dev/null; then
  pass "can create ClusterRoles"
else
  fail "cannot create ClusterRoles — required by pipeline operator"
fi

# ============================================================
section "Required Operators / CRDs"
# ============================================================

# CloudNativePG operator
CNPG_REPO="https://cloudnative-pg.github.io/charts"
if $VALUES_CNPG_ENABLED; then
  if kubectl get crd clusters.postgresql.cnpg.io &>/dev/null 2>&1; then
    pass "CloudNativePG operator CRD found"
  else
    if confirm "CloudNativePG operator not found. Install it?"; then
      printf "        installing CloudNativePG operator...\n"
      if helm upgrade --install cnpg cloudnative-pg \
           --namespace cnpg-system --create-namespace \
           --repo "$CNPG_REPO" 2>/dev/null; then
        fixed "installed CloudNativePG operator"
      else
        fail "failed to install CloudNativePG operator"
        info "manual install: https://cloudnative-pg.io/documentation/current/installation_upgrade/"
      fi
    else
      fail "CloudNativePG operator not installed — required for PostgreSQL (clusters.postgresql.cnpg.io)"
    fi
  fi
else
  pass "CloudNativePG disabled (using external PostgreSQL)"
fi

# VictoriaMetrics operator
VM_REPO="https://victoriametrics.github.io/helm-charts/"
VM_INSTALLED_VER=$(helm list -n "$NAMESPACE" -f 'vmo' -o json 2>/dev/null | grep -oE '"chart":"victoria-metrics-operator-[^"]+"' | head -1 | sed 's/.*operator-//' | tr -d '"')

if kubectl get crd vmclusters.operator.victoriametrics.com &>/dev/null 2>&1; then
  if [ -n "$VM_INSTALLED_VER" ]; then
    VM_LATEST_VER=$(helm show chart victoria-metrics-operator --repo "$VM_REPO" 2>/dev/null | grep '^version:' | awk '{print $2}')
    if [ -n "$VM_LATEST_VER" ] && [ "$VM_LATEST_VER" != "$VM_INSTALLED_VER" ]; then
      if confirm "VictoriaMetrics operator ${VM_INSTALLED_VER} installed, ${VM_LATEST_VER} available. Update?"; then
        if helm upgrade vmo victoria-metrics-operator -n "$NAMESPACE" --repo "$VM_REPO" 2>/dev/null; then
          fixed "updated VictoriaMetrics operator to ${VM_LATEST_VER}"
        else
          warn "failed to update VictoriaMetrics operator"
        fi
      else
        pass "VictoriaMetrics operator installed (v${VM_INSTALLED_VER}, update available: ${VM_LATEST_VER})"
      fi
    else
      pass "VictoriaMetrics operator installed (v${VM_INSTALLED_VER}, up to date)"
    fi
  else
    pass "VictoriaMetrics operator CRDs found"
  fi
else
  if confirm "VictoriaMetrics operator not found. Install it?"; then
    printf "        installing VictoriaMetrics operator...\n"
    if helm upgrade --install vmo victoria-metrics-operator -n "$NAMESPACE" --repo "$VM_REPO" 2>/dev/null; then
      fixed "installed VictoriaMetrics operator"
    else
      fail "failed to install VictoriaMetrics operator"
      info "manual install: https://docs.victoriametrics.com/operator/"
    fi
  else
    fail "VictoriaMetrics operator not installed — required for internal metrics"
  fi
fi

# Gateway API CRDs
if ! kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null 2>&1; then
  if $INSTALL_PREREQS; then
    if confirm "Install Gateway API CRDs (experimental channel, includes TCPRoute)?"; then
      printf "        installing Gateway API CRDs...\n"
      if kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/experimental-install.yaml 2>/dev/null; then
        fixed "installed Gateway API CRDs (experimental channel)"
      else
        fail "failed to install Gateway API CRDs"
      fi
    fi
  fi
fi

# ============================================================
section "Ingress / Gateway"
# ============================================================

INGRESS_FOUND=false
GATEWAY_FOUND=false

# Check for Gateway API CRDs (preferred per install guide)
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null 2>&1; then
  GATEWAY_FOUND=true
  pass "Gateway API CRDs installed"

  # Check for TCPRoute support (experimental channel — required for syslog/TLS inputs)
  if kubectl get crd tcproutes.gateway.networking.k8s.io &>/dev/null 2>&1; then
    pass "Gateway API TCPRoute CRD found (experimental channel)"
  else
    warn "Gateway API TCPRoute CRD not found — required for TCP inputs (syslog). Install experimental channel CRDs"
  fi

  # Check for at least one GatewayClass
  GW_CLASSES=$(kubectl get gatewayclass -o name 2>/dev/null | head -5)
  if [ -n "$GW_CLASSES" ]; then
    pass "GatewayClass(es) available: $(echo "$GW_CLASSES" | sed 's|gatewayclass.gateway.networking.k8s.io/||g' | tr '\n' ' ')"
  else
    warn "no GatewayClass found — install a Gateway API implementation (Traefik, Istio, Envoy Gateway, kgateway)"
  fi

  # Check for a Gateway resource if routing is enabled
  if $VALUES_ROUTING_ENABLED; then
    GW_COUNT=$(kubectl get gateways --all-namespaces --no-headers 2>/dev/null | wc -l)
    if [ "$GW_COUNT" -gt 0 ]; then
      pass "Gateway resource(s) found (${GW_COUNT} total)"
    else
      warn "routing is enabled but no Gateway resources found — create a Gateway before installing"
    fi
  fi
fi

# Check for traditional Ingress (alternative)
if ! $GATEWAY_FOUND || $VALUES_INGRESS_ENABLED; then
  ING_CLASSES=$(kubectl get ingressclass -o name 2>/dev/null | head -5)
  if [ -n "$ING_CLASSES" ]; then
    pass "IngressClass(es) available: $(echo "$ING_CLASSES" | sed 's|ingressclass.networking.k8s.io/||g' | tr '\n' ' ')"
    INGRESS_FOUND=true
  fi
fi

if ! $GATEWAY_FOUND && ! $INGRESS_FOUND; then
  fail "no Gateway API or IngressClass found — a gateway or ingress controller is required for external access"
  info "install guide recommends Gateway API with experimental channel (TCPRoute support)"
fi

# ============================================================
section "Required Kubernetes Secrets"
# ============================================================

check_secret() {
  local name="$1"
  shift
  local keys=("$@")

  if kubectl get secret "$name" -n "$NAMESPACE" &>/dev/null; then
    local missing=()
    for key in "${keys[@]}"; do
      if ! kubectl get secret "$name" -n "$NAMESPACE" -o jsonpath="{.data.${key}}" 2>/dev/null | grep -q .; then
        missing+=("$key")
      fi
    done
    if [ ${#missing[@]} -eq 0 ]; then
      pass "secret '${name}' exists with all expected keys"
    else
      warn "secret '${name}' exists but missing keys: ${missing[*]}"
    fi
  else
    fail "secret '${name}' not found in namespace ${NAMESPACE}"
  fi
}

# License secret
if kubectl get secret "monad-license" -n "$NAMESPACE" &>/dev/null; then
  pass "secret 'monad-license' exists"
else
  if [ -f "license.crt" ]; then
    if confirm "Found license.crt in current directory. Create 'monad-license' secret from it?"; then
      if kubectl create secret generic monad-license --from-file=license.crt=license.crt -n "$NAMESPACE" 2>/dev/null; then
        fixed "created secret 'monad-license' from ./license.crt"
      else
        fail "failed to create secret 'monad-license' from ./license.crt"
      fi
    else
      warn "secret 'monad-license' not created (license.crt found locally but skipped)"
    fi
  else
    fail "secret 'monad-license' not found and no license.crt in current directory"
  fi
fi

# API secret
if kubectl get secret "api" -n "$NAMESPACE" &>/dev/null; then
  check_secret "api" AUTH_SECRET JWT_SIGNING_KEY
  # Check auth type-specific keys
  AUTH_TYPE=$(kubectl get secret "api" -n "$NAMESPACE" -o jsonpath='{.data.MONAD_AUTH_TYPE}' 2>/dev/null | base64 -d 2>/dev/null || true)
  case "$AUTH_TYPE" in
    auth0)
      info "auth type: auth0"
      check_secret "api" \
        MONAD_AUTH_AUTH0_DOMAIN \
        MONAD_AUTH_AUTH0_API_AUDIENCE \
        MONAD_AUTH_AUTH0_API_CLIENT_ID \
        MONAD_AUTH_AUTH0_CLIENT_SECRET \
        MONAD_AUTH_AUTH0_MACHINE_CLIENT_ID \
        MONAD_AUTH_AUTH0_MACHINE_CLIENT_SECRET \
        MONAD_AUTH_AUTH0_MACHINE_AUDIENCE
      ;;
    cognito)
      info "auth type: cognito"
      check_secret "api" \
        MONAD_AUTH_COGNITO_AWS_REGION \
        MONAD_AUTH_COGNITO_USER_POOL_ID \
        MONAD_AUTH_COGNITO_CLIENT_ID \
        MONAD_AUTH_COGNITO_DOMAIN \
        MONAD_AUTH_COGNITO_SECRET \
        MONAD_AUTH_COGNITO_ISSUER_URL
      ;;
    local) info "auth type: local (no external auth provider needed)" ;;
    "") warn "api secret has no MONAD_AUTH_TYPE key — set to 'auth0', 'cognito', or 'local'" ;;
    *) warn "api secret has unknown MONAD_AUTH_TYPE '${AUTH_TYPE}'" ;;
  esac
else
  # Secret doesn't exist — check for api.env or offer to create it
  if [ -f "api.env" ]; then
    if confirm "Found api.env in current directory. Create 'api' secret from it?"; then
      if kubectl create secret generic api --from-env-file=api.env -n "$NAMESPACE" 2>/dev/null; then
        fixed "created secret 'api' from ./api.env"
      else
        fail "failed to create secret 'api' from ./api.env"
      fi
    else
      fail "secret 'api' not found in namespace ${NAMESPACE}"
    fi
  else
    warn "secret 'api' not found and no api.env in current directory"
    if confirm "Generate api.env template to fill in?"; then
      cat > api.env <<'APIENV'
# Required
AUTH_SECRET=<AUTH_SECRET>
MONAD_AUTH_SECRET=<AUTH_SECRET>
JWT_SIGNING_KEY=<ANY RANDOM STRING>

# Required for Auth0
MONAD_AUTH_TYPE=auth0
MONAD_AUTH_AUTH0_CLIENT_ID=<AUTH0_CLIENT_ID>
MONAD_AUTH_AUTH0_API_AUDIENCE=<AUTH0_API_AUDIENCE>
MONAD_AUTH_AUTH0_API_CLIENT_ID=<AUTH0_API_CLIENT_ID>
MONAD_AUTH_AUTH0_CLIENT_SECRET=<AUTH0_API_CLIENT_SECRET>
MONAD_AUTH_AUTH0_DOMAIN=<AUTH0_DOMAIN>
MONAD_AUTH_AUTH0_ISSUER=<AUTH0_ISSUER>
MONAD_AUTH_AUTH0_MACHINE_CLIENT_SECRET=<AUTH0_MACHINE_CLIENT_SECRET>
MONAD_AUTH_AUTH0_MACHINE_CLIENT_ID=<AUTH0_MACHINE_CLIENT_ID>
MONAD_AUTH_AUTH0_MACHINE_AUDIENCE=<AUTH0_MACHINE_AUDIENCE>

# Required for Cognito (replace the Auth0 section above)
# MONAD_AUTH_TYPE=cognito
# MONAD_AUTH_COGNITO_AWS_REGION=<COGNITO_AWS_REGION>
# MONAD_AUTH_COGNITO_USER_POOL_ID=<COGNITO_USER_POOL_ID>
# MONAD_AUTH_COGNITO_CLIENT_ID=<COGNITO_CLIENT_ID>
# MONAD_AUTH_COGNITO_DOMAIN=<COGNITO_DOMAIN>
# MONAD_AUTH_COGNITO_SECRET=<COGNITO_SECRET>
# MONAD_AUTH_COGNITO_ISSUER_URL=<COGNITO_ISSUER_URL>

# Optional
# GOOGLE_OAUTH_CLIENT_ID=<GOOGLE_OAUTH_CLIENT_ID>
# GOOGLE_OAUTH_CLIENT_SECRET=<GOOGLE_OAUTH_CLIENT_SECRET>
# ZOOM_OAUTH_CLIENT_ID=<ZOOM_OAUTH_CLIENT_ID>
# ZOOM_OAUTH_CLIENT_SECRET=<ZOOM_OAUTH_CLIENT_SECRET>
APIENV
      fixed "created api.env template — fill in your values and re-run this script"
      fail "secret 'api' still needs to be created (fill in api.env first)"
    else
      fail "secret 'api' not found in namespace ${NAMESPACE}"
    fi
  fi
fi

# UI secret
if kubectl get secret "ui" -n "$NAMESPACE" &>/dev/null; then
  check_secret "ui" AUTH_SECRET
  UI_AUTH_TYPE=$(kubectl get secret "ui" -n "$NAMESPACE" -o jsonpath='{.data.MONAD_AUTH_TYPE}' 2>/dev/null | base64 -d 2>/dev/null || true)
  case "$UI_AUTH_TYPE" in
    auth0)
      check_secret "ui" \
        AUTH_AUTH0_DOMAIN \
        AUTH_AUTH0_CLIENT_ID \
        AUTH_AUTH0_API_AUDIENCE \
        AUTH_AUTH0_CLIENT_SECRET
      ;;
    cognito)
      check_secret "ui" \
        AUTH_COGNITO_AWS_REGION \
        AUTH_COGNITO_USER_POOL_ID \
        AUTH_COGNITO_CLIENT_ID \
        AUTH_COGNITO_DOMAIN \
        AUTH_COGNITO_SECRET \
        AUTH_COGNITO_ISSUER_URL
      ;;
    local) ;;
    "")
      if kubectl get secret "ui" -n "$NAMESPACE" -o jsonpath='{.data.AUTH_AUTH0_CLIENT_ID}' 2>/dev/null | grep -q .; then
        info "ui secret appears to use Auth0 keys (legacy format without MONAD_AUTH_TYPE)"
      fi
      ;;
  esac
else
  # Secret doesn't exist — check for ui.env or offer to create it
  if [ -f "ui.env" ]; then
    if confirm "Found ui.env in current directory. Create 'ui' secret from it?"; then
      if kubectl create secret generic ui --from-env-file=ui.env -n "$NAMESPACE" 2>/dev/null; then
        fixed "created secret 'ui' from ./ui.env"
      else
        fail "failed to create secret 'ui' from ./ui.env"
      fi
    else
      fail "secret 'ui' not found in namespace ${NAMESPACE}"
    fi
  else
    warn "secret 'ui' not found and no ui.env in current directory"
    if confirm "Generate ui.env template to fill in?"; then
      cat > ui.env <<'UIENV'
# Required
AUTH_SECRET=<AUTH_SECRET>

# Required for Auth0
MONAD_AUTH_TYPE=auth0
AUTH_AUTH0_DOMAIN=<AUTH0_DOMAIN>
AUTH_AUTH0_CLIENT_ID=<AUTH0_CLIENT_ID>
AUTH_AUTH0_API_AUDIENCE=<AUTH0_API_AUDIENCE>
AUTH_AUTH0_CLIENT_SECRET=<AUTH0_CLIENT_SECRET>

# Required for Cognito (replace the Auth0 section above)
# MONAD_AUTH_TYPE=cognito
# AUTH_COGNITO_AWS_REGION=<COGNITO_AWS_REGION>
# AUTH_COGNITO_USER_POOL_ID=<COGNITO_USER_POOL_ID>
# AUTH_COGNITO_CLIENT_ID=<COGNITO_CLIENT_ID>
# AUTH_COGNITO_DOMAIN=<COGNITO_DOMAIN>
# AUTH_COGNITO_SECRET=<COGNITO_SECRET>
# AUTH_COGNITO_ISSUER_URL=<COGNITO_ISSUER_URL>
UIENV
      fixed "created ui.env template — fill in your values and re-run this script"
      fail "secret 'ui' still needs to be created (fill in ui.env first)"
    else
      fail "secret 'ui' not found in namespace ${NAMESPACE}"
    fi
  fi
fi

# Encryption key secret (named "secret" per install guide)
SECRET_FOUND=false
if kubectl get secret "secret" -n "$NAMESPACE" &>/dev/null; then
  check_secret "secret" MONAD_ENCRYPTION_KEY
  SECRET_FOUND=true
fi
if kubectl get secret "secret-service-env-secrets" -n "$NAMESPACE" &>/dev/null; then
  check_secret "secret-service-env-secrets" MONAD_ENCRYPTION_KEY
  SECRET_FOUND=true
fi
if ! $SECRET_FOUND; then
  if confirm "Encryption key secret not found. Generate and create it now?"; then
    ENC_KEY=$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64)
    if kubectl create secret generic secret --from-literal="MONAD_ENCRYPTION_KEY=${ENC_KEY}" -n "$NAMESPACE" 2>/dev/null; then
      fixed "created secret 'secret' with generated MONAD_ENCRYPTION_KEY"
    else
      fail "failed to create encryption key secret"
    fi
  else
    fail "encryption key secret not found in namespace ${NAMESPACE}"
  fi
fi

# External PostgreSQL secret (only if CNPG is disabled)
if ! $VALUES_CNPG_ENABLED; then
  check_secret "monad-db-app" \
    user \
    password \
    dbname \
    host \
    port \
    uri
fi

# ============================================================
section "Image Pull Credentials"
# ============================================================

HAS_PULL_SECRET=false
for secret_name in default-pull-secret monad-image-auth-token ghcr-auth regcred; do
  if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
    TYPE=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null)
    if [ "$TYPE" = "kubernetes.io/dockerconfigjson" ]; then
      pass "image pull secret '${secret_name}' exists (type: dockerconfigjson)"
      HAS_PULL_SECRET=true
      break
    fi
  fi
done

if ! $HAS_PULL_SECRET; then
  SA_PULL=$(kubectl get serviceaccount default -n "$NAMESPACE" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)
  if [ -n "$SA_PULL" ]; then
    pass "default service account has imagePullSecrets: ${SA_PULL}"
  else
    if confirm "No image pull secret found. Create 'default-pull-secret' now? (you'll be prompted for your Docker Hub token)"; then
      printf "  ${YELLOW}?${NC}     Docker Hub access token: "
      read -rs DOCKER_TOKEN
      printf "\n"
      if [ -n "$DOCKER_TOKEN" ] && \
         kubectl create secret docker-registry default-pull-secret \
           -n "$NAMESPACE" \
           --docker-server=registry-1.docker.io \
           --docker-username=monadinc \
           --docker-password="$DOCKER_TOKEN" 2>/dev/null; then
        fixed "created secret 'default-pull-secret' for registry-1.docker.io"
      else
        fail "failed to create image pull secret"
      fi
    else
      fail "no image pull secret found — required to pull Monad images"
    fi
  fi
fi

# ============================================================
section "TLS Certificates"
# ============================================================

# HTTP Input TLS secret (for syslog / direct TLS inputs)
if kubectl get secret "http-input-tls" -n "$NAMESPACE" &>/dev/null; then
  TLS_TYPE=$(kubectl get secret "http-input-tls" -n "$NAMESPACE" -o jsonpath='{.type}' 2>/dev/null)
  if [ "$TLS_TYPE" = "kubernetes.io/tls" ]; then
    pass "secret 'http-input-tls' exists (TLS certificate for TCP/syslog inputs)"
  else
    warn "secret 'http-input-tls' exists but type is '${TLS_TYPE}' (expected kubernetes.io/tls)"
  fi
else
  warn "secret 'http-input-tls' not found — needed for TCP inputs (syslog). Should cover l4.<hostname> and *.l4.<hostname>"
fi

# Check for gateway TLS cert (in the gateway namespace, if routing enabled)
if $VALUES_ROUTING_ENABLED && [ -n "$VALUES_FILE" ] && [ -f "$VALUES_FILE" ]; then
  GW_NS=$(grep -A3 'parentRefs:' "$VALUES_FILE" 2>/dev/null | grep 'namespace:' | head -1 | awk '{print $2}' | tr -d '"' || true)
  if [ -n "$GW_NS" ] && [ "$GW_NS" != "$NAMESPACE" ]; then
    GW_CERTS=$(kubectl get secrets -n "$GW_NS" --field-selector type=kubernetes.io/tls -o name 2>/dev/null | head -5)
    if [ -n "$GW_CERTS" ]; then
      pass "TLS secret(s) found in gateway namespace '${GW_NS}': $(echo "$GW_CERTS" | sed 's|secret/||g' | tr '\n' ' ')"
    else
      warn "no TLS secrets found in gateway namespace '${GW_NS}' — HTTPS termination requires a certificate on the Gateway"
    fi
  fi
fi

# ============================================================
section "Storage"
# ============================================================

SC_DEFAULT=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || true)
if [ -n "$SC_DEFAULT" ]; then
  pass "default StorageClass: ${SC_DEFAULT}"
else
  SC_ANY=$(kubectl get storageclass -o name 2>/dev/null | head -1)
  if [ -n "$SC_ANY" ]; then
    warn "no default StorageClass set, but StorageClass(es) exist — specify storageClassName in values (e.g., nats.config.jetstream.fileStore.pvc.storageClassName)"
  else
    fail "no StorageClass found — required for PostgreSQL (CNPG) and NATS JetStream persistent storage"
  fi
fi

# ============================================================
section "DNS"
# ============================================================

if [ "$VALUES_HOSTNAME" = "chart-example.local" ]; then
  warn "hostname is still default 'chart-example.local' — set hostnames in your values override"
else
  if command -v dig &>/dev/null; then
    if dig +short "$VALUES_HOSTNAME" 2>/dev/null | grep -q .; then
      pass "DNS resolves for '${VALUES_HOSTNAME}'"
    else
      warn "DNS does not resolve for '${VALUES_HOSTNAME}' — ensure DNS is configured before users access the UI"
    fi
  elif command -v nslookup &>/dev/null; then
    if nslookup "$VALUES_HOSTNAME" &>/dev/null; then
      pass "DNS resolves for '${VALUES_HOSTNAME}'"
    else
      warn "DNS does not resolve for '${VALUES_HOSTNAME}' — ensure DNS is configured"
    fi
  else
    warn "cannot verify DNS for '${VALUES_HOSTNAME}' (no dig or nslookup available)"
  fi

  # Check for L4 wildcard DNS (needed for TCP/syslog inputs)
  L4_HOSTNAME="l4.${VALUES_HOSTNAME}"
  if command -v dig &>/dev/null; then
    if dig +short "$L4_HOSTNAME" 2>/dev/null | grep -q .; then
      pass "DNS resolves for '${L4_HOSTNAME}' (TCP input hostname)"
    else
      warn "DNS does not resolve for '${L4_HOSTNAME}' — needed for TCP inputs. Point *.l4.<hostname> to your load balancer"
    fi
  fi
fi

# ============================================================
section "Cluster Resources"
# ============================================================

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -gt 0 ]; then
  pass "${NODE_COUNT} node(s) in cluster"

  TOTAL_MEM_KI=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null | \
    sed 's/Ki//' | awk '{s+=$1} END {print s}')
  if [ -n "$TOTAL_MEM_KI" ] && [ "$TOTAL_MEM_KI" -gt 0 ] 2>/dev/null; then
    TOTAL_MEM_GI=$((TOTAL_MEM_KI / 1048576))
    if [ "$TOTAL_MEM_GI" -ge 8 ]; then
      pass "total allocatable memory: ~${TOTAL_MEM_GI}Gi"
    elif [ "$TOTAL_MEM_GI" -ge 4 ]; then
      warn "total allocatable memory: ~${TOTAL_MEM_GI}Gi — minimum 8Gi recommended"
    else
      fail "total allocatable memory: ~${TOTAL_MEM_GI}Gi — likely insufficient (8Gi+ recommended)"
    fi
  fi

  TOTAL_CPU=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' 2>/dev/null | \
    awk '{s+=$1} END {print s}')
  if [ -n "$TOTAL_CPU" ] && [ "$TOTAL_CPU" -gt 0 ] 2>/dev/null; then
    if [ "$TOTAL_CPU" -ge 4 ]; then
      pass "total allocatable CPU: ${TOTAL_CPU} cores"
    else
      warn "total allocatable CPU: ${TOTAL_CPU} cores — 4+ recommended"
    fi
  fi
else
  fail "no nodes found in cluster"
fi

# ============================================================
section "Values File"
# ============================================================

VALUES_FILE_TO_CHECK="$VALUES_FILE"

# If no values file specified, check for values-override.yaml in current directory
if [ -z "$VALUES_FILE_TO_CHECK" ]; then
  if [ -f "values-override.yaml" ]; then
    VALUES_FILE_TO_CHECK="values-override.yaml"
    pass "found values-override.yaml in current directory"
  else
    if confirm "No values-override.yaml found. Generate a template?"; then
      cat > values-override.yaml <<'VALUESEOF'
# The hostname(s) at which Monad will be accessible.
# All HTTPRoutes, backend URLs, and the UI origin are derived from this.
hostnames:
  - monad.example.com

# Pull images from Docker Hub
image:
  repository: registry-1.docker.io/monadinc/

imagePullSecrets:
  - name: default-pull-secret

# Disable the built-in Postgres cluster if using external Postgres
# postgresql:
#   cnpg:
#     enabled: false

# Enable Gateway API routing
routing:
  enabled: true

# Point all routes at your Gateway — replace placeholders with your values
routes:
  default:
    parentRefs:
      - namespace: <gateway-namespace>
        name: <your-gateway-name>
        sectionName: websecure
  otel:
    parentRefs:
      - namespace: <gateway-namespace>
        name: <your-gateway-name>
        sectionName: otel-grpc
      - namespace: <gateway-namespace>
        name: <your-gateway-name>
        sectionName: otel-https
  tcp:
    parentRefs:
      - namespace: <gateway-namespace>
        name: <your-gateway-name>
        sectionName: tcp

# Set this to your cluster's storage class
nats:
  config:
    jetstream:
      fileStore:
        pvc:
          storageClassName: <your-storage-class>

operator:
  env:
    MONAD_PIPELINE_IMAGE_REGISTRY:
      value: registry-1.docker.io/monadinc/
VALUESEOF
      fixed "created values-override.yaml template — fill in your values and re-run with: ./preflight-check.sh -f values-override.yaml"
      fail "values-override.yaml still has placeholder values"
      # Don't validate the template we just generated
      VALUES_FILE_TO_CHECK=""
    else
      warn "no values override file — using chart defaults"
    fi
  fi
fi

if [ -n "$VALUES_FILE_TO_CHECK" ] && [ -f "$VALUES_FILE_TO_CHECK" ]; then
  pass "values override file: ${VALUES_FILE_TO_CHECK}"

  # Check that imagePullSecrets is configured
  if grep -q 'imagePullSecrets' "$VALUES_FILE_TO_CHECK" 2>/dev/null; then
    pass "imagePullSecrets configured in values file"
  else
    warn "imagePullSecrets not set in values file — add: imagePullSecrets: [{name: default-pull-secret}]"
  fi

  # Check that hostnames is not default
  if grep -qE 'chart-example\.local|monad\.example\.com' "$VALUES_FILE_TO_CHECK" 2>/dev/null; then
    warn "values file still contains a placeholder hostname — update hostnames to your actual domain"
  fi

  # Check image repository is set
  if grep -q 'repository:' "$VALUES_FILE_TO_CHECK" 2>/dev/null; then
    pass "image repository configured in values file"
  else
    warn "image.repository not set in values file — should be set to registry-1.docker.io/monadinc/ or ghcr.io/monad-inc/"
  fi

  # Check operator pipeline image registry
  if grep -q 'MONAD_PIPELINE_IMAGE_REGISTRY' "$VALUES_FILE_TO_CHECK" 2>/dev/null; then
    pass "operator pipeline image registry configured"
  else
    warn "operator.env.MONAD_PIPELINE_IMAGE_REGISTRY not set — pipeline pods may pull from wrong registry"
  fi

  # Check for placeholder values that still need to be replaced
  if grep -qE '<[a-z].*>' "$VALUES_FILE_TO_CHECK" 2>/dev/null; then
    PLACEHOLDERS=$(grep -oE '<[a-z][a-z0-9_-]*>' "$VALUES_FILE_TO_CHECK" 2>/dev/null | sort -u | tr '\n' ' ')
    warn "values file has unfilled placeholders: ${PLACEHOLDERS}"
  fi
elif [ -n "$VALUES_FILE_TO_CHECK" ]; then
  fail "values file '${VALUES_FILE_TO_CHECK}' not found"
fi

# ============================================================
# Summary
# ============================================================
print_summary

if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
