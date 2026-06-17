#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh
#
# Automates the full environment setup for the GitOps POC.
# Creates the K3d cluster, installs and configures ArgoCD, deploys the
# App-of-Apps, and optionally installs the Sealed Secrets controller.
#
# Usage: ./scripts/bootstrap.sh
# =============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ───────────────────────────────────────────────────────────────────
CLUSTER_NAME="gitops-poc"
ARGOCD_PORT="9090"
ARGOCD_NS="argocd"
SEALED_SECRETS_VERSION="v0.37.0"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

confirm() {
  local prompt="$1"
  read -r -p "$(echo -e "${YELLOW}[?]${NC} ${prompt} [y/N] ")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Step 0: Pre-flight checks ─────────────────────────────────────────────────
step "Pre-flight checks"

for cmd in k3d kubectl argocd; do
  if command -v "$cmd" &>/dev/null; then
    success "$cmd found: $(command -v "$cmd")"
  else
    error "$cmd is not installed. Please install it before running this script."
  fi
done

# ── Step 1: K3d Cluster ───────────────────────────────────────────────────────
step "K3d Cluster"

if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists."
  if confirm "Do you want to delete and recreate it?"; then
    log "Deleting existing cluster..."
    k3d cluster delete "${CLUSTER_NAME}"
  else
    warn "Reusing existing cluster. Skipping cluster creation."
  fi
fi

if ! k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  log "Creating K3d cluster '${CLUSTER_NAME}'..."
  k3d cluster create "${CLUSTER_NAME}" \
    --agents 2 \
    --port "8080:80@loadbalancer" \
    --port "8443:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0"
  success "Cluster created."
fi

log "Verifying nodes..."
kubectl get nodes

# ── Step 2: ArgoCD ───────────────────────────────────────────────────────────
step "Installing ArgoCD"

if ! kubectl get namespace "${ARGOCD_NS}" &>/dev/null; then
  log "Creating namespace '${ARGOCD_NS}'..."
  kubectl create namespace "${ARGOCD_NS}"
fi

log "Applying ArgoCD manifests (server-side to avoid CRD annotation size limits)..."
kubectl apply --server-side -n "${ARGOCD_NS}" -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log "Waiting for ArgoCD pods to be Ready (timeout: 180s)..."
kubectl wait --for=condition=Ready pods --all -n "${ARGOCD_NS}" --timeout=180s
success "ArgoCD is up and running."

# ── Step 3: Port-forward ─────────────────────────────────────────────────────
step "Setting up port-forward"

# Kill any stale port-forward on the same port
if lsof -ti tcp:"${ARGOCD_PORT}" &>/dev/null; then
  warn "Port ${ARGOCD_PORT} already in use. Killing existing process..."
  lsof -ti tcp:"${ARGOCD_PORT}" | xargs kill -9
  sleep 1
fi

log "Starting port-forward on localhost:${ARGOCD_PORT}..."
kubectl port-forward svc/argocd-server -n "${ARGOCD_NS}" "${ARGOCD_PORT}":443 \
  > /tmp/argocd-portforward.log 2>&1 &
PORT_FORWARD_PID=$!
echo "$PORT_FORWARD_PID" > /tmp/argocd-portforward.pid

# Wait until the port is reachable
log "Waiting for port-forward to be ready..."
for i in {1..15}; do
  if nc -z localhost "${ARGOCD_PORT}" 2>/dev/null; then
    success "Port-forward is ready (PID: ${PORT_FORWARD_PID})."
    break
  fi
  if [[ "$i" -eq 15 ]]; then
    error "Port-forward did not become available. Check /tmp/argocd-portforward.log"
  fi
  sleep 1
done

# ── Step 4: ArgoCD Login ─────────────────────────────────────────────────────
step "Logging into ArgoCD"

ARGOCD_PASS=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

argocd login "localhost:${ARGOCD_PORT}" \
  --username admin \
  --password "${ARGOCD_PASS}" \
  --insecure
success "Logged in as admin."

# ── Step 5: Sealed Secrets (optional) — asked BEFORE App-of-Apps sync ────────
# Install the controller first so ArgoCD can reconcile apps that use SealedSecrets.
step "Sealed Secrets Controller"

INSTALL_SEALED_SECRETS=false
if confirm "Do you want to install the Sealed Secrets controller?"; then
  INSTALL_SEALED_SECRETS=true
  log "Applying Sealed Secrets controller (${SEALED_SECRETS_VERSION})..."
  kubectl apply -f \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"

  log "Waiting for Sealed Secrets controller pod to be Ready..."
  kubectl rollout status deployment/sealed-secrets-controller \
    -n kube-system \
    --timeout=90s
  success "Sealed Secrets controller is ready."
else
  warn "Skipping Sealed Secrets controller."
  warn "If any app overlay contains a SealedSecret resource, those apps will"
  warn "remain OutOfSync until the controller is installed."
  warn "Run './scripts/setup-secrets.sh' or re-run bootstrap and choose 'y'."
fi

# ── Step 6: App-of-Apps ──────────────────────────────────────────────────────
step "Deploying App-of-Apps"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log "Applying App-of-Apps manifest..."
kubectl apply -f "${REPO_ROOT}/infra/argocd-apps/app-of-apps.yaml"

log "Waiting for applications to sync (up to 90s)..."
OUTOFSYNC_APPS=""
for i in {1..18}; do
  SYNCED=$(kubectl get applications -n "${ARGOCD_NS}" \
    -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' 2>/dev/null \
    | grep -c "Synced" || true)
  TOTAL=$(kubectl get applications -n "${ARGOCD_NS}" \
    --no-headers 2>/dev/null | wc -l)

  if [[ "$TOTAL" -gt 0 && "$SYNCED" -eq "$TOTAL" ]]; then
    success "All ${TOTAL} application(s) are Synced."
    OUTOFSYNC_APPS=""
    break
  fi

  if [[ "$i" -eq 18 ]]; then
    # Collect names and reasons for any OutOfSync apps
    OUTOFSYNC_APPS=$(kubectl get applications -n "${ARGOCD_NS}" \
      --no-headers 2>/dev/null \
      | awk '$2 != "Synced" {print $1}')
    break
  fi

  log "  Synced: ${SYNCED}/${TOTAL} — retrying in 5s..."
  sleep 5
done

argocd app list

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         Bootstrap completed successfully!    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}ArgoCD UI:${NC}       https://localhost:${ARGOCD_PORT}"
echo -e "  ${BOLD}Username:${NC}        admin"
echo -e "  ${BOLD}Password:${NC}        ${ARGOCD_PASS}"
echo ""
echo -e "  ${YELLOW}Note:${NC} Port-forward is running in the background (PID: ${PORT_FORWARD_PID})."
echo -e "        To stop it: kill \$(cat /tmp/argocd-portforward.pid)"

# Warn if Sealed Secrets was installed on a brand-new cluster
# The private key changes on every new cluster, so existing SealedSecrets in
# Git cannot be decrypted and must be re-sealed with the new cluster's key.
if [[ "${INSTALL_SEALED_SECRETS}" == true ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠  Sealed Secrets — important:${NC}"
  echo -e "  If this is a recreated cluster, the private key has changed."
  echo -e "  Any SealedSecret committed to Git is now unreadable by this cluster"
  echo -e "  and must be re-sealed. Run:"
  echo ""
  echo -e "     ${BLUE}./scripts/setup-secrets.sh${NC}"
  echo -e "     ${BLUE}git add apps/demo-app/overlays/dev/sealed-secret-db.yaml${NC}"
  echo -e "     ${BLUE}git commit -m \"fix: re-seal secret for new cluster\"${NC}"
  echo -e "     ${BLUE}git push origin main${NC}"
fi

# Warn about any apps that did not sync
if [[ -n "${OUTOFSYNC_APPS}" ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠  The following app(s) are OutOfSync:${NC}"
  for app in ${OUTOFSYNC_APPS}; do
    APP_STATUS=$(argocd app get "${app}" --insecure 2>/dev/null || true)
    # Check if the root cause is a missing SealedSecret CRD
    if echo "${APP_STATUS}" | grep -q "SealedSecret.*CRD is installed"; then
      echo -e "     ${RED}•${NC} ${BOLD}${app}${NC} — missing Sealed Secrets CRD."
      echo -e "       ${YELLOW}→${NC} Install the controller and it will auto-sync:"
      echo -e "          kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"
    # Check if the root cause is a failed unseal (wrong cluster key)
    elif echo "${APP_STATUS}" | grep -q "no key could decrypt"; then
      echo -e "     ${RED}•${NC} ${BOLD}${app}${NC} — SealedSecret cannot be decrypted (cluster key changed)."
      echo -e "       ${YELLOW}→${NC} Re-seal the secret and push:"
      echo -e "          ./scripts/setup-secrets.sh"
      echo -e "          git add apps/demo-app/overlays/dev/sealed-secret-db.yaml"
      echo -e "          git commit -m \"fix: re-seal secret for new cluster\""
      echo -e "          git push origin main"
    else
      echo -e "     ${RED}•${NC} ${BOLD}${app}${NC} — check the ArgoCD UI for details:"
      echo -e "          https://localhost:${ARGOCD_PORT}/applications/${app}"
    fi
  done
fi
echo ""
