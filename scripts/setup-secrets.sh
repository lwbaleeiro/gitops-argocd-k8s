#!/usr/bin/env bash
# =============================================================================
# setup-secrets.sh
#
# Handles the Sealed Secrets workflow for ALL environments: generates a raw
# Kubernetes Secret locally (dry-run), seals it with kubeseal for each
# namespace, places the encrypted manifests in the correct overlay paths,
# and removes the plaintext file immediately.
#
# Environments sealed: dev, staging
#
# Run this after bootstrap.sh if you skipped the Sealed Secrets step, or
# whenever you recreate the cluster (new key = must re-seal all secrets).
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

# ── Step 1: Fetch cluster public key once ─────────────────────────────────────
step "Fetching cluster public key"

CERT_FILE="/tmp/sealed-secrets-pub-cert.pem"
log "Fetching public certificate from controller..."
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  > "${CERT_FILE}"
success "Certificate saved to ${CERT_FILE}."

# ── Step 2: Seal for each namespace ───────────────────────────────────────────
# Array of "namespace:output_path" pairs — add more entries to support new envs
declare -a ENVIRONMENTS=(
  "dev:apps/demo-app/overlays/dev/sealed-secret-db.yaml"
  "staging:apps/demo-app/overlays/staging/sealed-secret-db.yaml"
)

SEALED_FILES=()

for entry in "${ENVIRONMENTS[@]}"; do
  NS="${entry%%:*}"
  OUTPUT_PATH="${entry##*:}"

  step "Sealing '${SECRET_NAME}' for namespace '${NS}'"

  log "Creating raw secret (dry-run, namespace: ${NS})..."
  log "  NOTE: Edit this script to change db-user and db-password values."

  kubectl create secret generic "${SECRET_NAME}" \
    --namespace "${NS}" \
    --from-literal=db-user='admin-user' \
    --from-literal=db-password='senha-secreta-banco' \
    --dry-run=client -o yaml > "${REPO_ROOT}/${TEMP_FILE}"

  mkdir -p "$(dirname "${REPO_ROOT}/${OUTPUT_PATH}")"

  log "Encrypting with kubeseal → ${OUTPUT_PATH}..."
  kubeseal --format=yaml \
    --cert "${CERT_FILE}" \
    < "${REPO_ROOT}/${TEMP_FILE}" \
    > "${REPO_ROOT}/${OUTPUT_PATH}"

  rm -f "${REPO_ROOT}/${TEMP_FILE}"
  success "SealedSecret generated: ${OUTPUT_PATH}"
  SEALED_FILES+=("${OUTPUT_PATH}")
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║    Sealed Secrets created successfully!      ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Files created:${NC}"
for f in "${SEALED_FILES[@]}"; do
  echo -e "    ${GREEN}✔${NC} ${f}"
done
echo ""
echo -e "  ${BOLD}Next steps — commit and push to trigger ArgoCD sync:${NC}"
echo ""
echo -e "    ${BLUE}git add \\"
for f in "${SEALED_FILES[@]}"; do
  echo -e "      ${f} \\"
done
echo -e "    ${NC}"
echo -e "    ${BLUE}git commit -m \"fix: re-seal secrets for new cluster\"${NC}"
echo -e "    ${BLUE}git push origin main${NC}"
echo ""
