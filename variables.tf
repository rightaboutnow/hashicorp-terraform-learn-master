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

variable "application_name" {
  description = "Name of application"
  type        = string
  default     = "learnapp"
}

variable "environment_name" {
  description = "Name of environment"
  type        = string
  default     = "test"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    environment = "{var.environment_name}"
    managed_by  = "terraform"
    application = "{var.application_name}"
    email       = "Jenson Thomas"
  }
}
