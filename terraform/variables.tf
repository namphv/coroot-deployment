variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "coroot-monitoring-cluster"
}

variable "network_name" {
  description = "VPC Network Name"
  type        = string
  default     = "coroot-network"
}

variable "subnet_name" {
  description = "VPC Subnet Name"
  type        = string
  default     = "coroot-subnet"
}

variable "subnet_cidr" {
  description = "VPC Subnet CIDR"
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary IP range for pods"
  type        = string
  default     = "10.4.0.0/14"
}

variable "services_cidr" {
  description = "Secondary IP range for services"
  type        = string
  default     = "10.8.0.0/20"
}

variable "monitoring_node_count" {
  description = "Number of monitoring nodes"
  type        = number
  default     = 3
}

variable "storage_node_count" {
  description = "Number of storage nodes"
  type        = number
  default     = 3
}

variable "spot_min_nodes" {
  description = "Minimum number of spot nodes"
  type        = number
  default     = 2
}

variable "spot_max_nodes" {
  description = "Maximum number of spot nodes"
  type        = number
  default     = 20
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}
