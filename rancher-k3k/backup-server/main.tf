# Look up the VM network
data "harvester_network" "vm_network" {
  name      = var.network.name
  namespace = var.network.namespace
}

# Cloud-init secret for user data and network configuration
resource "harvester_cloudinit_secret" "backup_server" {
  name      = "${var.server_name}-cloudinit"
  namespace = var.namespace

  user_data = <<-USERDATA
    #cloud-config
    hostname: ${var.server_name}

    package_update: true
    package_upgrade: false

    packages:
      - qemu-guest-agent
      - nfs-utils
      - iptables
      - iptables-services
      - curl
      - tar
      - rsync

    users:
      - name: ${var.ssh_user}
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        groups: [wheel]
        shell: /bin/bash
        lock_passwd: true
        ssh_authorized_keys:
          - "${var.ssh_public_key}"

    write_files:
      - path: /etc/exports
        owner: root:root
        permissions: "0644"
        content: |
          ${var.nfs_export} *(rw,sync,no_subtree_check,no_root_squash)

    runcmd:
      - systemctl enable --now qemu-guest-agent.service
      - mkdir -p ${var.nfs_export}
      - chmod 755 ${var.nfs_export}
      - systemctl enable --now nfs-server
      - exportfs -ra
      - |
        iptables -F
        iptables -X
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT
        iptables -A INPUT -i lo -j ACCEPT
        iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport 2049 -j ACCEPT
        iptables -A INPUT -p udp --dport 2049 -j ACCEPT
        iptables -A INPUT -p tcp --dport 111 -j ACCEPT
        iptables -A INPUT -p udp --dport 111 -j ACCEPT
        iptables -A INPUT -p icmp -j ACCEPT
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        cat > /etc/systemd/system/iptables-restore.service << 'EOF'
        [Unit]
        Description=Restore iptables rules
        Before=network-pre.target

        [Service]
        Type=oneshot
        ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl daemon-reload
        systemctl enable iptables-restore.service

    final_message: |
      Backup server initialization completed at $TIMESTAMP
      Hostname: ${var.server_name}
      NFS export: ${var.nfs_export}
  USERDATA

  network_data = <<-NETDATA
    version: 2
    ethernets:
      eth0:
        addresses:
          - ${var.ip_address}/${var.network.prefix}
        gateway4: ${var.network.gateway}
        nameservers:
          addresses:
%{for ns in var.network.nameservers~}
            - ${ns}
%{endfor~}
  NETDATA
}

# Backup server VM
resource "harvester_virtualmachine" "backup_server" {
  name      = var.server_name
  namespace = var.namespace

  description = "NFS backup server for k3k Rancher backups"

  tags = merge(var.labels, {
    "role" = "backup-server"
  })

  cpu    = var.resources.cpu_cores
  memory = "${var.resources.memory_gb}Gi"

  efi         = true
  secure_boot = false

  run_strategy    = "RerunOnFailure"
  hostname        = var.server_name
  machine_type    = "q35"
  reserved_memory = "100Mi"

  network_interface {
    name           = "nic-1"
    wait_for_lease = true
    type           = "bridge"
    network_name   = data.harvester_network.vm_network.id
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    size        = "${var.resources.disk_gb}Gi"
    bus         = "virtio"
    boot_order  = 1
    image       = "${var.vm_image.namespace}/${var.vm_image.name}"
    auto_delete = true
  }

  cloudinit {
    type                     = "noCloud"
    user_data_secret_name    = harvester_cloudinit_secret.backup_server.name
    network_data_secret_name = harvester_cloudinit_secret.backup_server.name
  }

  depends_on = [harvester_cloudinit_secret.backup_server]
}
