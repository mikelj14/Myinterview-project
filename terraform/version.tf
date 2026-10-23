terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.11.0" # Updated version constraint
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15.0"
    }
  }
}
