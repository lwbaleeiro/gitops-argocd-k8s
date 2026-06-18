# GitOps POC: ArgoCD + K3d + GitHub Actions CI

This repository demonstrates a complete, end-to-end **CI/CD GitOps workflow** using **GitHub Actions**, **ArgoCD**, and a local **K3d (K3s in Docker)** cluster.

Every push to the application source code automatically:
1. Builds and publishes a Docker image to **GitHub Container Registry (GHCR)**
2. Updates the Kubernetes manifests with the new image tag
3. Triggers **ArgoCD** to synchronize the cluster — no manual intervention needed

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer — git push (src/** change)                           │
└──────────────────────────────┬──────────────────────────────────┘
                               │ webhook
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions (CI)                                            │
│  ├── Build Docker image                                         │
│  ├── Push to ghcr.io/lwbaleeiro/demo-app:<sha>                  │
│  └── Commit updated kustomization.yaml → main [skip ci]        │
└──────────────────────────────┬──────────────────────────────────┘
                               │ git poll / webhook
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  ArgoCD — detects manifest drift → syncs                        │
│  ├── demo-app-dev     → namespace: dev     (1 replica)          │
│  └── demo-app-staging → namespace: staging (2 replicas)         │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  K3d cluster (1 server + 2 agents)                              │
│  ├── Nginx Ingress Controller  :8080 → /dev, /staging           │
│  ├── Sealed Secrets Controller (decrypts SealedSecrets)         │
│  └── App pods running ghcr.io image                             │
└─────────────────────────────────────────────────────────────────┘
```

**Key components:**
- **K3d**: Local Kubernetes cluster with Traefik disabled
- **ArgoCD**: GitOps controller — App-of-Apps pattern managing `dev` and `staging`
- **Nginx Ingress Controller**: Routes `localhost:8080/dev` and `localhost:8080/staging`
- **Sealed Secrets**: Encrypts `Secret` resources safe to commit to Git, decrypted in-cluster
- **GitHub Actions CI**: Builds image, pushes to GHCR, auto-updates manifests on every `src/` push
- **Kustomize overlays**: Per-environment configuration (replicas, image tag, secrets)

---

## Prerequisites

Ensure all tools are installed before running any script:

| Tool | Version | Install |
|------|---------|---------|
| [Docker](https://docs.docker.com/) | v24+ | Required by k3d |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.28+ | Kubernetes CLI |
| [k3d](https://k3d.io/) | v5.6+ | Local cluster |
| [ArgoCD CLI](https://argoproj.github.io/argo-cd/cli_installation/) | latest | GitOps CLI |
| [Helm](https://helm.sh/docs/intro/install/) | v3+ | Installs Nginx Ingress |
| [kubeseal CLI](https://github.com/bitnami-labs/sealed-secrets/releases) | v0.37.0+ | Seals secrets |

---

## Getting Started

### Option A — Automated Setup (Recommended)

Run the bootstrap script to set up everything in one shot:

```bash
./scripts/bootstrap.sh
```

The script runs these steps automatically:

| Step | What it does |
|------|--------------|
| 0 | Pre-flight checks (`k3d`, `kubectl`, `argocd`, `helm`) |
| 1 | Creates the K3d cluster `gitops-poc` (or reuses it) |
| 2 | Installs ArgoCD and waits for pods to be Ready |
| 3 | Starts `kubectl port-forward` for the ArgoCD UI on `localhost:9090` |
| 4 | Logs in via the ArgoCD CLI |
| 5 | *(Optional)* Installs the Sealed Secrets controller |
| 6 | Installs the **Nginx Ingress Controller** via Helm |
| 7 | Deploys the App-of-Apps and waits for sync |

At the end, it prints:
```
  ArgoCD UI:   https://localhost:9090
  Username:    admin
  Password:    <generated>

  App URLs:
    dev:     http://localhost:8080/dev
    staging: http://localhost:8080/staging
```

To tear down the environment:
```bash
./scripts/teardown.sh
```

> **⚠️ Sealed Secrets and cluster recreation:** Every new cluster generates a new private key.
> If you recreate the cluster, all SealedSecrets in Git become unreadable and must be re-sealed.
> The bootstrap script warns you about this and provides the exact commands to fix it.

---

### Option B — Manual Setup

> Follow these steps if you prefer full control over each phase.

#### 1. Create the K3d Cluster

```bash
k3d cluster create gitops-poc \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"
```

#### 2. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Ready pods --all -n argocd --timeout=180s
```

#### 3. Install Nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout=90s
```

#### 4. Access the ArgoCD UI

```bash
# Run in background or a separate terminal
kubectl port-forward svc/argocd-server -n argocd 9090:443 &

# Retrieve the admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Password: $ARGOCD_PASS"

# Log in via CLI
argocd login localhost:9090 --username admin --password $ARGOCD_PASS --insecure
```

Web UI available at: **https://localhost:9090** (user: `admin`)

#### 5. Install Sealed Secrets Controller *(if using secrets)*

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.37.0/controller.yaml
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=90s
```

#### 6. Deploy via App-of-Apps

1. Fork this repository
2. Update `repoURL` in [infra/argocd-apps/app-of-apps.yaml](infra/argocd-apps/app-of-apps.yaml) to point to your fork
3. Apply the root application:

```bash
kubectl apply -f infra/argocd-apps/app-of-apps.yaml
argocd app list
```

---

## Secrets Management (Sealed Secrets)

Secrets are encrypted locally with `kubeseal` and committed to Git as `SealedSecret` resources. The in-cluster controller decrypts them back to plain `Secret` objects — and only that specific cluster can do so.

### Automated (Recommended)

```bash
./scripts/setup-secrets.sh
```

The script seals the secret for **both** `dev` and `staging` namespaces, saves the output files, and removes the plaintext. Commit and push the result:

```bash
git add apps/demo-app/overlays/dev/sealed-secret-db.yaml \
        apps/demo-app/overlays/staging/sealed-secret-db.yaml
git commit -m "fix: re-seal secrets for new cluster"
git push origin main
```

### Manual

```bash
# Fetch the cluster's current public key
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system > /tmp/pub-cert.pem

# Seal for dev
kubectl create secret generic demo-db-secret \
  --from-literal=db-user=admin \
  --from-literal=db-password=supersecret \
  --namespace dev --dry-run=client -o yaml | \
kubeseal --format yaml --cert /tmp/pub-cert.pem \
  > apps/demo-app/overlays/dev/sealed-secret-db.yaml

# Seal for staging
kubectl create secret generic demo-db-secret \
  --from-literal=db-user=admin \
  --from-literal=db-password=supersecret \
  --namespace staging --dry-run=client -o yaml | \
kubeseal --format yaml --cert /tmp/pub-cert.pem \
  > apps/demo-app/overlays/staging/sealed-secret-db.yaml
```

> **Note:** SealedSecrets are namespace-scoped. A secret sealed for `dev` cannot be used in `staging` and vice versa.

---

## Testing

### Verify the cluster is healthy

```bash
# All pods running
kubectl get pods -n dev
kubectl get pods -n staging

# ArgoCD apps all Synced + Healthy
argocd app list
```

### Access the application

The Nginx Ingress Controller exposes the demo app on port `8080` via path-based routing:

```bash
# dev environment
curl http://localhost:8080/dev
# Expected: HTTP 200 with GitOps Demo App HTML page

# staging environment
curl http://localhost:8080/staging
# Expected: HTTP 200 with GitOps Demo App HTML page
```

Or open in the browser:
- **dev:** http://localhost:8080/dev
- **staging:** http://localhost:8080/staging

### Scenario A — Full CI/CD Cycle (GitHub Actions)

Trigger the complete pipeline by modifying the application source code:

```bash
# 1. Make a change to the app
echo "<p>Version $(date)</p>" >> src/index.html

# 2. Commit and push
git add src/index.html
git commit -m "feat: add timestamp to the page"
git push origin main

# 3. Watch the CI pipeline run (~1-2 min)
#    GitHub → Actions tab → "CI — Build and Push Image"

# 4. Force an immediate ArgoCD refresh (or wait ~3 min for polling)
argocd app get demo-app-dev --refresh

# 5. Watch the new pod roll out
kubectl get pods -n dev -w

# 6. Verify the running image tag
kubectl get deployment demo-app -n dev \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# ghcr.io/lwbaleeiro/demo-app:<new-sha>

# 7. Test the updated app
curl http://localhost:8080/dev
```

**Expected total time from push to running pod: ~4–5 minutes.**

### Scenario B — GitOps Self-Healing

Simulate a manual drift — ArgoCD will revert it automatically:

```bash
# Scale up manually (this drifts from the Git state)
kubectl scale deployment demo-app -n dev --replicas=5

# Watch pods momentarily increase...
kubectl get pods -n dev -w

# ArgoCD detects the drift (selfHeal: true) and scales back to 1
# Force refresh to see it immediately:
argocd app get demo-app-dev --refresh
kubectl get pods -n dev
# Back to 1 replica
```

### Scenario C — Verify ArgoCD Sync Status

```bash
# Refresh and display full app status
argocd app get demo-app-dev --refresh
argocd app get demo-app-staging --refresh

# Check specific resources
kubectl get ingress -n dev
kubectl get ingress -n staging
kubectl get sealedsecret -n dev
kubectl get sealedsecret -n staging
```

---

## Repository Structure

```
gitops-argocd-k8s/
├── .github/
│   └── workflows/
│       └── ci.yaml                    ← GitHub Actions CI pipeline
├── src/                               ← Application source code
│   ├── Dockerfile
│   └── index.html
├── apps/
│   └── demo-app/
│       ├── base/                      ← Shared base manifests
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── dev/                   ← dev-specific config
│           │   ├── kustomization.yaml ← image tag auto-updated by CI
│           │   ├── patch-replicas.yaml
│           │   ├── ingress.yaml       ← /dev path
│           │   └── sealed-secret-db.yaml
│           └── staging/               ← staging-specific config
│               ├── kustomization.yaml ← image promoted manually
│               ├── patch-replicas.yaml
│               ├── ingress.yaml       ← /staging path
│               └── sealed-secret-db.yaml
├── infra/
│   └── argocd-apps/
│       └── app-of-apps.yaml           ← Root ArgoCD application
├── scripts/
│   ├── bootstrap.sh                   ← Full environment setup
│   ├── teardown.sh                    ← Cluster cleanup
│   └── setup-secrets.sh              ← Re-seal secrets utility
└── doc/
    ├── poc-part1-k3d-argocd.md
    ├── poc-part2-sealed-secrets.md
    └── poc-part3-github-actions-ci.md
```

---

## CI/CD Pipeline Details

The GitHub Actions workflow (`.github/workflows/ci.yaml`) runs on every push to `main` that touches `src/**`:

1. **Checkout** the repository
2. **Build** the Docker image from `src/Dockerfile`
3. **Push** to GHCR with two tags: `:<commit-sha>` and `:latest`
4. **Update** `apps/demo-app/overlays/dev/kustomization.yaml` with `kustomize edit set image`
5. **Commit and push** the manifest change with `[skip ci]` to prevent loops

> **Note:** The CI pipeline only auto-updates the `dev` overlay. Promotion to `staging` is done manually by updating the `newTag` in `apps/demo-app/overlays/staging/kustomization.yaml`.

---

## Cleanup

```bash
# Automated (stops port-forward + deletes cluster)
./scripts/teardown.sh

# Manual
k3d cluster delete gitops-poc
```
