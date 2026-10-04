terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is local and gitignored.
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Refuse to run against any other account.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = "amazon-webinar-demo"
      ManagedBy = "terraform"
    }
  }
}
