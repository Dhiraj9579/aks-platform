data "azurerm_client_config" "current" {}

locals {
  acr_regions = toset([
    lower(replace(var.location, " ", "")),
    lower(replace(var.acr_replica_location, " ", "")),
  ])
}

resource "azurerm_resource_group" "main" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet"
  address_space       = ["10.40.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_network_security_group" "main" {
  name                = "${var.name_prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.40.0.0/20"]
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_subnet" "api_server" {
  name                 = "aks-api-server"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.40.16.0/28"]

  delegation {
    name = "aks-api-server"
    service_delegation {
      name = "Microsoft.ContainerService/managedClusters"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "api_server" {
  subnet_id                 = azurerm_subnet.api_server.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = ["10.40.17.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.main.id
}

resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "${var.name_prefix}-aks-control"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "${var.name_prefix}-aks-kubelet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "aks_api_server_network" {
  scope                = azurerm_subnet.api_server.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_log_analytics_workspace" "main" {
  name                         = "${var.name_prefix}-logs"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  sku                          = "PerGB2018"
  retention_in_days            = 30
  local_authentication_enabled = false
  tags                         = var.tags
}

resource "azurerm_container_registry" "main" {
  name                          = "${var.name_prefix}${substr(sha1(azurerm_resource_group.main.id), 0, 6)}acr"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  zone_redundancy_enabled       = true
  data_endpoint_enabled         = true
  retention_policy_in_days      = 30
  georeplications {
    location                = var.acr_replica_location
    zone_redundancy_enabled = true
  }
  # Quarantine blocks deployment until a release-promotion workflow is configured.
  #checkov:skip=CKV_AZURE_166: Image quarantine is deferred until CI can scan and promote verified images.
  # Legacy ACR Content Trust is not used; adopt supported image signing and verification before production.
  #checkov:skip=CKV_AZURE_164: Use modern image signing and verification rather than legacy ACR Content Trust.
  tags = var.tags
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "acr_data" {
  for_each            = local.acr_regions
  name                = "privatelink.${each.value}.data.azurecr.io"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "${var.name_prefix}-acr-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_data" {
  for_each              = azurerm_private_dns_zone.acr_data
  name                  = "${var.name_prefix}-${each.key}-data-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "${var.name_prefix}-acr-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name_prefix}-acr-connection"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "acr-private-dns"
    private_dns_zone_ids = concat(
      [azurerm_private_dns_zone.acr.id],
      [for zone in azurerm_private_dns_zone.acr_data : zone.id]
    )
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.private_endpoints,
    azurerm_private_dns_zone_virtual_network_link.acr_data,
  ]
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_key_vault" "main" {
  name                          = "${var.name_prefix}-${substr(sha1(azurerm_resource_group.main.id), 0, 8)}-kv"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "premium"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 30
  purge_protection_enabled      = true
  public_network_access_enabled = false
  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
  }
  tags = var.tags
}

resource "azurerm_role_assignment" "terraform_key_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_user_assigned_identity" "disk_encryption" {
  name                = "${var.name_prefix}-disk-encryption"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "disk_encryption_key_access" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.disk_encryption.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_key_vault_key" "disk_encryption" {
  name            = "${var.name_prefix}-aks-disk"
  key_vault_id    = azurerm_key_vault.main.id
  key_type        = "RSA-HSM"
  key_size        = 2048
  key_opts        = ["unwrapKey", "wrapKey"]
  expiration_date = "2036-01-01T00:00:00Z"

  rotation_policy {
    automatic {
      time_after_creation = "P90D"
    }
    expire_after         = "P365D"
    notify_before_expiry = "P30D"
  }

  depends_on = [
    azurerm_role_assignment.terraform_key_officer,
    azurerm_private_endpoint.key_vault,
    azurerm_private_dns_zone_virtual_network_link.key_vault,
  ]
}

resource "azurerm_disk_encryption_set" "aks" {
  name                      = "${var.name_prefix}-aks-des"
  location                  = azurerm_resource_group.main.location
  resource_group_name       = azurerm_resource_group.main.name
  key_vault_key_id          = azurerm_key_vault_key.disk_encryption.id
  encryption_type           = "EncryptionAtRestWithCustomerKey"
  auto_key_rotation_enabled = true
  tags                      = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.disk_encryption.id]
  }

  depends_on = [azurerm_role_assignment.disk_encryption_key_access]
}

resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "${var.name_prefix}-kv-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.name_prefix}-kv-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name_prefix}-kv-connection"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "key-vault-private-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }

  depends_on = [azurerm_subnet_network_security_group_association.private_endpoints]
}

resource "azurerm_kubernetes_cluster" "main" {
  name                      = "${var.name_prefix}-aks"
  location                  = azurerm_resource_group.main.location
  resource_group_name       = azurerm_resource_group.main.name
  dns_prefix                = "${var.name_prefix}-aks"
  private_cluster_enabled   = true
  local_account_disabled    = true
  sku_tier                  = "Standard"
  automatic_upgrade_channel = "stable"
  node_os_upgrade_channel   = "SecurityPatch"
  workload_identity_enabled = true
  oidc_issuer_enabled       = true
  azure_policy_enabled      = true
  disk_encryption_set_id    = azurerm_disk_encryption_set.aks.id
  tags                      = var.tags

  default_node_pool {
    name                         = "system"
    vm_size                      = "Standard_D2s_v5"
    vnet_subnet_id               = azurerm_subnet.aks.id
    auto_scaling_enabled         = true
    min_count                    = 2
    max_count                    = 5
    node_count                   = 2
    max_pods                     = 50
    only_critical_addons_enabled = true
    os_sku                       = "AzureLinux"
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = 64
    host_encryption_enabled      = true
    upgrade_settings {
      max_surge = "33%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.aks_kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.aks_kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_kubelet.id
  }

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  network_profile {
    network_plugin     = "azure"
    network_policy     = "azure"
    network_data_plane = "azure"
    load_balancer_sku  = "standard"
    outbound_type      = "loadBalancer"
    service_cidr       = "10.1.0.0/16"
    dns_service_ip     = "10.1.0.10"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = azurerm_subnet.api_server.id
  }

  depends_on = [
    azurerm_role_assignment.aks_network,
    azurerm_role_assignment.aks_api_server_network,
    azurerm_role_assignment.kubelet_acr_pull,
    azurerm_subnet_network_security_group_association.aks,
    azurerm_subnet_network_security_group_association.api_server,
    azurerm_private_endpoint.acr,
    azurerm_private_dns_zone_virtual_network_link.acr,
  ]
}

resource "azurerm_role_assignment" "aks_admin" {
  for_each             = toset(var.aks_admin_object_ids)
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
  principal_type       = "User"
}

resource "azurerm_role_assignment" "aks_key_vault_secrets" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster_node_pool" "workload" {
  name                    = "workload"
  kubernetes_cluster_id   = azurerm_kubernetes_cluster.main.id
  vm_size                 = "Standard_D2s_v5"
  mode                    = "User"
  vnet_subnet_id          = azurerm_subnet.aks.id
  auto_scaling_enabled    = true
  min_count               = 2
  max_count               = 4
  node_count              = 2
  max_pods                = 50
  os_sku                  = "AzureLinux"
  os_disk_type            = "Ephemeral"
  os_disk_size_gb         = 64
  host_encryption_enabled = true
  tags                    = var.tags
}

resource "azurerm_role_assignment" "ci_acr_push" {
  count                = var.ci_principal_object_id == null ? 0 : 1
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = var.ci_principal_object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "ci_aks_user" {
  count                = var.ci_principal_object_id == null ? 0 : 1
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.ci_principal_object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "ci_aks_admin" {
  count                = var.ci_principal_object_id == null ? 0 : 1
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.ci_principal_object_id
  principal_type       = "ServicePrincipal"
}
