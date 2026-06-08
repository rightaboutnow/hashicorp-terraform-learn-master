# variables.tf
# Declare input variables here.

variable "location" {
  description = "Azure region for resources."
  type        = string
  default     = "australiaeast"
}

variable "resource_group_name" {
  description = "Name of the resource group."
  type        = string
  default     = "learn-rg"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    environment = "learning"
    managed_by  = "terraform"
  }
}
