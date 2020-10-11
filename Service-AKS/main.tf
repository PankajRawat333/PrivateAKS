provider "azurerm" {
  # The "feature" block is required for AzureRM provider 2.x. 
  # If you are using version 1.x, the "features" block is not allowed.
  version = "~>2.0"
  features {}
  
  skip_provider_registration = true
}

terraform {
  backend "azurerm" {
  }
}

#######-----------Declaring Data for the process -----------------------------------------#

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name              =  var.resource_group_name
}

data "azurerm_log_analytics_workspace" "log_analytics_monitoring" {
  name                = "z-soc-ngs-clc-test-ew1-log01"
  resource_group_name = var.resource_group_name
}

## Importing AKS Key Vault
data "azurerm_key_vault" "aks_key_vault" {
  name                = "zsocngsclctestew1key01"
  resource_group_name = "z-soc-ngs-clc-test-ew1-rgp01"
}

## Importing the secrets

data "azurerm_key_vault_secret" "aks_spn_id" {
  name         = "aks-spn-id"
  key_vault_id = data.azurerm_key_vault.aks_key_vault.id
}

data "azurerm_key_vault_secret" "aks_spn_secret" {
  name         = "aks-spn-secret"
  key_vault_id = data.azurerm_key_vault.aks_key_vault.id
}

data "azurerm_key_vault_secret" "docker_username" {
  name         = "AKS-repo-username"
  key_vault_id = data.azurerm_key_vault.aks_key_vault.id
}

data "azurerm_key_vault_secret" "docker_password" {
  name         = "AKS-repo-password"
  key_vault_id = data.azurerm_key_vault.aks_key_vault.id
}

module "NetworkAKS" {
  source              = "./modules/NetworkAKS"
  resource_group_name = var.resource_group_name
  location            = data.azurerm_resource_group.rg.location
  vnet_name           = var.aks_vnet_name
  address_space       = var.aks_address_space
  subnets = [
    {
      name : "AzureFirewallSubnet"
      address_prefixes : ["10.0.0.0/24"]
    },
    {
      name : "AKS-Subnet"
      address_prefixes : ["10.0.1.0/24"]
    }
  ]
}

module "VirtualNetworkPeering" {
  source              = "./modules/VirtualNetworkPeering"
  vnet_1_name         = "Main-VNET-Name"
  vnet_1_id           = "module.hub_network.vnet_id"
  vnet_1_rg           = "azurerm_resource_group.vnet"
  vnet_2_name         = var.aks_vnet_name
  vnet_2_id           = module.NetworkAKS.vnet_id
  vnet_2_rg           = var.resource_group_name
  peering_name_1_to_2 = "HubToSpoke"
  peering_name_2_to_1 = "SpokeToHub"
}

module "AzureFirewallAKS" {
  source         = "./modules/AzureFirewallAKS"
  resource_group = var.resource_group_name
  location       = data.azurerm_resource_group.rg.location
  pip_name       = "azureFirewalls-ip"
  fw_name        = "kubenetfw"
  subnet_id      = module.NetworkAKS.subnet_ids["AzureFirewallSubnet"]
}

module "RouteTableAKS" {
  source             = "./modules/RouteTableAKS"
  resource_group     = var.resource_group_name
  location           = data.azurerm_resource_group.rg.location
  rt_name            = var.aks_rt_name
  r_name             = var.aks_r_name
  firewal_private_ip = module.AzureFirewallAKS.fw_private_ip
  subnet_id          = module.NetworkAKS.subnet_ids["AKS-Subnet"]
}

resource "azurerm_kubernetes_cluster" "k8s" {
  name                = var.aks_cluster_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.aks_dns_prefix
  kubernetes_version  = "1.19.0"
  private_cluster_enabled = true
  linux_profile {
    admin_username = var.aks_admin_username
    ssh_key {
      key_data = var.aks_ssh_public_key
    }
  }
  default_node_pool {
    name                = var.aks_node_pool_name
    enable_auto_scaling = true
    node_count          = var.aks_agent_count
    min_count           = var.aks_min_agent_count
    max_count           = var.aks_max_agent_count
    vm_size             = var.aks_node_pool_vm_size
  }
  service_principal {
    client_id     = data.azurerm_key_vault_secret.aks_spn_id.value
    client_secret = data.azurerm_key_vault_secret.aks_spn_secret.value
  }
  addon_profile {
    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = data.azurerm_log_analytics_workspace.log_analytics_monitoring.id
    }
  }

  tags = data.azurerm_resource_group.rg.tags
}

## Saving the kube raw config to the keyvault
resource "azurerm_key_vault_secret" "key_vault_secret_aks" {
  depends_on   = [azurerm_kubernetes_cluster.k8s]
  name         = "AKS-Raw-Config"
  value        = azurerm_kubernetes_cluster.k8s.kube_config_raw
  key_vault_id = data.azurerm_key_vault.aks_key_vault.id
  tags         = data.azurerm_resource_group.rg.tags
}


#######-----------Using helm charts for deploying AKS -----------------------------------------#
provider "helm" {
  kubernetes {
    load_config_file       = false
    host                   = azurerm_kubernetes_cluster.k8s.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.k8s.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.k8s.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.k8s.kube_config.0.cluster_ca_certificate)
  }
}

resource "helm_release" "clc" {
  name = "clc-release"
  repository = "http://helm.cyberproof.io:8080"
  chart = "clc"
  version = "1.1.71-axa"
  dependency_update = true
  wait = false
  timeout = 1800

  values = [
    "${file("./helm/values.yaml")}"
  ]

  set {
    name = "client_id"
    value = data.azurerm_key_vault_secret.aks_spn_id.value
  }

  set {
    name = "client_secret"
    value = data.azurerm_key_vault_secret.aks_spn_secret.value
  }

  set {
    name = "clc-receiver-cybereason.logstash.keyvault.volumes[0].flexVolume.options.keyvaultname"
    value = data.azurerm_key_vault.aks_key_vault.name
  }

  set {
    name = "clc-receiver-cybereason.logstash.keyvault.volumes[0].flexVolume.options.tenantid"
    value = data.azurerm_client_config.current.tenant_id
  }

  set {
    name = "clc-receiver-eh2eh.logstash.keyvault.volumes[0].flexVolume.options.keyvaultname"
    value = data.azurerm_key_vault.aks_key_vault.name
  }

  set {
    name = "clc-receiver-eh2eh.logstash.keyvault.volumes[0].flexVolume.options.tenantid"
    value = data.azurerm_client_config.current.tenant_id
  }

    set {
    name  = "clc-parser-cef.logstash.keyvault.volumes[0].flexVolume.options.keyvaultname"
    value = data.azurerm_key_vault.aks_key_vault.name
  }

  set {
    name  = "clc-parser-cef.logstash.keyvault.volumes[0].flexVolume.options.tenantid"
    value = data.azurerm_client_config.current.tenant_id
  }

  set {
    name  = "clc-loader-bulk.logstash.keyvault.volumes[0].flexVolume.options.keyvaultname"
    value = data.azurerm_key_vault.aks_key_vault.name
  }

  set {
    name  = "clc-loader-bulk.logstash.keyvault.volumes[0].flexVolume.options.tenantid"
    value = data.azurerm_client_config.current.tenant_id
  }

  set {
    name = "imageCredentials.registry"
    value = var.imageCredentials_registry
  }

  set {
    name = "imageCredentials.username"
    value = data.azurerm_key_vault_secret.docker_username.value
  }
  
  set {
    name = "imageCredentials.password"
    value = data.azurerm_key_vault_secret.docker_password.value
  }  
}