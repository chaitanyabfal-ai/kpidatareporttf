terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure for shared/team use — local state (the default)
  # is fine solo but has no locking and isn't shared.
  #
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "ilds/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}
