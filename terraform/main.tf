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
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.lawaks.id
  }
}

# Give the cluster permission to pull images from ACR — no password needed
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
  name                        = "ecommerce-kv-aks"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = true
  enable_rbac_authorization   = true
}

# Grant the identity read access to Key Vault secrets
resource "azurerm_role_assignment" "order_service_kv" {
  principal_id         = azurerm_user_assigned_identity.order_service.principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.kv.id
}

# Output the client ID needed for SecretProviderClass and the service account annotation
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