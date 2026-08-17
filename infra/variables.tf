variable "project_name" {
  description = <<-EOT
    Branch-scoped project name, used as the prefix for every resource. Supplied
    by the pipeline as TF_VAR_project_name from the platform's PROJECT_NAME
    secret — deliberately without a default so it can never silently drift.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, starting with a letter."
  }
}

variable "kubernetes_version" {
  description = "EKS control plane minor version."
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Number of worker nodes to run. The group's ceiling is this plus two."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 1 && var.node_desired_size <= 20
    error_message = "node_desired_size must be between 1 and 20."
  }
}

variable "db_instance_class" {
  description = "RDS instance class for the Postgres database."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Postgres storage in GB (gp3)."
  type        = number
  default     = 20
}

variable "vpc_cidr" {
  description = "CIDR block for the project VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "log_retention_days" {
  description = "Retention for the CloudWatch log groups this stack owns."
  type        = number
  default     = 14
}
