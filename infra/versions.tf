terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pinned below 5.83.0 deliberately: from 5.83.0 the provider made
      # aws_db_instance.password write-only, which breaks reading the
      # generated password back out for the application secret.
      version = "~> 5.82.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state is mandatory and its settings are supplied by the pipeline as
  # -backend-config flags (bucket, key, region). This block must stay EMPTY:
  # backend blocks cannot use variables, and hardcoding the key loses state
  # between retries.
  backend "s3" {}
}

provider "aws" {
  # Region comes from AWS_REGION in the pipeline's stage env, so there is one
  # source of truth for the whole deploy (provider, backend, AWS CLI, kubectl).
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap-terraform"
      Blueprint = "python-eks"
    }
  }
}
