variable "harvester_kubeconfig_path" {
  description = "Path to the Harvester kubeconfig file"
  type        = string
}

variable "server_name" {
  description = "Name of the backup server VM"
  type        = string
  default     = "k3k-backup-server"
}

variable "namespace" {
  description = "Harvester namespace for the VM"
  type        = string
  default     = "default"
}

variable "ip_address" {
  description = "Static IP address for the backup server"
  type        = string
}

variable "network" {
  description = "Network configuration for the backup server"
  type = object({
    namespace   = string
    name        = string
    gateway     = string
    prefix      = number
    nameservers = list(string)
  })
}

variable "resources" {
  description = "Resource allocation for the backup server VM"
  type = object({
    cpu_cores = number
    memory_gb = number
    disk_gb   = number
  })
  default = {
    cpu_cores = 2
    memory_gb = 4
    disk_gb   = 100
  }
}

variable "ssh_user" {
  description = "SSH user for the backup server"
  type        = string
  default     = "rocky"
}

variable "ssh_public_key" {
  description = "SSH public key for authentication"
  type        = string
}

variable "vm_image" {
  description = "VM image configuration"
  type = object({
    name      = string
    namespace = string
  })
}

variable "nfs_export" {
  description = "NFS export path for k3k Rancher backups"
  type        = string
  default     = "/srv/nfs/k3k-rancher-backups"
}

variable "labels" {
  description = "Additional labels/tags for the VM"
  type        = map(string)
  default     = {}
}
