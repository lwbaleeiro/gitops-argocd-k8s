# POC: GitOps com ArgoCD + K3d

Objetivo: demonstrar um fluxo GitOps completo end-to-end — qualquer push no repositório dispara sync automático no cluster local. 100% free, roda na sua máquina com CachyOS + Fish.

---

## Arquitetura da POC

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Repository                                              │
│  ├── apps/                  ← manifestos das aplicações         │
│  │   └── demo-app/          ← Deployment, Service, Ingress      │
│  └── infra/                 ← configurações de infra/ArgoCD     │
│      └── argocd-apps/       ← App-of-Apps pattern              │
└────────────────┬────────────────────────────────────────────────┘
                 │  git pull (polling 3min ou webhook)
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  K3d Cluster (local, Docker)                                    │
│  ├── argocd namespace       ← ArgoCD controller + UI           │
│  ├── dev namespace          ← demo-app (env: dev)              │
│  └── staging namespace      ← demo-app (env: staging)          │
└─────────────────────────────────────────────────────────────────┘
```

**O que será demonstrado:**
- Cluster K8s local com K3d (K3s dentro de Docker)
- ArgoCD monitorando o repositório Git
- Deploy automático ao fazer push de um manifesto
- Multi-environment: dev e staging com Kustomize overlays
- App-of-Apps pattern para gerenciar múltiplas aplicações
- Self-healing: ArgoCD reverte mudanças manuais no cluster

---

## Pré-requisitos

```fish
# Verificar dependências
docker --version       # Docker 24+
kubectl version        # kubectl 1.28+
k3d --version          # K3d 5.6+
helm version           # Helm 3.12+
```

### Instalação das ferramentas (CachyOS)

```fish
# K3d
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# kubectl (provavelmente já tem, mas garantindo)
sudo pacman -S kubectl

# Helm
sudo pacman -S helm

# ArgoCD CLI
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
```

---

## Estrutura do Repositório

```
gitops-poc/
├── README.md
├── apps/
│   └── demo-app/
│       ├── base/
│       │   ├── kustomization.yaml
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── ingress.yaml
│       └── overlays/
│           ├── dev/
│           │   ├── kustomization.yaml
│           │   └── patch-replicas.yaml
│           └── staging/
│               ├── kustomization.yaml
│               └── patch-replicas.yaml
└── infra/
    └── argocd-apps/
        ├── app-of-apps.yaml
        ├── demo-app-dev.yaml
        └── demo-app-staging.yaml
```

---

## Passo 1 — Criar o cluster K3d

```fish
# Cluster com 1 server + 2 agents + ingress controller exposto
k3d cluster create gitops-poc \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"

# Verificar
kubectl get nodes
# NAME                       STATUS   ROLES                  AGE
# k3d-gitops-poc-server-0    Ready    control-plane,master   30s
# k3d-gitops-poc-agent-0     Ready    <none>                 25s
# k3d-gitops-poc-agent-1     Ready    <none>                 25s
```

---

## Passo 2 — Instalar o ArgoCD

```fish
# Criar namespace e instalar
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Aguardar todos os pods ficarem Ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=120s

# Expor a UI localmente (use um terminal dedicado para isso)
kubectl port-forward svc/argocd-server -n argocd 9090:443 &

# Pegar a senha inicial do admin
set ARGOCD_PASS (kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Senha ArgoCD: $ARGOCD_PASS"

# Login via CLI
argocd login localhost:9090 --username admin --password $ARGOCD_PASS --insecure
```

Acesse a UI em: **https://localhost:9090** (usuário: `admin`)

---

## Passo 3 — Criar os manifestos da aplicação

### `apps/demo-app/base/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  labels:
    app: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo-app
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          env:
            - name: ENVIRONMENT
              valueFrom:
                configMapKeyRef:
                  name: demo-app-config
                  key: environment
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-app-config
data:
  environment: "base"
```

### `apps/demo-app/base/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-app
spec:
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 80
```

### `apps/demo-app/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

### `apps/demo-app/overlays/dev/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: dev
resources:
  - ../../base
patches:
  - path: patch-replicas.yaml
configMapGenerator:
  - name: demo-app-config
    behavior: merge
    literals:
      - environment=dev
```

### `apps/demo-app/overlays/dev/patch-replicas.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  replicas: 1
```

### `apps/demo-app/overlays/staging/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: staging
resources:
  - ../../base
patches:
  - path: patch-replicas.yaml
configMapGenerator:
  - name: demo-app-config
    behavior: merge
    literals:
      - environment=staging
```

### `apps/demo-app/overlays/staging/patch-replicas.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  replicas: 2
```

---

## Passo 4 — App-of-Apps pattern

Este pattern é a forma profissional de gerenciar múltiplas aplicações no ArgoCD. Uma "app pai" gerencia todas as "apps filhas".

### `infra/argocd-apps/demo-app-dev.yaml`

```yaml
# Substitua SEU_USUARIO pelo seu usuário do GitHub
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app-dev
  namespace: argocd
  labels:
    environment: dev
spec:
  project: default
  source:
    repoURL: https://github.com/SEU_USUARIO/gitops-poc
    targetRevision: HEAD
    path: apps/demo-app/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true       # remove recursos deletados do Git
      selfHeal: true    # reverte mudanças manuais no cluster
    syncOptions:
      - CreateNamespace=true
```

### `infra/argocd-apps/demo-app-staging.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app-staging
  namespace: argocd
  labels:
    environment: staging
spec:
  project: default
  source:
    repoURL: https://github.com/SEU_USUARIO/gitops-poc
    targetRevision: HEAD
    path: apps/demo-app/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### `infra/argocd-apps/app-of-apps.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/SEU_USUARIO/gitops-poc
    targetRevision: HEAD
    path: infra/argocd-apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Passo 5 — Ativar o App-of-Apps

```fish
# Aplicar apenas o app-of-apps — ele cuida do resto
kubectl apply -f infra/argocd-apps/app-of-apps.yaml

# Acompanhar o sync
argocd app list
# NAME               CLUSTER     NAMESPACE  PROJECT  STATUS  HEALTH
# app-of-apps        in-cluster  argocd     default  Synced  Healthy
# demo-app-dev       in-cluster  dev        default  Synced  Healthy
# demo-app-staging   in-cluster  staging    default  Synced  Healthy

# Ver detalhes de uma app
argocd app get demo-app-dev
```

---

## Passo 6 — Demonstrar o GitOps em ação

### Cenário 1: Deploy via push no Git

```fish
# Mudar a versão da imagem no overlay de dev
sed -i 's/nginx:1.25-alpine/nginx:1.27-alpine/' apps/demo-app/base/deployment.yaml

git add .
git commit -m "chore: bump nginx to 1.27-alpine"
git push origin main

# Aguardar ~3 minutos (polling padrão) e observar
argocd app get demo-app-dev --refresh
kubectl get pods -n dev -w
```

### Cenário 2: Self-healing — ArgoCD revertendo mudança manual

```fish
# Fazer uma mudança manual no cluster (drift)
kubectl scale deployment demo-app -n dev --replicas=5

# Observar o ArgoCD detectar e reverter (< 3 min)
kubectl get pods -n dev -w
# Em instantes volta para 1 replica, pois selfHeal: true
```

### Cenário 3: Scale em staging via Git

```fish
# Editar o patch de staging
# patch-replicas.yaml: replicas: 3

git add .
git commit -m "feat: scale staging to 3 replicas"
git push origin main

# Verificar
kubectl get pods -n staging
```

---

## Dicas para o portfólio

### README.md — estrutura sugerida

```markdown
# GitOps POC — ArgoCD + K3d

Demonstração de um fluxo GitOps completo com ArgoCD gerenciando
dois ambientes (dev e staging) em cluster K3s local via K3d.

## Conceitos demonstrados
- App-of-Apps pattern
- Multi-environment com Kustomize overlays
- Sync automatizado com pruning e self-healing
- Cluster local zero-cost com K3d

## Como rodar
[passos de setup...]

## Screenshots
[adicionar screenshots da UI do ArgoCD mostrando apps Synced/Healthy]
```

### O que capturar para o portfólio

1. **Screenshot da UI do ArgoCD** com app-of-apps mostrando as apps filhas Synced + Healthy
2. **GIF ou vídeo curto** mostrando o self-healing: você escala manualmente e o ArgoCD reverte
3. **Link do repositório público** bem documentado no GitHub

---

## Evolução futura (para enriquecer ainda mais)

| Evolução | Complexidade | Impacto |
|---|---|---|
| Adicionar Sealed Secrets para gerenciar secrets no Git | Baixa | Alto |
| Webhook GitHub → sync imediato ao invés de polling | Baixa | Médio |
| Adicionar ApplicationSet para gerar apps dinamicamente | Média | Alto |
| Integrar com pipeline CI (GitHub Actions build + push de imagem) | Média | Alto |
| Adicionar Prometheus + Grafana para observabilidade | Média | Alto |
| Progressivo: Argo Rollouts com canary deploy | Alta | Muito alto |

---

## Limpeza

```fish
# Remover o cluster ao terminar
k3d cluster delete gitops-poc
```
