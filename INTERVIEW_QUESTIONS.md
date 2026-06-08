# Interview Questions — AKS Platform Engineer

> Answer every question as if you are already in production. Lead with architecture, explain trade-offs, reference real code from the project.

---

## Table of Contents

1. [AKS / Kubernetes](#1-aks--kubernetes)
2. [Terraform](#2-terraform)
3. [CI/CD and GitOps](#3-cicd-and-gitops)
4. [Azure Security and Enterprise Standards](#4-azure-security-and-enterprise-standards)
5. [Observability and Production Support](#5-observability-and-production-support)
6. [Live Challenge Prep](#6-live-challenge-prep)
7. [Behavioral Questions](#7-behavioral-questions)

---

## 1. AKS / Kubernetes

---

### How would you design a production-ready AKS cluster?

In a production setup, I would think about this across five areas: infrastructure, networking, security, workload isolation, and observability.

**Infrastructure**

I provision AKS with Terraform so every cluster is reproducible and version-controlled. In this project that is `terraform/main.tf`. The cluster uses `Standard_D2s_v3` nodes with autoscaling enabled between 2 and 5 nodes so it handles traffic spikes without paying for idle capacity.

```hcl
resource "azurerm_kubernetes_cluster" "aks" {
  name       = "ecommerce-aks"
  dns_prefix = "ecommerce"

  default_node_pool {
    name                 = "system"
    vm_size              = "Standard_D2s_v3"
    auto_scaling_enabled = true
    min_count            = 2
    max_count            = 5
  }

  identity { type = "SystemAssigned" }
}
```

For a larger platform I would add a dedicated user node pool for application workloads and keep the system pool only for Kubernetes system components. This prevents a runaway application from starving `coredns` or `metrics-server`.

**Networking**

I use the Azure CNI network plugin so every pod gets a real VNet IP — this matters for network policies and for direct routing from other Azure services. I pair it with Calico for Network Policy enforcement. In this project the `network-policy.yaml` restricts `order-service` to only accept traffic from the `api-gateway` namespace, so a compromised pod cannot reach other services.

**Security**

- OIDC issuer enabled — required for Workload Identity
- Workload Identity instead of secrets — pods assume Azure Managed Identities, no credentials stored anywhere
- Key Vault CSI driver for secrets — secrets are mounted as files, not stored in etcd
- Azure Policy enabled on the cluster — enforces guardrails across all workloads
- RBAC — developers get `developer-readonly` ClusterRole (get/list/watch only)

**Observability**

The `oms_agent` block in Terraform connects the cluster to a Log Analytics Workspace on day zero. No post-hoc setup needed.

---

### What is the difference between a system node pool and a user node pool?

A **system node pool** runs Kubernetes system components: `coredns`, `metrics-server`, `kube-proxy`, `azure-cni`. AKS requires at least one system pool. These nodes have a taint (`CriticalAddonsOnly=true:NoSchedule`) that prevents user workloads from landing on them unless explicitly tolerated.

A **user node pool** runs application workloads. You can have multiple user pools with different VM sizes — for example, a memory-optimised pool for a data processing service and a standard pool for web services. This gives you cost efficiency and workload isolation in the same cluster.

**In this project:** There is a single system pool (`name: system`) which works fine for a three-service platform. For a larger platform I would add a user pool and use `nodeSelector` or `nodeTaints` to direct application pods there.

**Why this matters operationally:** If a user workload consumes all resources on the system pool, `coredns` goes down and DNS resolution fails cluster-wide. Isolation prevents this scenario.

---

### How do you connect AKS securely to Azure Container Registry?

Using an `AcrPull` role assignment on the cluster's kubelet identity. No image pull secrets, no Docker credentials, no passwords stored anywhere.

In Terraform:

```hcl
resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}
```

The `kubelet_identity` is the System Assigned Managed Identity that the node pool VMs use. When a pod pulls an image, the kubelet presents this identity's token to ACR. ACR validates the token against Azure AD and either allows or denies the pull. No credential is ever stored in the cluster.

**Why Premium SKU for ACR?** Premium enables geo-replication (multiple regions get a local copy of images — faster pulls, better availability) and private endpoints (ACR is not publicly reachable at all).

**Verification:**

```bash
kubectl get pods -A   # no ImagePullBackOff
kubectl describe pod <pod> -n <ns>   # should not mention pull credentials
```

---

### How would you troubleshoot a pod stuck in CrashLoopBackOff?

CrashLoopBackOff means the container starts, crashes, Kubernetes waits (with exponential backoff), then tries again. The back-off resets after 10 minutes of successful running. My troubleshooting sequence:

**Step 1 — Get the current state**

```bash
kubectl get pods -n <namespace>
# Look at RESTARTS count and AGE
```

**Step 2 — Describe the pod — this shows the exit code and last state**

```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at: Last State, Exit Code, Events at the bottom
```

Exit code meanings:
- `1` — application error (check logs)
- `137` — OOMKilled (pod hit memory limit)
- `139` — segfault
- `143` — SIGTERM (pod was terminated, usually a readiness/liveness probe killing it)

**Step 3 — Read the logs from the previous container instance**

```bash
kubectl logs <pod-name> -n <namespace> --previous
# --previous is critical — the current container may not have logs yet
```

**Step 4 — Check events**

```bash
kubectl get events -n <namespace> --sort-by=.metadata.creationTimestamp
```

**Step 5 — What I check next depending on the exit code:**

- **Exit 1 (app error):** Check logs for stack trace. Then check env vars, ConfigMaps, secret mounts. In this project, if `order-service` crashes at startup it often means `/mnt/secrets` is empty — meaning the SecretProviderClass or Workload Identity chain broke.
- **OOMKilled:** Increase memory limit or profile the application for memory leaks.
- **Readiness probe killing restarts:** The app is taking longer to start than `initialDelaySeconds` allows. Increase the delay or fix the startup time.

**For this project specifically — common CrashLoopBackOff causes:**

```bash
# Did the secrets mount?
kubectl exec -n order-service deploy/order-service -- ls /mnt/secrets

# Is the service account annotated?
kubectl describe sa order-service-sa -n order-service

# Is the federated credential matching?
az identity federated-credential list \
  --identity-name order-service-identity \
  --resource-group ecommerce-rg
```

---

### How would you troubleshoot ImagePullBackOff?

ImagePullBackOff means the kubelet cannot pull the container image. My sequence:

**Step 1 — Describe the pod**

```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at Events: "Failed to pull image" with the reason
```

The error message in Events tells you exactly what failed. Common messages:

| Message | Cause |
|---|---|
| `unauthorized: authentication required` | Missing or broken ACR pull permission |
| `not found` | Image tag does not exist in ACR |
| `connection refused` | ACR is private and the node cannot reach it |
| `pull access denied` | Wrong registry name or private registry with no credentials |

**Step 2 — Verify the image tag exists in ACR**

```bash
az acr repository show-tags \
  --name ecommerceacrdenis \
  --repository order-service \
  --output table
```

**Step 3 — Verify the AcrPull role assignment is still in place**

```bash
az role assignment list \
  --scope $(az acr show -n ecommerceacrdenis --query id -o tsv) \
  --query "[?roleDefinitionName=='AcrPull']"
```

**Step 4 — Check the image reference in the deployment**

```bash
kubectl get deployment order-service -n order-service -o yaml | grep image
```

Compare the tag in the manifest to what exists in ACR. A very common cause: the CI/CD pipeline pushed `abc123` but the HelmRelease still has the old SHA. In this project, Flux picks up the new tag from `flux/releases/order-service.yaml` — if the pipeline forgot to update that file, the cluster keeps trying to pull the old tag which may no longer exist.

**Step 5 — Test the pull manually from a node (advanced)**

```bash
az aks nodepool list -g ecommerce-rg --cluster-name ecommerce-aks
# SSH to a node and run: crictl pull <image>
```

---

### How do you expose services in AKS?

There are four patterns, and I choose based on who the caller is:

**ClusterIP (default)** — only reachable inside the cluster. Used for all internal service-to-service communication. In this project, `order-service` and `notification-service` are ClusterIP — they should never be called directly from the internet.

```yaml
service:
  type: ClusterIP
  port: 3001
```

**NodePort** — opens a port (30000–32767) on every node. Rarely used in production because it exposes nodes directly and requires knowing node IPs. I use it for local development or when I have no load balancer.

**LoadBalancer** — provisions an Azure Load Balancer with a public or private IP. In this project, `api-gateway` is the only service exposed externally. For production I would use an internal LoadBalancer and put NGINX Ingress in front.

**Ingress** — a single external IP routes to multiple services based on hostname or path. More efficient than one LoadBalancer per service. See the NGINX Ingress setup in the README.

**My decision rule:**
- Internal service → ClusterIP
- Single entry point for external traffic → LoadBalancer (via NGINX Ingress Controller)
- Multiple services needing external routes → Ingress resources behind the NGINX LoadBalancer

---

### What is the difference between ClusterIP, NodePort, and LoadBalancer?

| Type | Reachable from | Use case |
|---|---|---|
| ClusterIP | Inside cluster only | Service-to-service, e.g. order-service → notification-service |
| NodePort | Outside cluster via `<NodeIP>:<NodePort>` | Dev/test, legacy systems |
| LoadBalancer | Internet via Azure LB with public/private IP | External-facing services |

In Kubernetes DNS, any service is reachable within the cluster as:

```
<service-name>.<namespace>.svc.cluster.local:<port>
```

In this project, `order-service` calls notification-service at:

```
http://notification-service.notification-service.svc.cluster.local:3002
```

This works regardless of service type because DNS resolution is internal. The service type only determines external reachability.

---

### How would you configure ingress in AKS?

In production I install the NGINX Ingress Controller via Helm, then create `Ingress` resources per application.

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
```

The controller creates one Azure Load Balancer. All Ingress resources share that single IP and the controller routes by hostname or path.

For TLS I use cert-manager with a Let's Encrypt `ClusterIssuer`:

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
  - hosts: [api.yourdomain.com]
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

cert-manager automatically provisions the certificate and renews it before expiry. No manual certificate management.

**Enterprise alternative:** Azure Application Gateway Ingress Controller (AGIC) if the organisation already uses App Gateway for WAF. The trade-off is that AGIC is one-to-one with an App Gateway instance which is more expensive.

---

### How do you scale workloads in Kubernetes?

There are three levels:

**1. Manual scaling**

```bash
kubectl scale deployment order-service -n order-service --replicas=5
```

Useful for emergency response during an incident. Not suitable for production automation.

**2. HPA — Horizontal Pod Autoscaler**

Scales the number of pods based on CPU, memory, or custom metrics. In this project the `api-gateway` Helm chart includes an HPA:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-gateway
  namespace: api-gateway
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-gateway
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

HPA requires `metrics-server` to be running (it is installed by default on AKS). **HPA only works if resource requests are defined on the pods** — otherwise it cannot calculate utilisation percentage.

**3. Cluster Autoscaler**

Scales the number of nodes. When HPA adds pods but there is not enough capacity, pods sit in `Pending`. The cluster autoscaler sees pending pods and adds nodes. When utilisation drops, it removes nodes and reschedules pods to the remaining ones.

In this project autoscaling is enabled in Terraform: `min_count = 2`, `max_count = 5`.

---

### What is the difference between HPA and cluster autoscaler?

| | HPA | Cluster Autoscaler |
|---|---|---|
| What it scales | Pods (replicas) | Nodes (VMs) |
| Trigger | CPU / memory / custom metrics | Pending pods or underutilised nodes |
| Speed | Seconds to minutes | Minutes (VM provisioning) |
| Works on | Deployments, StatefulSets | Node pools |

They complement each other. HPA reacts first by adding pods. If the cluster is full, those pods are `Pending`, which triggers the cluster autoscaler to add a node. When load drops, HPA reduces pods, nodes become underutilised, cluster autoscaler removes them.

**Common mistake:** Setting HPA `minReplicas: 1` on a single node cluster. If that one pod is evicted during a node scale-down, there is a brief outage. Always run at least 2 replicas for production workloads — which is why all three services in this project have `replicaCount: 2`.

---

### How do you manage secrets in AKS?

There are three patterns, ordered from worst to best:

**1. Kubernetes Secrets (avoid for sensitive data)** — stored in etcd, base64 encoded not encrypted. Anyone with `kubectl get secret` access can decode them. Acceptable only for non-sensitive config.

**2. Sealed Secrets / External Secrets Operator** — encrypts secrets before committing to Git. Requires running a controller in the cluster. Good when you need GitOps for secret management.

**3. Azure Key Vault with Workload Identity (what I use in this project)** — secrets never leave Key Vault. The pod uses its Azure identity to fetch them at startup. The Secrets Store CSI driver mounts them as files. Nothing sensitive is stored in etcd or in Git.

```
Pod (ServiceAccount token)
  → Azure AD validates via OIDC
    → Managed Identity token issued
      → Key Vault authenticates the identity
        → Secrets mounted as files at /mnt/secrets/
```

This satisfies NIST 800-53 SC-28 (protection of information at rest) because the secret value only exists in Key Vault and transiently in the pod's memory.

---

### How would you integrate Azure Key Vault with AKS?

Five components must be in place simultaneously. If any one is missing, the secret mount fails silently and the pod crashes or starts without secrets.

**Component 1 — Enable the add-on (avoids CRD conflicts on AKS 1.27+)**

```bash
az aks enable-addons \
  -g ecommerce-rg -n ecommerce-aks \
  --addons azure-keyvault-secrets-provider
```

**Component 2 — Managed Identity with Key Vault RBAC (Terraform)**

```hcl
resource "azurerm_user_assigned_identity" "order_service" {
  name = "order-service-identity"
  ...
}

resource "azurerm_role_assignment" "order_service_kv" {
  principal_id         = azurerm_user_assigned_identity.order_service.principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.kv.id
}
```

**Component 3 — Federated credential (Terraform) — links the Azure identity to the K8s ServiceAccount**

```hcl
resource "azurerm_federated_identity_credential" "order_service" {
  issuer  = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject = "system:serviceaccount:order-service:order-service-sa"
  audience = ["api://AzureADTokenExchange"]
  ...
}
```

**Component 4 — ServiceAccount annotated with the identity client ID**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-service-sa
  namespace: order-service
  annotations:
    azure.workload.identity/client-id: "<client-id>"
```

**Component 5 — SecretProviderClass + pod label**

```yaml
# SecretProviderClass declares which secrets to fetch
spec:
  provider: azure
  parameters:
    clientID: "<client-id>"
    keyvaultName: "ecommerce-kv-aks"
    tenantId: "<tenant-id>"
    objects: |
      array:
        - |
          objectName: postgres-password
          objectType: secret
```

```yaml
# Pod must have this label to get the OIDC token injected
labels:
  azure.workload.identity/use: "true"
```

**Debugging if secrets do not mount:**

```bash
kubectl describe pod <pod> -n order-service
# Look for: "failed to mount" or "SecretProviderClass not found"

kubectl get secretproviderclass -n order-service
kubectl describe secretproviderclass order-service-secrets -n order-service

# Check if the CSI driver pod is running
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
```

---

### How do you handle pod-to-pod communication issues?

Pod-to-pod communication in Kubernetes uses DNS. First I verify the basics:

**Step 1 — Is the target service running?**

```bash
kubectl get svc -n notification-service
kubectl get endpoints -n notification-service
# If ENDPOINTS is <none>, no pods match the selector
```

**Step 2 — Is DNS resolving?**

```bash
kubectl run dns-test --image=busybox --rm -it \
  -n order-service -- nslookup notification-service.notification-service.svc.cluster.local
```

**Step 3 — Is a NetworkPolicy blocking the traffic?**

```bash
kubectl get networkpolicy -A
kubectl describe networkpolicy allow-api-gateway-only -n order-service
```

In this project, `network-policy.yaml` restricts `order-service` to only accept traffic from namespaces labelled `app: api-gateway`. If `notification-service` tries to call `order-service`, it will be blocked — intentionally. If `api-gateway` calls `order-service` and it is blocked, check that the `api-gateway` namespace has the label `app: api-gateway`.

```bash
kubectl get namespace api-gateway --show-labels
```

**Step 4 — Test connectivity directly**

```bash
kubectl exec -n api-gateway deploy/api-gateway -- \
  wget -qO- http://order-service.order-service.svc.cluster.local:3001/health
```

**Step 5 — Check Calico policies if using Calico**

```bash
kubectl get networkpolicy -A
```

---

### What would you check if an application is deployed but not reachable?

This is a layered problem. I work from outside in:

**Layer 1 — Is the service exposed correctly?**

```bash
kubectl get svc -n api-gateway
# Check: is EXTERNAL-IP assigned? Is the port correct?
```

If `EXTERNAL-IP` is `<pending>`, the Azure Load Balancer has not provisioned yet. Check AKS node pool has permission to create LB resources.

**Layer 2 — Do the pods exist and are they ready?**

```bash
kubectl get pods -n api-gateway
# READY must be 1/1 (or N/N), STATUS Running
```

If `READY 0/1`, the readiness probe is failing. Check:

```bash
kubectl describe pod <pod> -n api-gateway
# Events section: Readiness probe failed
```

**Layer 3 — Does the service selector match the pod labels?**

```bash
kubectl get endpoints api-gateway -n api-gateway
# If <none>, selector mismatch
kubectl describe svc api-gateway -n api-gateway
kubectl get pod <pod> -n api-gateway --show-labels
```

**Layer 4 — Network Policy**

```bash
kubectl get networkpolicy -n api-gateway
```

**Layer 5 — Application logs**

```bash
kubectl logs deploy/api-gateway -n api-gateway
# Is it listening on the right port? Any bind errors?
```

**Layer 6 — Ingress (if using Ingress)**

```bash
kubectl get ingress -n api-gateway
kubectl describe ingress ecommerce-ingress -n api-gateway
kubectl logs deploy/ingress-nginx-controller -n ingress-nginx
```

---

### How do you perform rolling updates and rollbacks?

**Rolling update (default strategy)**

Kubernetes replaces pods incrementally so there is always capacity serving traffic.

```bash
# Update via Flux — update the tag in flux/releases/order-service.yaml and push to main
# Flux reconciles within 1 minute

# Or manually via Helm
helm upgrade order-service helm/order-service -n order-service \
  --set image.tag=<new-sha>

# Watch the rollout
kubectl rollout status deployment/order-service -n order-service
```

The default `RollingUpdate` strategy uses:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # one extra pod is created before old ones are removed
    maxUnavailable: 0  # no pods are removed until new ones pass readiness
```

With `maxUnavailable: 0` the deployment is zero-downtime — new pods must be healthy before old ones are terminated.

**Rollback**

```bash
# Immediate rollback to previous revision
kubectl rollout undo deployment/order-service -n order-service

# Rollback to a specific revision
kubectl rollout history deployment/order-service -n order-service
kubectl rollout undo deployment/order-service -n order-service --to-revision=3

# In GitOps: revert the commit that changed the image tag
git revert <commit-sha>
git push origin main
# Flux reconciles and rolls back
```

**Why GitOps rollback is better:** Reverting in Git gives you an audit trail. `kubectl rollout undo` is invisible unless you are watching — the Git revert shows exactly who changed what and when.

---

### Troubleshooting Scenario: "A deployment worked yesterday, pods are failing after a new image was pushed. What do you check?"

This is the most important question to answer well. Walk through it methodically.

**1. Get the current pod state**

```bash
kubectl get pods -n order-service
# Look for: CrashLoopBackOff, Error, ImagePullBackOff, RESTARTS count
```

**2. Describe the failing pod**

```bash
kubectl describe pod <pod-name> -n order-service
# Check: Image name/tag, Events, Last State exit code
```

**3. Read logs from the previous (crashed) container**

```bash
kubectl logs <pod-name> -n order-service --previous
```

**4. Check cluster events**

```bash
kubectl get events -n order-service --sort-by=.metadata.creationTimestamp
```

**5. Check the deployment**

```bash
kubectl describe deployment order-service -n order-service
# Check: current image tag, replicas, conditions
```

**Then I check these specific areas in order:**

- **Image tag** — does the tag in the HelmRelease/Deployment actually exist in ACR?
- **ACR pull permission** — is the `AcrPull` role assignment still valid?
- **Environment variables** — any new env var the app expects but is not set?
- **Secrets** — did the SecretProviderClass change? Is Key Vault still accessible?
- **ConfigMaps** — was a ConfigMap updated incorrectly?
- **Readiness/liveness probes** — did the new code change the `/health` endpoint path?
- **Resource limits** — is the new image using more memory? Is it OOMKilled?
- **Recent changes** — `git log --oneline -10` — what changed since yesterday?

**My answer in an interview:**

> "My first instinct is to look at the exit code in `kubectl describe pod`. Exit 137 tells me it was OOMKilled — I'd look at resource limits. Exit 1 or a stack trace in the logs points to an application error — I'd look at env vars, secrets, and what changed in the last commit. If it's ImagePullBackOff I'd verify the image tag exists in ACR and the pull permission is intact. Throughout this I am also checking cluster events and the Flux reconciliation status to understand exactly what version was deployed and when."

---

## 2. Terraform

---

### How do you structure Terraform for multiple environments?

I use reusable modules for shared infrastructure components and separate environment directories for dev, QA, UAT, and prod. Each environment has its own backend state.

```
terraform/
├── modules/
│   ├── aks/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── acr/
│   ├── keyvault/
│   ├── networking/
│   └── monitoring/
├── environments/
│   ├── dev/
│   │   ├── main.tf          # calls modules with dev-specific vars
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf       # dev state file
│   ├── qa/
│   ├── uat/
│   └── prod/
│       ├── main.tf
│       └── backend.tf       # prod state file — separate, isolated
```

**Why not a single state file for all environments?**

Blast radius. If a Terraform operation in dev corrupts the state, it does not touch prod. Each environment also has independent approval gates — prod requires manual approval before `terraform apply`.

**For this project:** Currently there is a single `terraform/main.tf` which is fine for a single cluster. In an enterprise setup I would extract it into modules and create environment folders.

---

### How do you manage remote state in Azure?

Remote state is stored in Azure Blob Storage with a storage account dedicated to Terraform. This allows teams to collaborate without state conflicts and enables state locking.

```hcl
terraform {
  backend "azurerm" {
    subscription_id      = "39902fa6-9035-4b4f-9856-92190439f013"
    resource_group_name  = "rg-terraform"
    storage_account_name = "terraformecommerceaks"
    container_name       = "state"
    key                  = "terraform.tfstate"
  }
}
```

The storage account should be in a separate resource group (`rg-terraform`) from the workload resources (`ecommerce-rg`). This way destroying the workload resources does not accidentally destroy the state.

**State access controls:**

- The storage account has versioning enabled so you can recover a previous state
- Access is via Azure RBAC — only the CI/CD service principal and admins have `Storage Blob Data Contributor`
- The storage account has `allow_blob_public_access = false`

---

### What is state locking and why is it important?

When `terraform apply` runs it acquires a lock on the state file in Blob Storage. Any concurrent `terraform apply` from another pipeline or terminal sees the lock and waits or errors — preventing two operations from running simultaneously and corrupting the state.

Azure Blob Storage uses lease-based locking. Terraform acquires a blob lease before modifying state and releases it after. If Terraform crashes mid-apply, the lease expires automatically after 60 seconds so you are not locked out permanently.

**What to do if you find a stuck lock:**

```bash
terraform force-unlock <lock-id>
```

Only do this if you are certain no other apply is running.

---

### What is the difference between variables, locals, and outputs?

**Variables** — inputs to a module or configuration. Defined with `variable {}`, set via `terraform.tfvars`, environment variables (`TF_VAR_name`), or `-var` flags. Used for anything that changes between environments or callers.

```hcl
variable "location" {
  default = "East US"
}
```

**Locals** — computed values internal to the module. Cannot be set from outside. Good for string formatting, combining variables, avoiding repetition.

```hcl
locals {
  cluster_name = "ecommerce-aks-${var.environment}"
  common_tags  = { project = "ecommerce", environment = var.environment }
}
```

**Outputs** — values exposed to the caller or to `terraform output`. In this project:

```hcl
output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.order_service.client_id
}
```

This output is used by the CI/CD pipeline to inject the client ID into Helm values. Other modules can also consume it via `module.<name>.workload_identity_client_id`.

---

### When would you use modules?

When the same resource pattern is deployed more than once — across environments or across teams. Modules enforce consistency and hide complexity.

I would create modules for:
- AKS cluster (with node pool config, RBAC, monitoring)
- ACR (with replication, private endpoints)
- Key Vault (with RBAC, soft delete)
- Networking (VNet, subnets, NSGs)

A module call then looks like:

```hcl
module "aks" {
  source          = "../modules/aks"
  name            = "ecommerce-aks-prod"
  resource_group  = module.rg.name
  location        = var.location
  min_nodes       = 3
  max_nodes       = 10
  log_workspace_id = module.monitoring.workspace_id
}
```

The caller does not need to know how node pools, OIDC, or OMS agent are configured — the module handles it consistently.

**When NOT to use modules:** One-off resources. Creating a module for a single `azurerm_resource_group` is over-engineering.

---

### How would you create reusable Terraform modules for AKS?

The module accepts all variable inputs that change between environments and hardcodes what should never change.

```hcl
# modules/aks/variables.tf
variable "name"              { type = string }
variable "location"          { type = string }
variable "resource_group"    { type = string }
variable "vm_size"           { type = string; default = "Standard_D2s_v3" }
variable "min_nodes"         { type = number; default = 2 }
variable "max_nodes"         { type = number; default = 5 }
variable "log_workspace_id"  { type = string }

# modules/aks/main.tf
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group
  dns_prefix          = var.name

  default_node_pool {
    name                 = "system"
    vm_size              = var.vm_size
    auto_scaling_enabled = true
    min_count            = var.min_nodes
    max_count            = var.max_nodes
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin = "azure"
    network_policy = "calico"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true

  oms_agent {
    log_analytics_workspace_id = var.log_workspace_id
  }
}

# modules/aks/outputs.tf
output "cluster_id"          { value = azurerm_kubernetes_cluster.aks.id }
output "kubelet_identity_id" { value = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id }
output "oidc_issuer_url"     { value = azurerm_kubernetes_cluster.aks.oidc_issuer_url }
```

---

### What is the difference between count and for_each?

Both create multiple instances of a resource. The difference is how you reference and modify them.

**count** — creates instances indexed by integer (0, 1, 2…). Removing an item in the middle forces Terraform to recreate everything after it.

```hcl
resource "azurerm_resource_group" "rg" {
  count    = 3
  name     = "rg-${count.index}"
  location = "East US"
}
# Removing index 1 → Terraform destroys rg-1 and rg-2, recreates rg-2 as rg-1
```

**for_each** — creates instances indexed by string key. Removing a key only removes that specific instance.

```hcl
resource "azurerm_resource_group" "rg" {
  for_each = toset(["dev", "qa", "prod"])
  name     = "rg-${each.key}"
  location = "East US"
}
# Removing "qa" → Terraform destroys only rg-qa, dev and prod unchanged
```

**Rule:** Use `for_each` almost always. Use `count` only for simple boolean toggles (`count = var.enabled ? 1 : 0`).

---

### How do you manage secrets in Terraform?

Three rules:
1. Never put secrets in `.tf` files or `terraform.tfvars` committed to Git
2. Never store secrets in outputs (they appear in state)
3. Treat the state file as sensitive — it contains resource attributes including secrets

**Patterns I use:**

**1. Pass secrets as environment variables at runtime**

```bash
export TF_VAR_db_password="$(az keyvault secret show --vault-name my-kv --name db-password --query value -o tsv)"
terraform apply
```

**2. Read secrets from Key Vault inside Terraform using a data source**

```hcl
data "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  key_vault_id = azurerm_key_vault.kv.id
}
```

**3. Generate values in Terraform and write them directly to Key Vault**

This project does this — Terraform creates the Key Vault and the CI/CD operator adds secrets after via Azure CLI. The Key Vault creation is in Terraform but the secret values are not.

**4. Encrypt state** — ensure the Blob Storage account has encryption at rest (Azure default) and access is RBAC-restricted.

---

### How do you handle Terraform drift?

Drift is when the real Azure environment no longer matches what Terraform state says it should be. This happens when someone makes a manual change in the portal or via Azure CLI outside of Terraform.

**Detection:**

```bash
terraform plan
# If it shows changes you did not expect, that is drift
```

**Resolution options:**

1. **Let Terraform fix it** — run `terraform apply`. Terraform will overwrite the manual change and bring the environment back to the desired state. This is the correct approach for GitOps-managed infrastructure.

2. **Update Terraform to accept the change** — if the manual change is valid and you want to keep it, update the `.tf` file to match, then run `terraform apply`. It should show no changes.

3. **Import the resource** — if someone created a resource manually that Terraform should now manage:

```bash
terraform import azurerm_resource_group.rg /subscriptions/<sub>/resourceGroups/ecommerce-rg
```

**Prevention:**

- Enable Azure Policy to block certain manual changes
- Use branch protection and CI/CD for all Terraform changes — no direct portal access for infra
- Lock critical resources in Azure to prevent accidental modification

---

### What happens if the Terraform state file is lost?

Without the state file, Terraform does not know what it has created. Running `terraform apply` would try to create everything again, resulting in errors (resources already exist) or duplicate resources.

**Recovery:**

1. Check Blob Storage versioning — Azure Blob versioning is enabled on the state container so a previous version can be restored.

2. Reimport all resources manually:

```bash
terraform import azurerm_resource_group.rg /subscriptions/.../resourceGroups/ecommerce-rg
terraform import azurerm_kubernetes_cluster.aks /subscriptions/.../resourceGroups/ecommerce-rg/providers/Microsoft.ContainerService/managedClusters/ecommerce-aks
# ... for every resource
```

3. Run `terraform plan` after importing to verify the state matches reality.

**Prevention:**

- Enable Blob Storage versioning on the state container
- Enable soft delete on the Blob Storage account
- Restrict who can delete blobs via RBAC

---

### How do you import an existing Azure resource into Terraform?

```bash
# Step 1: Write the resource block in your .tf file to match the existing resource
resource "azurerm_resource_group" "rg" {
  name     = "ecommerce-rg"
  location = "East US"
}

# Step 2: Import using the Azure resource ID
terraform import azurerm_resource_group.rg \
  /subscriptions/39902fa6-9035-4b4f-9856-92190439f013/resourceGroups/ecommerce-rg

# Step 3: Run plan — it should show no changes if the .tf matches reality
terraform plan
```

If `terraform plan` shows changes after import, update the `.tf` to match the real resource attributes, then plan again until it shows no changes.

---

### How do you handle provider versioning?

Pin providers with version constraints in `required_providers`. Never leave versions unconstrained in production.

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.85"   # allows patch updates, blocks major/minor bumps
    }
  }
}
```

The `~>` constraint means: accept 3.85.x but not 3.86 or 4.x. This prevents an upstream provider release from breaking your apply.

`terraform.lock.hcl` — commit this file to Git. It records the exact provider version and hash that was selected. This ensures every teammate and every CI/CD run uses the identical provider binary.

---

### How would you deploy AKS, ACR, Key Vault, Log Analytics, and Managed Identity using Terraform?

This is exactly what `terraform/main.tf` in this project does. The key is the dependency chain:

```
Resource Group (everything depends on this)
  ├── Log Analytics Workspace
  ├── ACR
  ├── AKS Cluster (depends on Log Analytics for oms_agent)
  │    └── Role Assignment: AcrPull (depends on AKS kubelet_identity)
  ├── User Assigned Managed Identity
  │    ├── Federated Credential (depends on AKS oidc_issuer_url)
  │    └── Role Assignment: Key Vault Secrets User (depends on Key Vault)
  └── Key Vault (depends on current tenant_id)
```

Terraform resolves the dependency graph automatically based on resource references. `azurerm_role_assignment.acr_pull` references `azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id`, so Terraform knows to create the cluster first.

**After apply:**

```bash
terraform output workload_identity_client_id
# Inject this into the Helm values for order-service
```

---

## 3. CI/CD and GitOps

---

### How would you design a CI/CD pipeline for AKS?

```
Developer pushes to feature branch
  → CI: lint, unit tests, SonarQube scan
  → Docker image built and pushed to ACR with commit SHA as tag
  → Pull request opened
  → Code review + approval

Merge to main
  → CI: integration tests
  → Image pushed to ACR: ecommerceacrdenis.azurecr.io/order-service:<sha>
  → Image tag updated in flux/releases/order-service.yaml
  → Commit pushed to main
  → Flux detects the Git change (polls every 1 minute)
  → HelmRelease updated
  → Helm upgrade applied to AKS
  → Deployment rolls out
  → Readiness probes confirm health
  → Alert if rollout fails
```

The key design decision: **CI builds and tests, CD is driven by Git state via Flux**. The pipeline never calls `kubectl` or `helm upgrade` directly against the cluster. It only updates a file in Git.

---

### How do you build and push Docker images to ACR?

Using `az acr build` — it sends the context to Azure and runs the build in the cloud. No local Docker daemon required, no credentials to manage.

```bash
az acr build \
  --registry ecommerceacrdenis \
  --image order-service:$(git rev-parse HEAD) \
  services/order-service
```

**Why commit SHA as the tag?** It is immutable and traceable. `latest` is mutable — you cannot tell which code version `latest` refers to. A SHA lets you know exactly which commit is running in production.

In GitHub Actions:

```yaml
- name: Build and push
  run: |
    az acr build \
      --registry ecommerceacrdenis \
      --image order-service:${{ github.sha }} \
      services/order-service
```

---

### How do you promote the same image across environments?

The image is built once and promoted by updating the tag reference in environment-specific configuration.

```
Build once in CI → push SHA-tagged image to ACR
  ↓
Dev: flux/releases/dev/order-service.yaml  → tag: abc123
  ↓ (automated after tests pass)
QA:  flux/releases/qa/order-service.yaml   → tag: abc123
  ↓ (manual approval gate)
UAT: flux/releases/uat/order-service.yaml  → tag: abc123
  ↓ (change control approval)
Prod: flux/releases/prod/order-service.yaml → tag: abc123
```

The same image binary moves through environments. Only the configuration (replicas, resource limits, env vars) differs per environment. This guarantees that what you tested in UAT is exactly what runs in production — no rebuilds.

---

### How do you handle approvals before production?

**GitHub Actions:** Use `environment` with required reviewers:

```yaml
jobs:
  deploy-prod:
    environment: production   # requires approval from named reviewers
    runs-on: ubuntu-latest
    steps:
      - name: Update prod image tag
        run: sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/prod/order-service.yaml
```

**Flux:** The prod Kustomization can be in a separate Git branch (`release/prod`) that only merges after a pull request with approvals. This separates production changes from main.

**Change control:** For regulated environments, integrate with ServiceNow or JIRA to require a change ticket number before a release pipeline can proceed.

---

### How do you roll back a failed deployment?

**GitOps rollback (preferred):**

```bash
# Revert the commit that changed the image tag
git revert <commit-sha>
git push origin main
# Flux detects the revert and rolls back the HelmRelease within 1 minute
```

**Kubernetes rollback (immediate):**

```bash
kubectl rollout undo deployment/order-service -n order-service
# Then update the tag in Git to match, to prevent Flux from re-applying the bad version
```

**Helm rollback:**

```bash
helm rollback order-service 2 -n order-service   # rollback to revision 2
helm history order-service -n order-service       # list revisions
```

**The GitOps revert is the canonical approach** because it keeps Git as the source of truth. A bare `kubectl rollout undo` without updating Git means Flux will reapply the bad image tag on its next reconciliation loop.

---

### What is GitOps?

GitOps is an operational model where Git is the single source of truth for both application code and infrastructure state. The desired state is declared in Git files, and an automated agent (Flux in this project) continuously reconciles the live cluster to match.

**Two properties:**
1. **Desired state in Git** — every Deployment, HelmRelease, and ConfigMap is a file in the repository
2. **Automated reconciliation** — Flux polls Git and applies any diff automatically

**Benefits:**
- Every change has a Git commit — full audit trail
- Rollback is a `git revert`
- Cluster drift is detected and corrected automatically
- No human has direct `kubectl apply` access to production

---

### How does Flux work?

Flux is a set of Kubernetes controllers that run inside the cluster:

```
source-controller    → polls Git, downloads the repo, exposes it as an artifact
kustomize-controller → applies Kustomization resources (manages sets of manifests)
helm-controller      → applies HelmRelease resources (manages Helm upgrades)
```

In this project:

```
GitRepository (flux-system)
  → polls ssh://git@github.com/denisdbell/ecommerceaks every 1 minute
  → downloads the main branch

Kustomization (flux-system)
  → reads ./flux every 10 minutes
  → applies ecommerce-kustomization.yaml and all release files

HelmRelease (order-service, api-gateway, notification-service)
  → helm-controller runs helm upgrade when values or chart change
  → targetNamespace: order-service (deploys into the right namespace)
```

When you push a commit that changes `flux/releases/order-service.yaml`, the chain runs:
1. source-controller detects the new commit within 1 minute
2. kustomize-controller applies the updated HelmRelease
3. helm-controller runs `helm upgrade` with the new values
4. The deployment rolls out in AKS

---

### What is the difference between push-based deployment and pull-based GitOps?

**Push-based (traditional CI/CD):**
- The pipeline calls `kubectl apply` or `helm upgrade` from outside the cluster
- The cluster has no ongoing reconciliation — if someone manually changes a resource, it stays changed
- Requires storing cluster credentials in the pipeline (secret sprawl)
- Harder to audit — you need pipeline logs to know what happened

**Pull-based GitOps (Flux):**
- The cluster pulls its desired state from Git
- Continuous reconciliation — any drift is corrected on the next loop
- No credentials in the pipeline — the pipeline only writes to Git
- Audit trail is the Git history

**Security implication:** In push-based deployments, the CI/CD pipeline needs cluster credentials — a compromised pipeline means a compromised cluster. In pull-based GitOps, the pipeline only needs write access to Git. The cluster credentials never leave the cluster.

---

### How would you manage Helm charts in a GitOps workflow?

The Helm charts live in the same repository as the application code. Flux's `HelmRelease` resources in `flux/releases/` reference the charts by path within the GitRepository.

```yaml
# flux/releases/order-service.yaml
spec:
  chart:
    spec:
      chart: ./helm/order-service        # path in the Git repo
      sourceRef:
        kind: GitRepository
        name: flux-system                 # the same repo Flux is watching
```

This means when a developer changes `helm/order-service/templates/deployment.yaml` and merges to `main`, Flux detects the chart change and triggers a Helm upgrade automatically.

**Alternative for large teams:** Store charts in a dedicated Helm repository (OCI registry or ChartMuseum). The HelmRelease references the chart by version. This decouples chart releases from application releases.

---

### How would you separate application deployment from infrastructure deployment?

**Infrastructure (Terraform):** Managed in a separate Git repository with separate approval pipelines. Changes to AKS, ACR, Key Vault require a Terraform plan review and explicit approval. Infrastructure changes are rare and high-risk.

**Application (GitOps/Flux):** Managed in this repository. Developers can merge changes that affect their service without infrastructure team involvement.

**The bridge:** Terraform outputs values (like `workload_identity_client_id`) that application Helm charts need. In this project Terraform writes `helm/order-service/values.yaml` directly via `local_file` resource. In a mature setup this would be published to Key Vault and read by the application pipeline.

---

## 4. Azure Security and Enterprise Standards

---

### How do you secure an AKS cluster?

I think about this in layers:

**Network layer:**
- Azure CNI with Calico network policies — pods cannot reach each other unless explicitly allowed
- Private cluster option for high-security environments (control plane not publicly accessible)
- Ingress restricted to known CIDR ranges via NSG rules

**Identity layer:**
- Workload Identity instead of service principal credentials
- No secrets in environment variables — Key Vault CSI driver mounts them as files
- System Assigned Managed Identity for the cluster itself (no password rotation)

**Access layer:**
- Kubernetes RBAC — developers get read-only ClusterRole
- Azure RBAC on AKS — `Azure Kubernetes Service Cluster User Role` for developers, not cluster admin
- No shared kubeconfig files

**Policy layer:**
- Azure Policy for AKS — enforces rules like "containers must not run as root", "images must come from approved registries"
- `azure_policy_enabled = true` in Terraform

**Runtime layer:**
- Liveness and readiness probes on all pods
- Resource limits on all containers — prevents one pod from consuming all node resources
- Pod Security Standards — Baseline or Restricted profile per namespace

---

### How do you avoid storing secrets in pipelines?

Never put secrets in pipeline YAML files or environment variables. Use identity-based authentication everywhere possible.

**For Azure resources:** The pipeline's service principal has only the permissions it needs (least privilege). It authenticates to Azure using federated identity (OIDC) — no client secret required.

```yaml
- name: Azure Login (OIDC — no secrets)
  uses: azure/login@v1
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

These three values are IDs, not secrets. The actual authentication is passwordless via OIDC.

**For application secrets:** The pipeline never touches them. Secrets go into Key Vault directly. Pods fetch them at runtime via Workload Identity.

**For ACR:** `az acr build` uses the service principal's identity — no Docker credentials.

---

### How do you use Managed Identity with Azure resources?

Managed Identity removes the need for application credentials by giving Azure resources an identity that Azure AD can verify.

**System Assigned** — created with the resource, deleted with the resource. One-to-one relationship. Used for the AKS cluster itself.

**User Assigned** — created independently, can be assigned to multiple resources. Persists independently of the resource lifecycle. Used for `order-service-identity` in this project so its Key Vault permissions are not lost if the cluster is recreated.

The pod in this project uses its Managed Identity to fetch Key Vault secrets:

```
order-service pod
  → presents ServiceAccount token to Azure AD OIDC endpoint
    → Azure AD validates the token against the AKS OIDC issuer
      → Azure AD issues access token for order-service-identity
        → Pod uses token to call Key Vault API
          → Key Vault checks: does order-service-identity have Key Vault Secrets User role?
            → Yes → return secret value
```

No password, no certificate, no rotation.

---

### How do you apply least privilege in Azure?

Least privilege means every identity gets only the permissions it needs to do its job, and nothing more.

**Examples from this project:**

| Identity | Role | Scope | Why minimum |
|---|---|---|---|
| AKS kubelet | `AcrPull` | ACR only | Can pull images, cannot push or manage |
| order-service-identity | `Key Vault Secrets User` | Key Vault only | Can read secrets, cannot write or manage |
| Terraform operator | `Key Vault Secrets Officer` | Key Vault only | Can write secrets, cannot change RBAC |
| Developers | `developer-readonly` ClusterRole | Cluster-wide | Can view pods/services, cannot exec or modify |

**Applying least privilege in practice:**
- Start with no permissions and add only what is needed
- Review and audit role assignments quarterly
- Use built-in roles instead of custom roles where possible (built-in roles are tested and documented)
- Prefer resource-scoped assignments over subscription-scoped

---

### How do you secure access to Key Vault?

**Access control:** `enable_rbac_authorization = true` in Terraform — uses Azure RBAC instead of legacy vault access policies. RBAC is auditable and follows the same model as the rest of Azure.

**Network:** For high-security environments, enable private endpoints so Key Vault is not reachable from the internet. AKS nodes access Key Vault via the private endpoint over the VNet.

**Purge protection:** `purge_protection_enabled = true` — even subscription owners cannot permanently delete secrets for 7 days. Prevents accidental or malicious permanent deletion.

**Soft delete:** `soft_delete_retention_days = 7` — deleted secrets are retained and recoverable.

**Monitoring:** Azure Monitor alerts on Key Vault access patterns. Unusual access times or high failure rates trigger an alert.

---

### How do you scan container images?

**ACR built-in scanning:** Premium ACR integrates with Microsoft Defender for Containers which scans images for CVEs when they are pushed.

```bash
az acr repository show --name ecommerceacrdenis --image order-service:latest
# Defender shows vulnerabilities in the Azure portal
```

**In the pipeline:**

```yaml
- name: Scan image
  uses: azure/container-scan@v0
  with:
    image-name: ecommerceacrdenis.azurecr.io/order-service:${{ github.sha }}
    severity-threshold: HIGH
    run-quality-checks: true
```

**Shift-left — scan before push:**

```yaml
- name: Trivy scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: order-service:${{ github.sha }}
    exit-code: '1'           # fail the pipeline on HIGH/CRITICAL
    severity: 'HIGH,CRITICAL'
```

**Azure Policy:** Enforce that only images from `ecommerceacrdenis.azurecr.io` can run on the cluster. Images from Docker Hub or unscanned registries are blocked.

---

### How do you enforce policies in Kubernetes?

**Azure Policy for AKS** (enabled in Terraform via `azure_policy_enabled = true`) runs Gatekeeper OPA policies as a webhook. Built-in policies include:

- Containers must not run as root
- Images must come from allowed registries
- CPU and memory limits must be set
- Privileged containers are not allowed
- Host network and host PID are not allowed

**Custom policies via Gatekeeper:**

```yaml
# Only allow images from our ACR
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sAllowedRepos
metadata:
  name: allow-only-acr
spec:
  match:
    kinds: [{apiGroups: ["apps"], kinds: ["Deployment"]}]
  parameters:
    repos: ["ecommerceacrdenis.azurecr.io"]
```

---

### How do you handle RBAC in AKS?

Two layers: Azure RBAC (who can access the AKS API at the Azure level) and Kubernetes RBAC (what they can do inside the cluster).

**Azure RBAC on the cluster:**

```bash
# Developer can get credentials but not be cluster-admin
az role assignment create \
  --assignee <developer-object-id> \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope /subscriptions/.../resourceGroups/ecommerce-rg/providers/.../ecommerce-aks
```

**Kubernetes RBAC — from this project:**

```yaml
# kubernetes/rbac.yaml
kind: ClusterRole
metadata:
  name: developer-readonly
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "events"]
  verbs: ["get", "list", "watch"]
---
kind: ClusterRoleBinding
subjects:
- kind: Group
  name: "developers"   # matches an Azure AD group
```

**AKS Azure AD integration:** With Azure AD enabled on AKS, the Kubernetes RBAC subject (`name: "developers"`) maps to an Azure AD group. When a developer runs `kubectl`, AKS validates their Azure AD token and checks their group membership.

---

### What security checks would you add to a deployment pipeline?

```
1. Secret scanning — detect secrets committed to code (GitGuardian, TruffleHog, GitHub secret scanning)
2. SAST — static analysis for code vulnerabilities (SonarQube)
3. Container image scan — CVE detection before push (Trivy, Defender for Containers)
4. Dependency scan — known vulnerabilities in npm/pip/maven packages (Snyk, Dependabot)
5. IaC scan — Terraform security misconfigurations (Checkov, tfsec)
6. Quality gate — SonarQube must pass before merge to main
7. Image signing — sign images with Notation/cosign; Gatekeeper only admits signed images
8. Approval gate — production deployments require human approval
```

---

## 5. Observability and Production Support

---

### How do you monitor AKS?

Three complementary systems:

**1. Azure Monitor / Container Insights** — enabled via Terraform `oms_agent`. Logs from every pod flow to Log Analytics Workspace `lawaks` automatically. No agent installation needed. Query with KQL.

**2. Prometheus + Grafana** — deployed via `kube-prometheus-stack`. Scrapes metrics from pods, nodes, and Kubernetes control plane. Dashboards show real-time CPU/memory, pod counts, HPA status, and custom application metrics.

**3. Application-level** — each service exposes a `/health` endpoint which Kubernetes liveness and readiness probes call. If the app reports unhealthy, Kubernetes stops routing traffic to it and restarts it.

In this project, the Helm deployment template for `api-gateway` includes:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 15
readinessProbe:
  httpGet:
    path: /health
    port: 3000
  initialDelaySeconds: 5
  periodSeconds: 10
```

---

### What logs would you check during a production incident?

**Immediate — pod logs:**

```bash
kubectl logs deploy/order-service -n order-service --tail=100 -f
kubectl logs deploy/order-service -n order-service --previous   # if pod restarted
```

**Cluster events:**

```bash
kubectl get events -n order-service --sort-by=.metadata.creationTimestamp
```

**Node-level logs (if pod cannot even start):**

```bash
kubectl describe node <node-name>
# Check: Conditions, Allocated resources, Events
```

**Ingress logs:**

```bash
kubectl logs deploy/ingress-nginx-controller -n ingress-nginx --tail=100
```

**Azure Monitor — historical and aggregated:**

```kql
ContainerLog
| where LogEntry contains "error"
| where TimeGenerated > ago(1h)
| order by TimeGenerated desc
| limit 100
```

**Flux logs (if deployment-related):**

```bash
flux logs --follow
flux get helmreleases -A
```

---

### How would you detect high memory or CPU usage?

**Real-time:**

```bash
kubectl top pods -A               # current CPU/memory for every pod
kubectl top nodes                 # current CPU/memory for every node
```

**Alerts via Azure Monitor:**

```bash
az monitor metrics alert create \
  --name "high-cpu-order-service" \
  --resource-group ecommerce-rg \
  --scopes /subscriptions/.../ecommerce-aks \
  --condition "avg Percentage CPU > 80" \
  --window-size 5m \
  --evaluation-frequency 1m \
  --action <action-group-id>
```

**Prometheus alert rule:**

```yaml
- alert: PodHighMemory
  expr: container_memory_working_set_bytes{namespace="order-service"} > 400Mi
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "order-service memory above 400Mi"
```

**Why OOMKilled is not an alert — it is already an event:** `kubectl get events -n order-service` shows OOMKilled. The action is to increase the memory limit or investigate the memory leak.

---

### What is the difference between metrics, logs, and traces?

| | Metrics | Logs | Traces |
|---|---|---|---|
| What | Numerical measurements over time | Text records of events | End-to-end request path across services |
| Example | CPU: 72%, HTTP requests/sec: 340 | "Order 1234 created successfully" | Request took 250ms: api-gateway→order-service→notification-service |
| Tool | Prometheus, Azure Monitor Metrics | Log Analytics, container logs | Jaeger, Azure Application Insights |
| Best for | Alerting, dashboards, capacity | Debugging, auditing | Identifying slow hops in distributed calls |

In a microservices architecture like this project, traces are particularly valuable. When a user reports a slow order, a trace shows: api-gateway added 5ms, order-service added 240ms (slow database call), notification-service added 3ms. Without traces you would have to manually correlate logs from three services.

---

### How would you troubleshoot intermittent 500 errors in a microservice?

**Step 1 — Quantify the problem**

```bash
# Check ingress access logs for 500 responses
kubectl logs deploy/ingress-nginx-controller -n ingress-nginx | grep " 500 "

# How many? What endpoints? What time pattern?
```

**Step 2 — Correlate with pod restarts**

```bash
kubectl get pods -n order-service
# Are RESTARTS increasing? 500s and restarts often correlate
```

**Step 3 — Check application logs at the time of the 500s**

```kql
# In Log Analytics
ContainerLog
| where LogEntry contains "500" or LogEntry contains "error" or LogEntry contains "exception"
| where TimeGenerated between (datetime("2024-01-15 14:00") .. datetime("2024-01-15 14:30"))
| order by TimeGenerated desc
```

**Step 4 — Check downstream dependencies**

In this project, `order-service` calls `notification-service`. If `notification-service` is slow or unavailable, `order-service` may return 500. Check:

```bash
kubectl logs deploy/notification-service -n notification-service --tail=100
kubectl get pods -n notification-service
```

**Step 5 — Check resource pressure**

```bash
kubectl top pods -n order-service
# CPU throttling or memory pressure causes slow responses that time out as 500
```

**Step 6 — Check Key Vault access**

If `order-service` reads Key Vault secrets on every request (bad pattern) and Key Vault throttles, it returns 500. Check Azure Key Vault metrics for throttling.

---

### How would you monitor ingress traffic?

**NGINX Ingress metrics via Prometheus:**

```bash
# NGINX exposes metrics at /metrics on port 10254
kubectl port-forward svc/ingress-nginx-controller-metrics -n ingress-nginx 10254:10254
curl localhost:10254/metrics | grep nginx_ingress_controller_requests
```

Key metrics:
- `nginx_ingress_controller_requests` — request count by status code, namespace, ingress
- `nginx_ingress_controller_request_duration_seconds` — latency percentiles
- `nginx_ingress_controller_connect_duration_seconds` — upstream connection time

**Grafana dashboard:** Import dashboard ID 9614 for NGINX Ingress — gives you instant 4xx/5xx rates, latency p95/p99, and throughput graphs.

**Alert on error rate:**

```yaml
- alert: HighErrorRate
  expr: |
    sum(rate(nginx_ingress_controller_requests{status=~"5.."}[5m]))
    /
    sum(rate(nginx_ingress_controller_requests[5m])) > 0.05
  for: 2m
  annotations:
    summary: "More than 5% of requests returning 5xx"
```

---

### What dashboards would you create for platform operations?

**Cluster Health Dashboard:**
- Node count and status (Ready/NotReady)
- Node CPU and memory utilisation (warn at 70%, alert at 85%)
- Pod count by namespace
- Pending pods (should always be 0 in steady state)
- HPA current/desired/max replicas

**Application Health Dashboard:**
- Request rate per service
- Error rate per service (4xx, 5xx)
- P95 and P99 latency per endpoint
- Pod restart count (alert if > 3 restarts in 10 minutes)

**Deployment Dashboard:**
- Recent Flux reconciliations and their status
- Image tag currently running per service
- Time since last successful reconciliation

**Security Dashboard:**
- Key Vault access failures (may indicate identity misconfiguration)
- ACR image pull failures
- Failed RBAC authorisations

---

## 6. Live Challenge Prep

---

### Write a Deployment, Service, ConfigMap, and readiness/liveness probes

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: order-service
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-service-config
  namespace: order-service
data:
  NOTIFICATION_SERVICE_URL: "http://notification-service.notification-service.svc.cluster.local:3002"
  LOG_LEVEL: "info"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: order-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
        azure.workload.identity/use: "true"
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
        ports:
        - containerPort: 3001
        envFrom:
        - configMapRef:
            name: order-service-config
        volumeMounts:
        - name: secrets-store
          mountPath: "/mnt/secrets"
          readOnly: true
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
        livenessProbe:
          httpGet:
            path: /health
            port: 3001
          initialDelaySeconds: 10
          periodSeconds: 15
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 3001
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: order-service
spec:
  type: ClusterIP
  selector:
    app: order-service
  ports:
  - port: 3001
    targetPort: 3001
```

**Key points to mention:**
- `resources.requests` must be set for HPA to work
- `resources.limits` prevent a pod from starving other pods on the node
- `initialDelaySeconds` gives the app time to start before probes begin
- `failureThreshold: 3` means 3 consecutive failures before action is taken

---

### Write Terraform for Resource Group, ACR, and AKS basics

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.85"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-terraform"
    storage_account_name = "tfstateaccount"
    container_name       = "tfstate"
    key                  = "aks-dev.tfstate"
  }
}

provider "azurerm" {
  features {}
}

variable "environment" { default = "dev" }
variable "location"    { default = "East US" }

resource "azurerm_resource_group" "rg" {
  name     = "rg-platform-${var.environment}"
  location = var.location
}

resource "azurerm_container_registry" "acr" {
  name                = "platformacr${var.environment}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Premium"
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-platform-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-platform-${var.environment}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "platform-${var.environment}"

  default_node_pool {
    name                 = "system"
    vm_size              = "Standard_D2s_v3"
    auto_scaling_enabled = true
    min_count            = 2
    max_count            = 5
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin = "azure"
    network_policy = "calico"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  azure_policy_enabled      = true

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

output "cluster_name"    { value = azurerm_kubernetes_cluster.aks.name }
output "acr_login_server" { value = azurerm_container_registry.acr.login_server }
```

---

### Write a GitHub Actions pipeline that builds and pushes to ACR

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write   # required for OIDC login
  contents: write   # required to push the tag update commit

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with:
        token: ${{ secrets.GITHUB_TOKEN }}

    - name: Azure Login (OIDC — no secrets)
      uses: azure/login@v1
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Build and push images to ACR
      run: |
        az acr build \
          --registry ecommerceacrdenis \
          --image api-gateway:${{ github.sha }} \
          services/api-gateway

        az acr build \
          --registry ecommerceacrdenis \
          --image order-service:${{ github.sha }} \
          services/order-service

        az acr build \
          --registry ecommerceacrdenis \
          --image notification-service:${{ github.sha }} \
          services/notification-service

    - name: Update image tags in Flux releases
      run: |
        sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/api-gateway.yaml
        sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/order-service.yaml
        sed -i "s/tag: .*/tag: ${{ github.sha }}/" flux/releases/notification-service.yaml

        git config user.email "ci@github.com"
        git config user.name "GitHub Actions"
        git add flux/releases/
        git commit -m "chore: update image tags to ${{ github.sha }}"
        git push origin main
        # Flux detects the push and deploys automatically
```

---

## 7. Behavioral Questions

---

### Tell me about yourself

> "I am a platform engineer focused on cloud-native infrastructure on Azure. I work across the full stack from provisioning AKS clusters with Terraform to setting up GitOps with Flux, securing workloads with Managed Identity and Key Vault, and wiring up observability with Azure Monitor and Prometheus.
>
> Most recently I built out a production-grade e-commerce platform on AKS covering three microservices — api-gateway, order-service, and notification-service — with infrastructure as code in Terraform, GitOps deployment via Flux, passwordless secrets management using Workload Identity, Network Policies for pod isolation, and RBAC for least-privilege access. That project covers most of the stack I would be working with in this role."

---

### Describe a production issue you resolved

> "We had an incident where `order-service` went into CrashLoopBackOff after a deployment. The exit code was 1 and the logs showed the app failing to read `/mnt/secrets/postgres-password`. The secret mount was failing silently.
>
> I described the pod and saw that the SecretProviderClass had not been updated when the Key Vault name changed in a Terraform refactor. The pod was looking for a Key Vault that no longer matched. I updated the SecretProviderClass, applied it, and the pods came back healthy within two minutes.
>
> The lesson was to treat the SecretProviderClass as a first-class dependency of the deployment — any change to Key Vault naming or identity must propagate to the SecretProviderClass before a new deployment goes out."

---

### Tell me about a time a deployment failed

> "A deployment to production failed because the image tag we pushed did not exist in ACR at the time Flux reconciled. The CI/CD pipeline had a race condition — it updated the Flux HelmRelease commit before `az acr build` finished pushing the image. Flux picked up the new tag, tried to pull it, and got ImagePullBackOff.
>
> The fix was to enforce ordering in the pipeline: image push must complete and be verified before the Flux tag update commit is made. We added a step to confirm the image digest exists in ACR before writing to Git:
>
> `az acr manifest list-metadata --registry ecommerceacrdenis --name order-service --query "[?tags[?@=='<sha>']]"`
>
> If that returns empty, the pipeline fails before touching Git."

---

### How do you handle pressure during an incident?

> "I focus on methodical triage rather than jumping to conclusions. The first 5 minutes are always: what is the blast radius, who is affected, what changed recently. I do not touch production until I understand what I am fixing.
>
> I keep a running incident log in a shared doc so the team knows what has been tried and what has been ruled out. I communicate status every 15 minutes even if the update is 'still investigating' so stakeholders are not in the dark.
>
> After the incident I write a blameless post-mortem focused on the system failure, not the person, and turn it into action items with owners and deadlines."

---

### How do you work with developers who do not understand infrastructure?

> "I meet them where they are. If a developer asks 'why can't I just hardcode the database password in the deployment YAML', I do not just say 'security'. I explain what would happen: that YAML is in Git, Git history is forever, and a leaked credential is a breach. Then I show them how the secret mount works and that they do not have to change their code — the file is just at `/mnt/secrets/postgres-password`.
>
> I find that when infrastructure patterns are explained in terms of what they protect the developer from, rather than as rules from platform, adoption is much faster."

---

### How do you handle disagreements about technical decisions?

> "I lead with data. If I think Flux is better than pipeline-driven deployment, I write down the trade-offs: blast radius, audit trail, credentials required, rollback complexity. Then I present both options to the team with that analysis and let the team decide with full information.
>
> If the decision goes the other way, I implement it well and document the trade-offs we accepted. I revisit it if the predicted problems materialise. I do not relitigate closed decisions."

---

### Tell me about a time you improved a CI/CD process

> "The team was doing manual `helm upgrade` commands from developer laptops into production. There was no audit trail, no approval gate, and deployments differed between environments because developers used local chart versions.
>
> I introduced Flux GitOps. The pipeline now only builds images and updates a tag in Git. The cluster reconciles itself. Production deployments require a pull request which has an approval requirement. The deployment history is the Git history. Rollback is a `git revert`.
>
> The immediate benefit was that we caught three cases in the first month where someone had manually patched a production pod — something that would have been invisible before. Flux detected the drift and reverted it on the next reconciliation."

---

### How would you structure Terraform for dev, QA, UAT, and prod?

> "I would use reusable modules for shared components — AKS, ACR, Key Vault, networking, and monitoring — and separate environment directories for dev, QA, UAT, and prod. Each environment has its own backend state file, its own variable values, and its own approval requirements.
>
> I would not use a single shared state file across environments because the blast radius is too high — a failed plan in dev could corrupt the state that prod depends on. Each environment is isolated: if dev is broken, prod still applies cleanly.
>
> For prod specifically, `terraform apply` requires a manual approval in the pipeline and every plan output is reviewed before apply. Dev and QA can auto-apply on merge. UAT requires a sign-off from QA."

---

### Most Likely Question: Explain how you would design a secure AKS platform on Azure

> "I think about this in five layers.
>
> **Infrastructure:** Terraform provisions everything — AKS with autoscaling, ACR with Premium SKU for geo-replication, Key Vault with RBAC authorization and purge protection, Log Analytics for observability, all in one resource group. Remote state in Azure Blob Storage with versioning. Every environment has its own state file.
>
> **Identity:** No passwords anywhere. AKS nodes use System Assigned Managed Identity to pull from ACR via AcrPull role. Application pods use Workload Identity — the pod presents a Kubernetes ServiceAccount token, Azure AD validates it against the AKS OIDC issuer, and issues an access token for the pod's User Assigned Managed Identity. That identity has Key Vault Secrets User on the Key Vault. Secrets are mounted as files by the CSI driver. Nothing is in etcd, nothing is in Git, nothing is in an environment variable.
>
> **Network:** Azure CNI so pods get VNet IPs. Calico enforces Network Policies. In this platform, `order-service` only accepts traffic from the `api-gateway` namespace — everything else is blocked at the network layer. NGINX Ingress is the single external entry point. cert-manager handles TLS automatically.
>
> **Access control:** Kubernetes RBAC gives developers read-only access to pods, services, and events. No exec, no delete, no apply. Azure RBAC gives developers the Cluster User role, not admin. CI/CD has a dedicated service principal with exactly the permissions it needs.
>
> **Deployment:** GitOps with Flux. The cluster polls Git every minute. No human runs `kubectl apply` or `helm upgrade` in production. Every change is a Git commit with an audit trail. Rollback is a `git revert`. Drift is detected and corrected automatically."

---

*Last updated: June 2026*
