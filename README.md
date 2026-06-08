# Ecommerce AKS — Production Kubernetes on Azure

> **Project:** A production-grade 3-service e-commerce platform deployed on Azure Kubernetes Service (AKS), covering infrastructure-as-code, GitOps, secrets management, security, and observability.
>
> **Services:** `api-gateway` · `order-service` · `notification-service`
>
> **Stack:** AKS · Terraform · Helm · Flux · GitHub Actions · Key Vault · Workload Identity · NGINX · cert-manager · Prometheus · Azure Monitor

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [Prerequisites](#prerequisites)
4. [Step 1 — Provision Infrastructure with Terraform](#step-1--provision-infrastructure-with-terraform)
5. [Step 2 — Connect kubectl & Enable Key Vault Add-on](#step-2--connect-kubectl--enable-key-vault-add-on)
6. [Step 3 — Add Secrets to Key Vault](#step-3--add-secrets-to-key-vault)
7. [Step 4 — Apply Base Kubernetes Manifests](#step-4--apply-base-kubernetes-manifests)
8. [Step 5 — Configure Workload Identity](#step-5--configure-workload-identity)
9. [Step 6 — Build & Push Images to ACR](#step-6--build--push-images-to-acr)
10. [Step 7 — Bootstrap Flux GitOps](#step-7--bootstrap-flux-gitops)
11. [Step 8 — HTTPS Ingress with TLS](#step-8--https-ingress-with-tls)
12. [Step 9 — CI/CD Pipeline with GitHub Actions](#step-9--cicd-pipeline-with-github-actions)
13. [Step 10 — Observability](#step-10--observability)
14. [Step 11 — Test & Verify](#step-11--test--verify)
15. [Key Concepts Summary](#key-concepts-summary)

---

## Architecture Overview

```
Internet
    │
    ▼
LoadBalancer (api-gateway:80 / :443 via NGINX Ingress)
    │
    ▼
┌─────────────────────────────────────────────────────┐
│                    AKS Cluster                      │
│                                                     │
│  namespace: api-gateway                             │
│  ┌─────────────────────────────────────────────┐   │
│  │  api-gateway (Node.js/Express)              │   │
│  │  Proxies /orders → order-service            │   │
│  │  Proxies /notifications → notif-service     │   │
│  └─────────────────────────────────────────────┘   │
│         │                        │                  │
│  namespace: order-service        │                  │
│  ┌───────────────────────┐       │                  │
│  │  order-service        │       │                  │
│  │  (Node.js/Express)    │       │                  │
│  │  CRUD orders          │       │                  │
│  │  Reads KV secrets ────┼───────┼──► Key Vault     │
│  │  Calls notif-service  │       │                  │
│  └───────────────────────┘       │                  │
│         │                        │                  │
│  namespace: notification-service │                  │
│  ┌───────────────────────────────┘                  │
│  │  notification-service (Node.js/Express)          │
│  │  Receives & logs notifications                   │
│  └──────────────────────────────────────────────┘  │
│                                                     │
│  Secrets Store CSI  ──► Azure Key Vault             │
│  Workload Identity  ──► Azure AD (no passwords)     │
│  Flux GitOps        ──► Syncs from GitHub main      │
│  NGINX Ingress      ──► TLS (cert-manager)          │
│  Prometheus         ──► Metrics                     │
└─────────────────────────────────────────────────────┘
         │
         ▼
Log Analytics Workspace / Azure Monitor
```

---

## Project Structure

```
.
├── terraform/
│   └── main.tf                        # All Azure infrastructure as code
│
├── kubernetes/
│   ├── namespaces.yaml                # api-gateway, order-service, notification-service
│   ├── rbac.yaml                      # developer-readonly ClusterRole + binding
│   ├── network-policy.yaml            # order-service only accepts traffic from api-gateway
│   ├── service-account.yaml           # order-service-sa annotated with workload identity
│   ├── secretprovider.yaml            # SecretProviderClass — pulls KV secrets via CSI
│   └── orders-service.yaml            # Deployment with workload identity + secret mount
│
├── services/
│   ├── api-gateway/
│   │   ├── src/index.js               # Express proxy to order-service & notification-service
│   │   ├── package.json
│   │   └── Dockerfile
│   ├── order-service/
│   │   ├── src/index.js               # CRUD orders, reads KV secrets, calls notification-service
│   │   ├── package.json
│   │   └── Dockerfile
│   └── notification-service/
│       ├── src/index.js               # Receives and logs notifications
│       ├── package.json
│       └── Dockerfile
│
├── helm/
│   ├── api-gateway/
│   ├── order-service/
│   │   ├── values.yaml.tpl            # Template — Terraform fills in clientId and tenantId
│   │   └── templates/
│   │       ├── serviceaccount.yaml    # Annotated with UAMI client ID
│   │       ├── secretproviderclass.yaml
│   │       ├── deployment.yaml        # Workload identity label + CSI volume
│   │       └── service.yaml
│   └── notification-service/
│
└── flux/
    ├── flux-system/
    │   ├── gotk-components.yaml       # Flux controllers (auto-generated by flux bootstrap)
    │   ├── gotk-sync.yaml             # GitRepository + Kustomization (auto-generated)
    │   └── kustomization.yaml
    ├── ecommerce-kustomization.yaml   # Points Flux at ./flux/releases
    ├── kustomization.yaml             # Root kustomize — includes all releases
    ├── releases/
    │   ├── api-gateway.yaml           # HelmRelease for api-gateway
    │   ├── order-service.yaml         # HelmRelease for order-service
    │   └── notification-service.yaml  # HelmRelease for notification-service
    └── sources/
        └── gitrepository.yaml         # GitRepository CRD pointing to this repo
```

---

## Prerequisites

Before starting, ensure the following tools are installed:

```bash
az        # Azure CLI
terraform # Infrastructure as code
kubectl   # Kubernetes CLI
helm      # Kubernetes package manager
flux      # Flux GitOps CLI
```

---

## Step 1 — Provision Infrastructure with Terraform

### The Simple Explanation

Imagine you need to set up an entire office building before anyone can move in: you need the building itself (AKS), a mail room for packages (ACR for Docker images), a safe for sensitive documents (Key Vault), a security badge system (Managed Identity), and a camera system for monitoring (Log Analytics).

Terraform is the architect's blueprint. Instead of clicking through the Azure portal to build all of this manually, you write what you want in a file and Terraform builds it identically every time. If it is ever destroyed, one command rebuilds it exactly.

**Remote state** means Terraform saves its notes in Azure Blob Storage instead of your laptop — so any team member can apply changes without overwriting each other's work.

### What This Step Builds

| Resource | Name | Purpose |
|---|---|---|
| Resource Group | `ecommerce-rg` | Container for all Azure resources |
| Container Registry | `ecommerceacrdenis` (Premium) | Stores Docker images |
| AKS Cluster | `ecommerce-aks` | Kubernetes cluster, 2–5 nodes, auto-scaling |
| Log Analytics Workspace | `lawaks` | Receives cluster logs and metrics |
| User Assigned Managed Identity | `order-service-identity` | Azure identity for order-service pods |
| Federated Identity Credential | `order-service-federated` | Binds the Azure identity to the K8s service account |
| Key Vault | `ecommerce-kv-aks` | Stores secrets (postgres-password, api-key) |
| Role Assignment (AcrPull) | — | AKS nodes can pull images from ACR without passwords |
| Role Assignment (KV Secrets User) | — | order-service identity can read Key Vault secrets |
| Terraform State | `terraformecommerceaks/state` | Remote state in Azure Blob |

### The Code

```hcl
# terraform/main.tf

terraform {
  backend "azurerm" {
    subscription_id      = "39902fa6-9035-4b4f-9856-92190439f013"
    resource_group_name  = "rg-terraform"
    storage_account_name = "terraformecommerceaks"
    container_name       = "state"
    key                  = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "ecommerce-rg"
  location = "East US"
}

resource "azurerm_container_registry" "acr" {
  name                = "ecommerceacrdenis"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Premium"
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "ecommerce-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "ecommerce"

  default_node_pool {
    name                 = "system"
    vm_size              = "Standard_D2s_v3"
    auto_scaling_enabled = true
    min_count            = 2
    max_count            = 5
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    network_policy = "calico"   # enables NetworkPolicy enforcement
  }

  azure_policy_enabled      = true
  oidc_issuer_enabled       = true   # required for Workload Identity
  workload_identity_enabled = true   # required for Workload Identity

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.lawaks.id
  }
}

# AKS node pool pulls images from ACR — no Docker credentials needed
resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

# The Azure identity order-service pods will assume
resource "azurerm_user_assigned_identity" "order_service" {
  name                = "order-service-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# Trust link: this Azure identity can only be assumed by the specific K8s service account
resource "azurerm_federated_identity_credential" "order_service" {
  name                = "order-service-federated"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.order_service.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject             = "system:serviceaccount:order-service:order-service-sa"
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "ecommerce-kv-aks"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = true
  enable_rbac_authorization  = true
}

# order-service identity can read (but not write) Key Vault secrets
resource "azurerm_role_assignment" "order_service_kv" {
  principal_id         = azurerm_user_assigned_identity.order_service.principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.kv.id
}

# The operator (you, running Terraform) can create and manage secrets
resource "azurerm_role_assignment" "operator_kv" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Key Vault Secrets Officer"
  scope                = azurerm_key_vault.kv.id
}

# Terraform writes the real values into values.yaml so Helm can use them
resource "local_file" "order_service_values" {
  content = templatefile("${path.module}/../helm/order-service/values.yaml.tpl", {
    client_id     = azurerm_user_assigned_identity.order_service.client_id
    tenant_id     = data.azurerm_client_config.current.tenant_id
    keyvault_name = azurerm_key_vault.kv.name
  })
  filename = "${path.module}/../helm/order-service/values.yaml"
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.order_service.client_id
}

resource "azurerm_log_analytics_workspace" "lawaks" {
  name                = "lawaks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}
```

### Run It

```bash
cd terraform

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

---

## Step 2 — Connect kubectl & Enable Key Vault Add-on

### The Simple Explanation

After Terraform creates the cluster, your local `kubectl` does not know about it yet. The first command downloads the credentials. The second command enables the secrets store CSI driver — the plug-in that lets Kubernetes pods reach into Azure Key Vault and mount secrets as files.

**Why use the Azure add-on instead of installing the driver yourself?** AKS 1.27+ ships its own CRDs. If you install the Helm chart manually on top, there is a CRD conflict and pods fail to start. Enabling it through the Azure add-on lets Azure manage the CRDs — no conflict possible.

```bash
# Download cluster credentials into ~/.kube/config
az aks get-credentials -g ecommerce-rg -n ecommerce-aks

# Confirm nodes are ready
kubectl get nodes

# Enable the Azure Key Vault Secrets Provider add-on
az aks enable-addons \
  -g ecommerce-rg \
  -n ecommerce-aks \
  --addons azure-keyvault-secrets-provider

# Verify the CSI driver pods are running in kube-system
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
```

---

## Step 3 — Add Secrets to Key Vault

### The Simple Explanation

The safe (Key Vault) now exists, but it is empty. You put the secrets in once — by hand, securely — and from this point on no application ever handles the raw values again. Pods receive them as files at runtime.

```bash
az keyvault secret set \
  --vault-name ecommerce-kv-aks \
  --name postgres-password \
  --value "<your-db-password>"

az keyvault secret set \
  --vault-name ecommerce-kv-aks \
  --name api-key \
  --value "<your-api-key>"
```

Inside the pod, these appear as:

```
/mnt/secrets/postgres-password   ← the password string
/mnt/secrets/api-key             ← the api key string
```

---

## Step 4 — Apply Base Kubernetes Manifests

### The Simple Explanation

Think of a large office building with multiple companies on different floors. Even though they share the building (the cluster), each company has their own floor (namespace), their own key-card access (RBAC), and walls between floors so one company cannot walk into another's office (Network Policy).

- **Namespaces** — logical floors. Each service lives in its own namespace.
- **RBAC** — the key-card system. Developers get read-only access. No one gets a master key unless they need it.
- **Network Policy** — the walls. Only `api-gateway` can talk to `order-service`. All other pods are blocked at the network level.

### The Code

```yaml
# kubernetes/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: api-gateway
  labels:
    app: api-gateway   # NetworkPolicy uses this label to identify the namespace
---
apiVersion: v1
kind: Namespace
metadata:
  name: order-service
---
apiVersion: v1
kind: Namespace
metadata:
  name: notification-service
```

```yaml
# kubernetes/rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: developer-readonly
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "events"]
  verbs: ["get", "list", "watch"]   # look but don't touch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-readonly-binding
subjects:
- kind: Group
  name: "developers"
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: developer-readonly
  apiGroup: rbac.authorization.k8s.io
```

```yaml
# kubernetes/network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-gateway-only
  namespace: order-service
spec:
  podSelector: {}         # applies to ALL pods in the order-service namespace
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          app: api-gateway   # only the api-gateway namespace may send traffic in
```

### Apply Order (namespaces must exist before everything else)

```bash
kubectl apply -f kubernetes/namespaces.yaml
kubectl apply -f kubernetes/rbac.yaml
kubectl apply -f kubernetes/network-policy.yaml
```

---

## Step 5 — Configure Workload Identity

### The Simple Explanation

Instead of hardcoding passwords in your app or storing them in Kubernetes Secrets (which are just base64 strings, not encryption), the pod uses its Azure identity to fetch secrets directly from Key Vault at startup. No password is ever passed around.

**How the chain works:**

```
Pod (K8s ServiceAccount token)
  → AKS presents token to Azure AD via OIDC issuer
    → Azure AD issues access token for the Managed Identity
      → Managed Identity has RBAC on Key Vault
        → Secrets Provider CSI driver mounts secrets as files in /mnt/secrets/
```

The three components that must align:

| Component | File | What it does |
|---|---|---|
| ServiceAccount | `kubernetes/service-account.yaml` | Annotated with the Managed Identity client ID |
| SecretProviderClass | `kubernetes/secretprovider.yaml` | Declares which Key Vault secrets to fetch |
| Deployment label | `kubernetes/orders-service.yaml` | `azure.workload.identity/use: "true"` triggers OIDC token injection |

### Get Required Values from Terraform

```bash
WORKLOAD_IDENTITY_CLIENT_ID=$(terraform -chdir=terraform output -raw workload_identity_client_id)
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
KEYVAULT_NAME="ecommerce-kv-aks"

echo "Client ID : $WORKLOAD_IDENTITY_CLIENT_ID"
echo "Tenant ID : $AZURE_TENANT_ID"
```

### The Code

```yaml
# kubernetes/service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-service-sa
  namespace: order-service
  annotations:
    azure.workload.identity/client-id: "<WORKLOAD_IDENTITY_CLIENT_ID>"
```

```yaml
# kubernetes/secretprovider.yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: order-service-secrets
  namespace: order-service
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "<WORKLOAD_IDENTITY_CLIENT_ID>"
    keyvaultName: "ecommerce-kv-aks"
    tenantId: "<AZURE_TENANT_ID>"
    objects: |
      array:
        - |
          objectName: postgres-password
          objectType: secret
        - |
          objectName: api-key
          objectType: secret
```

```yaml
# kubernetes/orders-service.yaml (key sections)
spec:
  template:
    metadata:
      labels:
        app: order-service
        azure.workload.identity/use: "true"   # triggers OIDC token injection into the pod
    spec:
      serviceAccountName: order-service-sa
      volumes:
      - name: secrets-store
        csi:
          driver: secrets-store.csi.k8s.io
          readOnly: true
          volumeAttributes:
            secretProviderClass: "order-service-secrets"
      containers:
      - name: order-service
        image: ecommerceacrdenis.azurecr.io/order-service:latest
        volumeMounts:
        - name: secrets-store
          mountPath: "/mnt/secrets"
          readOnly: true
```

### Apply

```bash
kubectl apply -f kubernetes/service-account.yaml
kubectl apply -f kubernetes/secretprovider.yaml
kubectl apply -f kubernetes/orders-service.yaml
```

---

## Step 6 — Build & Push Images to ACR

### The Simple Explanation

Each service needs to be packaged into a Docker image and stored in the container registry before Kubernetes can run it. `az acr build` sends the source code up to Azure and runs the Docker build there — no local Docker daemon required.

```bash
# Build and push all three services
az acr build --registry ecommerceacrdenis \
  --image api-gateway:latest          services/api-gateway

az acr build --registry ecommerceacrdenis \
  --image order-service:latest        services/order-service

az acr build --registry ecommerceacrdenis \
  --image notification-service:latest services/notification-service
```

Or use the provided script to build and tag by commit SHA:

```bash
./build.sh $(git rev-parse --short HEAD)
```

Each service uses the same Dockerfile pattern:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY src/ ./src/
EXPOSE <port>
CMD ["node", "src/index.js"]
```

---

## Step 7 — Bootstrap Flux GitOps

### The Simple Explanation

Manual `helm install` works once, but what happens when you push a change to Git? Someone has to remember to run `helm upgrade`. Flux solves this by watching the Git repository continuously. The moment you merge a change to `main`, Flux detects it and reconciles the cluster to match — automatically, without human intervention.

**Flux is the robot that keeps the cluster in sync with the Git repository.**

How it works:

```
You push code to GitHub (main branch)
  → Flux polls GitHub every 1 minute
    → Detects a diff in ./flux
      → Applies the updated HelmRelease
        → Helm upgrades the deployment
          → New pods roll out, old pods terminate
```

### The Flux Resource Hierarchy

```
GitRepository (flux-system)        ← points at this GitHub repo, branch: main
  └── Kustomization (flux-system)  ← watches ./flux every 10 minutes
        ├── Kustomization (ecommerce-releases)   ← watches ./flux/releases
        │     ├── HelmRelease: api-gateway        ← deploys helm/api-gateway
        │     ├── HelmRelease: order-service      ← deploys helm/order-service
        │     └── HelmRelease: notification-service
        └── GitRepository (ecommerce-platform)   ← additional source reference
```

### Bootstrap

`flux bootstrap` creates the SSH deploy key, registers it in GitHub, and commits the Flux controllers into `flux/flux-system/` in this repo. After bootstrap, Flux manages itself from Git.

```bash
# Export a GitHub Personal Access Token with repo permissions
export GITHUB_TOKEN=<your-pat>

flux bootstrap github \
  --owner=denisdbell \
  --repository=ecommerceaks \
  --branch=main \
  --path=./flux \
  --personal
```

Flux will:
1. Create the `flux-system` namespace
2. Install the Flux controllers (source-controller, kustomize-controller, helm-controller)
3. Generate an SSH deploy key and add it to the GitHub repository
4. Commit `flux/flux-system/gotk-components.yaml` and `gotk-sync.yaml` to `main`
5. Begin reconciling immediately

### Verify Flux is Reconciling

```bash
# Watch all Flux resources across the cluster
flux get all

# Watch HelmReleases specifically
flux get helmreleases -A

# Follow Flux logs in real time
flux logs --follow

# Force an immediate reconciliation (skip the 1-minute poll interval)
flux reconcile source git flux-system
```

### The Flux Manifests in This Repo

```yaml
# flux/flux-system/gotk-sync.yaml (auto-generated by flux bootstrap)
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 1m0s
  ref:
    branch: main
  secretRef:
    name: flux-system     # the SSH key Flux generated
  url: ssh://git@github.com/denisdbell/ecommerceaks
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m0s
  path: ./flux
  prune: true             # deletes resources removed from Git
  sourceRef:
    kind: GitRepository
    name: flux-system
```

```yaml
# flux/ecommerce-kustomization.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ecommerce-releases
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./flux/releases
  prune: true    # delete resources removed from git
  wait: true     # wait for all resources to become ready before proceeding
```

```yaml
# flux/releases/order-service.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: order-service
  namespace: flux-system
spec:
  interval: 5m
  targetNamespace: order-service
  chart:
    spec:
      chart: ./helm/order-service
      sourceRef:
        kind: GitRepository
        name: flux-system
        namespace: flux-system
      interval: 1m
  values:
    image:
      repository: ecommerceacrdenis.azurecr.io/order-service
      tag: 7f17d7da3a4944c2987943c822f62183444b1649
    replicaCount: 2
```

### Updating a Deployment via GitOps

To deploy a new image, update the `tag` in the appropriate `flux/releases/*.yaml` and push to `main`. Flux detects the change and rolls out the new version within 1 minute.

```bash
# Update the image tag in the HelmRelease
sed -i '' 's/tag: .*/tag: <new-sha>/' flux/releases/order-service.yaml
git add flux/releases/order-service.yaml
git commit -m "chore: update order-service image to <new-sha>"
git push origin main

# Flux picks this up automatically — watch it happen
flux get helmreleases -A --watch
```

---

## Step 8 — HTTPS Ingress with TLS

### The Simple Explanation

Right now `api-gateway` is exposed over plain HTTP via a LoadBalancer. For production you want HTTPS. NGINX Ingress Controller acts as the single front door — all external traffic enters here and is routed to the right service. cert-manager automatically provisions a free TLS certificate from Let's Encrypt and renews it before it expires.

### Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
```

### Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
```

### ClusterIssuer (Let's Encrypt)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

### Ingress Resource

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ecommerce-ingress
  namespace: api-gateway
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - api.yourdomain.com
    secretName: ecommerce-tls
  rules:
  - host: api.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api-gateway
            port:
              number: 80
```

---

## Step 9 — CI/CD Pipeline with GitHub Actions

### The Simple Explanation

The GitOps loop handles *deploying* what is in Git. CI/CD handles *building* and *testing* before anything reaches Git. The pipeline builds new images, pushes them to ACR, then updates the image tag in `flux/releases/` — which triggers Flux to deploy.

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Azure Login
      uses: azure/login@v1
      with:
        creds: ${{ secrets.AZURE_CREDENTIALS }}

    - name: Build and push images to ACR
      run: |
        az acr build --registry ecommerceacrdenis \
          --image api-gateway:${{ github.sha }}          services/api-gateway
        az acr build --registry ecommerceacrdenis \
          --image order-service:${{ github.sha }}        services/order-service
        az acr build --registry ecommerceacrdenis \
          --image notification-service:${{ github.sha }} services/notification-service

    - name: Update image tags in flux/releases
      run: |
        sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/api-gateway.yaml
        sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/order-service.yaml
        sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/notification-service.yaml
        git config user.email "ci@github.com"
        git config user.name "GitHub Actions"
        git add flux/releases/
        git commit -m "chore: update image tags to ${{ github.sha }}"
        git push origin main
        # Flux detects the push and rolls out the new version automatically
```

---

## Step 10 — Observability

### Container Insights (enabled via Terraform)

Logs from all pods flow automatically to the Log Analytics Workspace `lawaks`. No configuration needed — Terraform's `oms_agent` block wired this up in Step 1.

```bash
# Query logs from Azure Monitor
az monitor log-analytics query \
  --workspace lawaks \
  --analytics-query "ContainerLog | where LogEntry contains 'error' | limit 50"
```

### Prometheus & Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
```

### Key Metrics to Watch

| Metric | What it signals |
|---|---|
| `container_cpu_usage_seconds_total` | CPU pressure per pod |
| `container_memory_working_set_bytes` | Memory usage per pod |
| `http_requests_total` | Request volume per service |
| `http_request_duration_seconds` | Latency per endpoint |

---

## Step 11 — Test & Verify

### End-to-End Flow

```bash
GATEWAY_IP=$(kubectl get svc api-gateway -n api-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Health checks on all services
curl http://$GATEWAY_IP/health

# Create an order — this triggers notification-service automatically
curl -X POST http://$GATEWAY_IP/orders \
  -H "Content-Type: application/json" \
  -d '{"item": "widget", "qty": 2}'

# List orders
curl http://$GATEWAY_IP/orders

# Confirm notification-service received the event
kubectl logs -n notification-service deploy/notification-service
```

### Verify Workload Identity is Working

```bash
# order-service logs this on startup if secrets mounted correctly
kubectl logs -n order-service deploy/order-service | grep "Secrets loaded"
# Expected: Secrets loaded — db: yes, api-key: yes
```

### Verify Network Policy is Blocking Lateral Traffic

```bash
# This should be blocked — notification-service is not api-gateway
kubectl run test --image=busybox -n notification-service --rm -it -- \
  wget -qO- http://order-service.order-service.svc.cluster.local:3001/health
# Expected: request hangs then times out
```

### Verify Flux is Reconciling

```bash
flux get all -A
# All resources should show: Applied revision: main/<latest-sha>
```

---

## Key Concepts Summary

| Concept | What it is | Why it matters |
|---|---|---|
| Terraform remote state | State stored in Azure Blob Storage | Team can share state; no local `tfstate` files |
| OIDC issuer | AKS publishes a JWT verification endpoint | Azure AD can validate Kubernetes service account tokens without a shared secret |
| Federated credential | Trust link between UAMI and a specific K8s ServiceAccount | No secret is ever exchanged — pure identity federation |
| Workload Identity | Pod assumes an Azure identity via token exchange | Passwordless access to any Azure service (Key Vault, Storage, etc.) |
| SecretProviderClass | CSI driver configuration for which Key Vault secrets to mount | Secrets appear as files — no Kubernetes Secret objects needed, nothing stored in etcd in plaintext |
| Key Vault Secrets Provider add-on | Azure-managed CSI driver | Avoids CRD conflicts with AKS 1.27+; Azure manages lifecycle |
| Network Policy | Kubernetes firewall rules between pods | Blast-radius containment — a compromised pod cannot reach other services |
| RBAC | Role-based permissions on the Kubernetes API | Least-privilege access for developers and CI/CD service accounts |
| Helm | Package manager for Kubernetes | Single source of truth for Kubernetes config; parameterised per environment |
| Flux GitOps | Continuous reconciliation from Git to cluster | Cluster state is always what Git says it should be; no manual `helm upgrade` needed |
| `prune: true` (Flux) | Flux deletes resources removed from Git | Drift prevention — orphaned resources cannot accumulate |
| `wait: true` (Flux Kustomization) | Flux waits for health before proceeding | Prevents a bad release from being considered successful |
