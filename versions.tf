terraform {
  required_version = "~> 1.14.8"

  cloud {
    organization = "my-terraform-org-0"

    workspaces {
      name = "my-terraform-workspace-0"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.28"
    }
  }
}
