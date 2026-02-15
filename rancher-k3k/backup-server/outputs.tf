output "server_name" {
  description = "Name of the backup server VM"
  value       = harvester_virtualmachine.backup_server.name
}

output "ip_address" {
  description = "IP address of the backup server"
  value       = var.ip_address
}

output "nfs_export" {
  description = "NFS export path configured on the server"
  value       = var.nfs_export
}

output "ssh_command" {
  description = "SSH command to connect to the backup server"
  value       = "ssh ${var.ssh_user}@${var.ip_address}"
}

output "nfs_mount" {
  description = "NFS mount command for verification"
  value       = "showmount -e ${var.ip_address}"
}

output "minio_endpoint" {
  description = "MinIO S3 endpoint for rancher-backup operator"
  value       = "${var.ip_address}:9000"
}

output "minio_console" {
  description = "MinIO console URL"
  value       = "https://${var.ip_address}:9001"
}

output "minio_bucket" {
  description = "MinIO bucket for backups"
  value       = var.minio_bucket
}
