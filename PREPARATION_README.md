# Ecommerce AKS — End-to-End Azure Kubernetes Deployment

> **Project:** A production-grade 3-service e-commerce platform deployed on Azure Kubernetes Service (AKS), covering infrastructure-as-code, Helm, CI/CD, security, and observability.
>
> **Services:** `api-gateway` · `order-service` · `notification-service`
>
> **Stack:** AKS · Terraform · Helm · GitHub Actions · Key Vault · Workload Identity · NGINX · cert-manager · Prometheus · Azure Monitor

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [Step 1 — Provision AKS with Terraform](#step-1--provision-aks-with-terraform)
4. [Step 2 — Namespaces, RBAC & Network Policy](#step-2--namespaces-rbac--network-policy)
5. [Step 3 — Key Vault Secrets via Workload Identity](#step-3--key-vault-secrets-via-workload-identity)
6. [Step 4 — Services & Helm Charts](#step-4--services--helm-charts)
7. [Step 5 — Build & Push Images to ACR](#step-5--build--push-images-to-acr)
8. [Step 6 — Deploy with Helm](#step-6--deploy-with-helm)
9. [Step 7 — HTTPS Ingress with TLS](#step-7--https-ingress-with-tls)
10. [Step 8 — CI/CD Pipeline with GitHub Actions](#step-8--cicd-pipeline-with-github-actions)
11. [Step 9 — Observability](#step-9--observability)
12. [Step 10 — Test & Verify](#step-10--test--verify)

---

## Architecture Overview

```
Internet
    │
    ▼
LoadBalancer (api-gateway:80)
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
│  │  Reads KV secrets     │───────┼──► Key Vault     │
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
│   └── main.tf                        # All Azure infrastructure
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
└── helm/
    ├── api-gateway/
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── deployment.yaml
    │       └── service.yaml           # type: LoadBalancer
    ├── order-service/
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── deployment.yaml        # workload identity label + secret volume
    │       ├── service.yaml
    │       ├── serviceaccount.yaml    # annotated with UAMI client ID
    │       └── secretproviderclass.yaml
    └── notification-service/
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── deployment.yaml
            └── service.yaml
```

---

## Step 1 — Provision AKS with Terraform

### The Simple Explanation

Terraform is a blueprint for your cloud infrastructure. Instead of clicking through the Azure portal, you write what you want in a file and Terraform builds it identically every time. If it's destroyed, `terraform apply` rebuilds it exactly.

AKS is a managed Kubernetes cluster — Azure runs the control plane and you run workloads on top. Managed Identity means your cluster proves who it is to other Azure services without storing any passwords anywhere.

### What This Step Builds

| Resource | Name | Purpose |
|---|---|---|
| Resource Group | `ecommerce-rg` | Container for all resources |
| Container Registry | `ecommerceacrdenis` (Premium) | Stores Docker images |
| AKS Cluster | `ecommerce-aks` | Runs the workloads |
| Log Analytics Workspace | `lawaks` | Receives cluster logs |
| User Assigned Managed Identity | `order-service-identity` | Pod identity for Key Vault access |
| Key Vault | `ecommerce-kv-aks` | Stores postgres-password and api-key |
| Terraform State | `terraformecommerceaks/state` | Remote state in Azure Blob Storage |

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
    network_policy = "calico"
  }

  azure_policy_enabled      = true
  oidc_issuer_enabled       = true       # required for workload identity
  workload_identity_enabled = true       # required for workload identity

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.lawaks.id
  }
}

# ACR pull permission for the cluster's node pool identity
resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

# User Assigned Managed Identity for order-service workload identity
resource "azurerm_user_assigned_identity" "order_service" {
  name                = "order-service-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# Federate the identity to the Kubernetes service account in order-service namespace
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

# Grant the UAMI read access to Key Vault secrets
resource "azurerm_role_assignment" "order_service_kv" {
  principal_id         = azurerm_user_assigned_identity.order_service.principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.kv.id
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
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Connect kubectl to the cluster
az aks get-credentials -g ecommerce-rg -n ecommerce-aks
kubectl get nodes

# Add secrets to Key Vault
az keyvault secret set --vault-name ecommerce-kv-aks --name postgres-password --value "<value>"
az keyvault secret set --vault-name ecommerce-kv-aks --name api-key --value "<value>"

# Capture the UAMI client ID for later use
terraform output -raw workload_identity_client_id
```

---

## Step 2 — Namespaces, RBAC & Network Policy

### The Simple Explanation

Think of a large office building with multiple companies on different floors. Even though they share the building (the cluster), each company has their own floor (namespace), their own key card access (RBAC), and walls between floors so one company cannot walk into another's office (Network Policy).

- **Namespaces** — logical partitions. Each service lives in its own namespace.
- **RBAC** — key card system. Developers get read-only access. Nobody gets a master key unless needed.
- **Network Policy** — the walls. Only `api-gateway` can send traffic to `order-service`. All other pods are blocked.

### The Code

```yaml
# kubernetes/namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: api-gateway
  labels:
    app: api-gateway   # used by NetworkPolicy namespaceSelector
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
  verbs: ["get", "list", "watch"]
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
  podSelector: {}         # applies to ALL pods in order-service namespace
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          app: api-gateway    # only the api-gateway namespace can send traffic in
```

### Apply Order

```bash
kubectl apply -f kubernetes/namespaces.yaml
kubectl apply -f kubernetes/rbac.yaml
kubectl apply -f kubernetes/network-policy.yaml
```

---

## Step 3 — Key Vault Secrets via Workload Identity

### The Simple Explanation

Instead of hardcoding passwords in your app or storing them in Kubernetes Secrets (which are just base64-encoded, not encrypted), you store them in Azure Key Vault. The pod fetches them at startup using its Azure identity — no password is ever passed around.

**Workload Identity** is the mechanism that makes this passwordless. The chain works like this:

```
Pod (K8s ServiceAccount token)
  → Azure AD validates token via AKS OIDC issuer
    → Issues access token for the managed identity
      → Managed identity has RBAC on Key Vault
        → Secrets mounted as files in /mnt/secrets/
```

### The Components

| Component | File | What it does |
|---|---|---|
| ServiceAccount | `kubernetes/service-account.yaml` | Annotated with UAMI client ID |
| SecretProviderClass | `kubernetes/secretprovider.yaml` | Declares which KV secrets to fetch |
| Deployment label | `kubernetes/orders-service.yaml` | `azure.workload.identity/use: "true"` triggers token injection |
| UAMI | Terraform | The Azure identity the pod assumes |
| Federated Credential | Terraform | Links the UAMI to the K8s service account |
| Role Assignment | Terraform | Grants UAMI read on Key Vault |

### The Code

```yaml
# kubernetes/service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-service-sa
  namespace: order-service
  annotations:
    azure.workload.identity/client-id: "<workload_identity_client_id>"
```

### Getting the Required Variables

Before applying, you need two values. Both are retrieved after `terraform apply` completes.

**`WORKLOAD_IDENTITY_CLIENT_ID`** — the client ID of the User Assigned Managed Identity:

```bash
terraform output -raw workload_identity_client_id
# or directly from Azure:
az identity show \
  --name order-service-identity \
  --resource-group ecommerce-rg \
  --query clientId -o tsv
```

**`AZURE_TENANT_ID`** — your Azure AD tenant ID:

```bash
az account show --query tenantId -o tsv
```

Substitute both into the manifests before applying:

```bash
WORKLOAD_IDENTITY_CLIENT_ID=$(terraform output -raw workload_identity_client_id)
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

sed -i '' "s|\${WORKLOAD_IDENTITY_CLIENT_ID}|$WORKLOAD_IDENTITY_CLIENT_ID|g" kubernetes/secretprovider.yaml
sed -i '' "s|\${AZURE_TENANT_ID}|$AZURE_TENANT_ID|g"                         kubernetes/secretprovider.yaml
sed -i '' "s|\${WORKLOAD_IDENTITY_CLIENT_ID}|$WORKLOAD_IDENTITY_CLIENT_ID|g" kubernetes/service-account.yaml
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
    clientID: "${WORKLOAD_IDENTITY_CLIENT_ID}"   # → terraform output -raw workload_identity_client_id
    keyvaultName: "ecommerce-kv-aks"
    tenantId: "${AZURE_TENANT_ID}"               # → az account show --query tenantId -o tsv
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
        azure.workload.identity/use: "true"   # triggers OIDC token injection
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
        volumeMounts:
        - name: secrets-store
          mountPath: "/mnt/secrets"
          readOnly: true
```

### Secrets are available inside the pod as files

```
/mnt/secrets/postgres-password   ← content is the password string
/mnt/secrets/api-key             ← content is the api key string
```

### Apply Order

```bash
kubectl apply -f kubernetes/service-account.yaml
kubectl apply -f kubernetes/secretprovider.yaml
kubectl apply -f kubernetes/orders-service.yaml
```

---

## Step 4 — Services & Helm Charts

### The Simple Explanation

Each service is a Node.js/Express app. They communicate over HTTP using Kubernetes DNS (`service-name.namespace.svc.cluster.local`). Helm packages all the Kubernetes YAML for each service into a reusable chart with a `values.yaml` for configuration — no more copy-pasting YAML between environments.

### Service Responsibilities

| Service | Port | Responsibility |
|---|---|---|
| `api-gateway` | 3000 | External entry point. Proxies `/orders` and `/notifications` to the downstream services. |
| `order-service` | 3001 | CRUD for orders. Reads secrets from `/mnt/secrets`. Calls notification-service after each order is created. |
| `notification-service` | 3002 | Receives notification events and logs them. |

### api-gateway — src/index.js

```js
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 3000;

const ORDER_SERVICE_URL        = process.env.ORDER_SERVICE_URL        || 'http://order-service.order-service.svc.cluster.local:3001';
const NOTIFICATION_SERVICE_URL = process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service.notification-service.svc.cluster.local:3002';

app.get('/health', (req, res) => res.json({ status: 'ok' }));
app.use('/orders',        createProxyMiddleware({ target: ORDER_SERVICE_URL,        changeOrigin: true }));
app.use('/notifications', createProxyMiddleware({ target: NOTIFICATION_SERVICE_URL, changeOrigin: true }));

app.listen(PORT, () => console.log(`API Gateway running on port ${PORT}`));
```

### order-service — src/index.js

```js
const express = require('express');
const axios   = require('axios');
const fs      = require('fs');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3001;
const NOTIFICATION_SERVICE_URL = process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service.notification-service.svc.cluster.local:3002';

const getSecret = (name) => {
  try {
    return fs.readFileSync(`/mnt/secrets/${name}`, 'utf8').trim();
  } catch {
    return process.env[name.toUpperCase().replace(/-/g, '_')] || '';
  }
};

const orders = [];  // replace with postgres in production

app.get('/health',       (req, res) => res.json({ status: 'ok' }));
app.get('/orders',       (req, res) => res.json(orders));
app.get('/orders/:id',   (req, res) => {
  const order = orders.find(o => o.id === req.params.id);
  if (!order) return res.status(404).json({ error: 'Order not found' });
  res.json(order);
});
app.patch('/orders/:id', (req, res) => {
  const idx = orders.findIndex(o => o.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Order not found' });
  orders[idx] = { ...orders[idx], ...req.body };
  res.json(orders[idx]);
});
app.post('/orders', async (req, res) => {
  const order = { id: Date.now().toString(), ...req.body, status: 'created', createdAt: new Date().toISOString() };
  orders.push(order);
  try {
    await axios.post(`${NOTIFICATION_SERVICE_URL}/notify`, { type: 'order_created', orderId: order.id, message: `Order ${order.id} created` });
  } catch (err) {
    console.error('Notification failed:', err.message);
  }
  res.status(201).json(order);
});

app.listen(PORT, () => {
  console.log(`Order Service running on port ${PORT}`);
  console.log(`Secrets loaded — db: ${getSecret('postgres-password') ? 'yes' : 'no'}, api-key: ${getSecret('api-key') ? 'yes' : 'no'}`);
});
```

### notification-service — src/index.js

```js
const express = require('express');
const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3002;
const notifications = [];

app.get('/health',          (req, res) => res.json({ status: 'ok' }));
app.get('/notifications',   (req, res) => res.json(notifications));
app.post('/notify', (req, res) => {
  const n = { id: Date.now().toString(), ...req.body, receivedAt: new Date().toISOString() };
  notifications.push(n);
  console.log(`[NOTIFICATION] type=${n.type} orderId=${n.orderId} — ${n.message}`);
  res.status(202).json({ received: true, id: n.id });
});

app.listen(PORT, () => console.log(`Notification Service running on port ${PORT}`));
```

### Helm Chart Structure

Each chart follows the same pattern. The order-service chart is the most complex because it includes workload identity.

```
helm/order-service/
├── Chart.yaml
├── values.yaml                    ← clientId, keyVault name/tenantId here
└── templates/
    ├── serviceaccount.yaml        ← annotated with workload identity client ID
    ├── secretproviderclass.yaml   ← declares which KV secrets to mount
    ├── deployment.yaml            ← workload identity label + CSI volume
    └── service.yaml               ← ClusterIP on port 3001
```

Key sections of `helm/order-service/values.yaml`:

```yaml
workloadIdentity:
  clientId: "3338177c-ce6c-4fa4-862d-4379ae6b90d3"

keyVault:
  name: "ecommerce-kv-aks"
  tenantId: "8af2a7d4-d3a6-44ab-8818-f84ba51bd431"
```

---

## Step 5 — Build & Push Images to ACR

```bash
# Build and push all three services
az acr build --registry ecommerceacrdenis --image api-gateway:latest          services/api-gateway
az acr build --registry ecommerceacrdenis --image order-service:latest        services/order-service
az acr build --registry ecommerceacrdenis --image notification-service:latest services/notification-service
```

Each Dockerfile uses the same pattern:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY src/ ./src/
EXPOSE <port>
CMD ["node", "src/index.js"]
```

`az acr build` runs the build in Azure — no local Docker daemon required.

---

## Step 6 — Deploy with Helm

### Prerequisites — namespaces must exist first

```bash
kubectl apply -f kubernetes/namespaces.yaml
kubectl apply -f kubernetes/rbac.yaml
kubectl apply -f kubernetes/network-policy.yaml
```

### Install Charts

```bash
# notification-service first — order-service calls it on startup
helm install notification-service helm/notification-service -n notification-service

# order-service — depends on Key Vault secrets and notification-service
helm install order-service helm/order-service -n order-service

# api-gateway last — depends on both downstream services
helm install api-gateway helm/api-gateway -n api-gateway
```

### Upgrade after changes

```bash
helm upgrade order-service helm/order-service -n order-service
```

### Verify

```bash
kubectl get pods -A
kubectl logs -n order-service deploy/order-service
kubectl logs -n api-gateway   deploy/api-gateway

# Get the external IP for api-gateway
kubectl get svc -n api-gateway

# Test
curl http://<EXTERNAL-IP>/health
curl -X POST http://<EXTERNAL-IP>/orders \
  -H "Content-Type: application/json" \
  -d '{"item": "widget", "qty": 2}'
```

---

## Step 7 — HTTPS Ingress with TLS

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

### Ingress

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

## Step 8 — CI/CD Pipeline with GitHub Actions

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

    - name: Build and push images
      run: |
        az acr build --registry ecommerceacrdenis --image api-gateway:${{ github.sha }}          services/api-gateway
        az acr build --registry ecommerceacrdenis --image order-service:${{ github.sha }}        services/order-service
        az acr build --registry ecommerceacrdenis --image notification-service:${{ github.sha }} services/notification-service

    - name: Set AKS context
      uses: azure/aks-set-context@v3
      with:
        resource-group: ecommerce-rg
        cluster-name: ecommerce-aks

    - name: Helm upgrade
      run: |
        helm upgrade api-gateway          helm/api-gateway          -n api-gateway          --set image.tag=${{ github.sha }}
        helm upgrade order-service        helm/order-service        -n order-service        --set image.tag=${{ github.sha }}
        helm upgrade notification-service helm/notification-service -n notification-service --set image.tag=${{ github.sha }}
```

---

## Step 9 — Observability

### Container Insights (enabled via Terraform)

Logs from all pods flow automatically to the Log Analytics Workspace `lawaks`.

```bash
# View logs in Azure Monitor
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

### Key metrics to watch

| Metric | What it signals |
|---|---|
| `container_cpu_usage_seconds_total` | CPU pressure per pod |
| `container_memory_working_set_bytes` | Memory usage per pod |
| `http_requests_total` | Request volume per service |
| `http_request_duration_seconds` | Latency per endpoint |

---

## Step 10 — Test & Verify

### End-to-end flow

```bash
GATEWAY_IP=$(kubectl get svc api-gateway -n api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Health checks
curl http://$GATEWAY_IP/health

# Create an order — triggers notification-service automatically
curl -X POST http://$GATEWAY_IP/orders \
  -H "Content-Type: application/json" \
  -d '{"item": "widget", "qty": 2}'

# List orders
curl http://$GATEWAY_IP/orders

# Check notification-service received the event
kubectl logs -n notification-service deploy/notification-service
```

### Verify workload identity is working

```bash
# If secrets loaded correctly, order-service logs will show:
# Secrets loaded — db: yes, api-key: yes

kubectl logs -n order-service deploy/order-service | grep "Secrets loaded"
```

### Verify network policy

```bash
# This should be blocked — only api-gateway namespace is allowed in
kubectl run test --image=busybox -n notification-service --rm -it -- \
  wget -qO- http://order-service.order-service.svc.cluster.local:3001/health
```

---

## Key Concepts Summary

| Concept | What it is | Why it matters |
|---|---|---|
| Terraform backend | State stored in Azure Blob | Team can share state; no local tfstate files |
| OIDC issuer | AKS publishes a JWT verification endpoint | Azure AD can validate K8s service account tokens |
| Federated credential | Trust link between UAMI and K8s SA | No secret ever exchanged — pure identity federation |
| Workload Identity | Pod assumes Azure identity via token exchange | Passwordless access to any Azure service |
| SecretProviderClass | CSI driver config for which secrets to mount | Secrets appear as files — no K8s Secret objects needed |
| Helm | Package manager for Kubernetes | Single source of truth for K8s config; parameterised per environment |
| Network Policy | Kubernetes firewall between pods | Blast radius containment if a pod is compromised |
| RBAC | Role-based permissions on the K8s API | Least-privilege access for developers and CI/CD |
