# GitOps POC: ArgoCD + K3d

This repository demonstrates a complete, end-to-end GitOps workflow using **ArgoCD** and a local **K3d (K3s in Docker)** cluster.

Any changes pushed to this repository are automatically synchronized to the local Kubernetes cluster.

---

## Architecture

- **K3d**: Local Kubernetes cluster (1 Server + 2 Agents).
- **ArgoCD**: Senders controller and UI deployed in the `argocd` namespace.
- **App-of-Apps Pattern**: A root application (`app-of-apps`) that manages and syncs all child applications (`demo-app-dev` and `demo-app-staging`).
- **Multi-Environment**: Deployments to `dev` and `staging` namespaces using Kustomize overlays.
- **Sealed Secrets**: Encrypts Kubernetes Secrets into custom `SealedSecret` resources that are safe to commit to Git, automatically decrypted inside the cluster by the controller.

---

## Prerequisites

Ensure you have the following installed on your machine:
- [Docker](https://docs.docker.com/) (v24+)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (v1.28+)
- [k3d](https://k3d.io/) (v5.6+)
- [ArgoCD CLI](https://argoproj.github.io/argo-cd/cli_installation/)
- [kubeseal CLI](https://github.com/bitnami-labs/sealed-secrets/releases) (v0.37.0+)

---

## Getting Started

### 1. Create the K3d Cluster
Spin up a local cluster with the default Ingress Controller (Traefik) disabled:

```bash
k3d cluster create gitops-poc \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"
```

### 2. Install ArgoCD
Create the namespace, apply the manifests, and wait for the pods to be ready:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD pods to start
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s
```

### 3. Access the ArgoCD API/UI
Expose the ArgoCD server API/UI on port `9090`:

```bash
kubectl port-forward svc/argocd-server -n argocd 9090:443 &
```

Retrieve the temporary admin password:

**For Bash / Zsh:**
```bash
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Password: $ARGOCD_PASS"
```

**For Fish:**
```fish
set ARGOCD_PASS (kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Password: $ARGOCD_PASS"
```

Log in using the CLI:

```bash
argocd login localhost:9090 --username admin --password $ARGOCD_PASS --insecure
```

You can now also access the web UI at `https://localhost:9090` (User: `admin`).

---

## Deploying via GitOps (App-of-Apps)

1. Fork this repository and clone it to your local machine.
2. In infra/argocd-apps/app-of-apps.yaml, update the `repoURL` to point to your fork.
3. Apply the root application:

```bash
kubectl apply -f infra/argocd-apps/app-of-apps.yaml
```

Once applied, the root application will automatically detect, build, and deploy both the `dev` and `staging` versions of the demo application.

You can monitor the sync status with:
```bash
argocd app list
```

---

## Secrets Management (Sealed Secrets)

To manage sensitive data securely inside Git, we use **Sealed Secrets**. The secret is encrypted locally using the public key of the cluster, producing a `SealedSecret` resource which is safe to commit. The controller in the cluster then decrypts it back into a standard `Secret`.

### 1. Install Sealed Secrets Controller
Install the controller in the `kube-system` namespace:

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.37.0/controller.yaml
kubectl wait --for=condition=Ready pods -l name=sealed-secrets-controller -n kube-system --timeout=90s
```

### 2. Install kubeseal CLI Locally
Download and install the `kubeseal` CLI to encrypt secrets:

```bash
# Download for Linux AMD64
curl -L -o kubeseal.tar.gz https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.37.0/kubeseal-0.37.0-linux-amd64.tar.gz
tar -xvzf kubeseal.tar.gz kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm kubeseal kubeseal.tar.gz
```

### 3. Generate and Seal a Secret
Create a local raw secret (do not commit this file!) and seal it using the cluster's public key:

```bash
# Create standard secret locally
kubectl create secret generic demo-db-secret \
  --namespace dev \
  --from-literal=db-user='admin-user' \
  --from-literal=db-password='senha-secreta-banco' \
  --dry-run=client -o yaml > temp-secret.yaml

# Seal the secret
kubeseal --format=yaml < temp-secret.yaml > apps/demo-app/overlays/dev/sealed-secret-db.yaml

# Remove the temporary raw secret file immediately!
rm temp-secret.yaml
```

Once committed and pushed, ArgoCD will synchronize the `SealedSecret` resource, and the controller will automatically decrypt it to create the matching `demo-db-secret` in the `dev` namespace.

---

## Testing GitOps

### Scenario A: Automatic Sync (Git Push)
Modify the Nginx version in the deployment file:
- File: [apps/demo-app/base/deployment.yaml](file:///home/lwbaleeiro/Documents/Code/gitops-argocd-k8s/apps/demo-app/base/deployment.yaml)
- Change `image: nginx:1.25-alpine` to `image: nginx:1.27-alpine`

Commit and push your changes:
```bash
git add .
git commit -m "chore: bump nginx to 1.27-alpine"
git push origin main
```
ArgoCD will automatically sync the change in a few minutes. To force an immediate refresh:
```bash
# Note: If your port-forward connection drops or your CLI session expires, run:
# kubectl port-forward svc/argocd-server -n argocd 9090:443 &
# and then re-login with 'argocd login localhost:9090 --username admin ...'
argocd app get demo-app-dev --refresh
```

### Scenario B: Self-Healing (Manual Drift Detection)
Manually scale up the deployment in the cluster to simulate a manual drift:

```bash
kubectl scale deployment demo-app -n dev --replicas=5
```

Watch the pods in the `dev` namespace:
```bash
kubectl get pods -n dev -w
```
Since `selfHeal: true` is enabled in the configuration, ArgoCD will detect the manual drift and scale the deployment back down to `1` replica to match the Git state.

---

## Cleanup

To completely remove the local environment:

```bash
k3d cluster delete gitops-poc
```
