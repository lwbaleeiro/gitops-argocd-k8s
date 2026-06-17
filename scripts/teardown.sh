#!/usr/bin/env bash
# =============================================================================
# teardown.sh
#
# Completely removes the local GitOps POC environment.
# Stops the ArgoCD port-forward process (if running) and deletes the K3d
# cluster, destroying all associated containers and resources.
#
# Usage: ./scripts/teardown.sh
# =============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CLUSTER_NAME="gitops-poc"
PID_FILE="/tmp/argocd-portforward.pid"

log()     { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
step()    { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

confirm() {
  local prompt="$1"
  read -r -p "$(echo -e "${YELLOW}[?]${NC} ${prompt} [y/N] ")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ── Confirm before destroying ─────────────────────────────────────────────────
echo ""
warn "This will permanently delete the K3d cluster '${CLUSTER_NAME}' and all its resources."
if ! confirm "Are you sure you want to proceed?"; then
  log "Teardown cancelled."
  exit 0
fi

# ── Step 1: Stop port-forward ─────────────────────────────────────────────────
step "Stopping ArgoCD port-forward"

if [[ -f "$PID_FILE" ]]; then
  PF_PID=$(cat "$PID_FILE")
  if kill -0 "$PF_PID" 2>/dev/null; then
    log "Killing port-forward process (PID: ${PF_PID})..."
    kill "$PF_PID"
    success "Port-forward stopped."
  else
    warn "Port-forward process (PID: ${PF_PID}) is not running."
  fi
  rm -f "$PID_FILE"
else
  warn "No port-forward PID file found. Skipping."
fi

# ── Step 2: Delete cluster ────────────────────────────────────────────────────
step "Deleting K3d cluster"

if k3d cluster list | grep -q "^${CLUSTER_NAME}"; then
  log "Deleting cluster '${CLUSTER_NAME}'..."
  k3d cluster delete "${CLUSTER_NAME}"
  success "Cluster deleted."
else
  warn "Cluster '${CLUSTER_NAME}' not found. Nothing to delete."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         Teardown completed successfully!     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Run ${BLUE}./scripts/bootstrap.sh${NC} to set up the environment again."
echo ""
