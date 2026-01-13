# Network Module Variables

variable "network_name" {
  description = "Name of the CloudStack network"
  type        = string
}

variable "cidr" {
  description = "CIDR block for the network"
  type        = string
}

variable "zone" {
  description = "CloudStack zone name"
  type        = string
}

variable "network_offering" {
  description = "CloudStack network offering name"
  type        = string
}
