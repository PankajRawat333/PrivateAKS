variable resource_group {
  description = "rg-MyFirstTerraform"
  type        = string
}

variable location {
  description = "westus"
  type        = string
}

variable pip_name {
  description = "pip"
  type        = string
  default     = "azure-fw-ip"
}

variable fw_name {
  description = "firewall"
  type        = string
}

variable subnet_id {
  description = "subnet"
  type        = string
}