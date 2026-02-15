# Harvester Configuration
harvester_kubeconfig_path = "/Users/jruds/.kube/harvester-config"

# Backup Server Configuration
server_name = "k3k-backup-server"
namespace   = "default"
ip_address  = "172.16.3.249"

# Network Configuration
network = {
  namespace   = "default"
  name        = "vm-network"
  gateway     = "172.16.3.1"
  prefix      = 24
  nameservers = ["172.16.3.1"]
}

# Resource Allocation
resources = {
  cpu_cores = 2
  memory_gb = 4
  disk_gb   = 100
}

# SSH Configuration
ssh_user       = "rocky"
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAw/Ob7ikMCwPwos/Av7govYPic1jqutEM3+F7jm89uI hvst-mgmt"

# VM Image - golden image from RKE2 deployment
vm_image = {
  name      = "rke2-rocky9-golden-20260214"
  namespace = "rke2-prod"
}

# MinIO S3 Configuration
minio_root_password = "minioadmin-secret-2026"

# Labels
labels = {
  environment = "production"
  managed_by  = "terraform"
  project     = "k3k-rancher"
}
