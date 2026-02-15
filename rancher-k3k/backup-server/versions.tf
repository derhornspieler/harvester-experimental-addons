terraform {
  required_version = ">= 1.5.0"
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
  }
}
