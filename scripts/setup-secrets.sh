#!/usr/bin/env bash
# =============================================================================
# setup-secrets.sh
#
# Handles the Sealed Secrets workflow: generates a raw Kubernetes Secret
# locally (dry-run), seals it using kubeseal, places the encrypted manifest
# in the correct overlay path, and removes the plaintext file immediately.
#
# Run this after bootstrap.sh if you skipped the Sealed Secrets step, or
# whenever you need to generate/rotate a new SealedSecret.
#
# Usage: ./scripts/setup-secrets.sh
# =============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
SEALED_SECRETS_VERSION="v0.37.0"
SECRET_NAME="demo-db-secret"
SECRET_NS="dev"
OUTPUT_PATH="apps/demo-app/overlays/dev/sealed-secret-db.yaml"
TEMP_FILE="temp-secret.yaml"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo -e "${BLUE}[•]${NC} $*"; }
success() { echo -e "${GREEN}[✔]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── Resolve repo root from script location ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Step 0: Checks ───────────────────────────────────────────────────────────
step "Pre-flight checks"

if ! command -v kubectl &>/dev/null; then
  error "kubectl is not installed."
fi
success "kubectl found."

if ! command -v kubeseal &>/dev/null; then
  echo ""
  warn "kubeseal is not installed. Install it with:"
  echo ""
  echo "  curl -L -o kubeseal.tar.gz https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-0.37.0-linux-amd64.tar.gz"
  echo "  tar -xvzf kubeseal.tar.gz kubeseal"
  echo "  sudo install -m 755 kubeseal /usr/local/bin/kubeseal"
  echo "  rm kubeseal kubeseal.tar.gz"
  echo ""
  error "Please install kubeseal and re-run this script."
fi
success "kubeseal found: $(command -v kubeseal)"

# Verify the Sealed Secrets controller is running
if ! kubectl get deployment sealed-secrets-controller -n kube-system &>/dev/null; then
  warn "Sealed Secrets controller not found in kube-system."
  warn "Make sure you answered 'y' during bootstrap.sh or run:"
  warn "  kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml"
  error "Controller is required to seal secrets."
fi
success "Sealed Secrets controller is running."

# ── Step 1: Generate raw Secret (dry-run, never committed) ───────────────────
step "Generating temporary raw Secret"

log "Creating '${SECRET_NAME}' in namespace '${SECRET_NS}' (dry-run)..."
log "  NOTE: Edit this script to change db-user and db-password values."

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${SECRET_NS}" \
  --from-literal=db-user='admin-user' \
  --from-literal=db-password='senha-secreta-banco' \
  --dry-run=client -o yaml > "${REPO_ROOT}/${TEMP_FILE}"

success "Temporary file created at ${TEMP_FILE} (will be deleted after sealing)."

# ── Step 2: Seal the Secret ───────────────────────────────────────────────────
step "Sealing the Secret"

mkdir -p "$(dirname "${REPO_ROOT}/${OUTPUT_PATH}")"

log "Encrypting with kubeseal → ${OUTPUT_PATH}..."
kubeseal --format=yaml \
  < "${REPO_ROOT}/${TEMP_FILE}" \
  > "${REPO_ROOT}/${OUTPUT_PATH}"

success "SealedSecret generated at ${OUTPUT_PATH}."

# ── Step 3: Remove plaintext file ────────────────────────────────────────────
step "Cleanup"

rm -f "${REPO_ROOT}/${TEMP_FILE}"
success "Temporary raw secret file removed."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║      Sealed Secret created successfully!     ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}File created:${NC} ${OUTPUT_PATH}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    1. Review the generated file: cat ${OUTPUT_PATH}"
echo -e "    2. Commit and push to trigger ArgoCD sync:"
echo -e "       ${BLUE}git add ${OUTPUT_PATH}${NC}"
echo -e "       ${BLUE}git commit -m \"feat: add sealed secret for demo-db\"${NC}"
echo -e "       ${BLUE}git push origin main${NC}"
echo ""
