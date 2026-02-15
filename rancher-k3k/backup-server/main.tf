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
      - openssl

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
      # --- MinIO S3 server (used by rancher-backup operator) ---
      - |
        curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio
        chmod +x /usr/local/bin/minio
        curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
        chmod +x /usr/local/bin/mc
      - useradd -r -s /sbin/nologin minio-user
      - chown minio-user:minio-user ${var.nfs_export}
      - |
        cat > /etc/default/minio << 'MINIO_ENV'
        MINIO_ROOT_USER=${var.minio_root_user}
        MINIO_ROOT_PASSWORD=${var.minio_root_password}
        MINIO_VOLUMES="${var.nfs_export}"
        MINIO_OPTS="--address :9000 --console-address :9001"
        MINIO_ENV
      # Generate self-signed TLS cert for MinIO (operator requires HTTPS)
      - mkdir -p /etc/minio/certs
      - |
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
          -keyout /etc/minio/certs/private.key \
          -out /etc/minio/certs/public.crt \
          -subj "/CN=${var.server_name}" \
          -addext "subjectAltName=IP:${var.ip_address}"
        chown -R minio-user:minio-user /etc/minio
      - |
        cat > /etc/systemd/system/minio.service << 'MINIO_SVC'
        [Unit]
        Description=MinIO Object Storage
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=minio-user
        Group=minio-user
        EnvironmentFile=/etc/default/minio
        ExecStart=/usr/local/bin/minio server $MINIO_VOLUMES $MINIO_OPTS --certs-dir /etc/minio/certs
        Restart=always
        RestartSec=10
        LimitNOFILE=65536

        [Install]
        WantedBy=multi-user.target
        MINIO_SVC
        systemctl daemon-reload
        systemctl enable --now minio.service
      # Create the backup bucket after MinIO starts
      - |
        sleep 5
        /usr/local/bin/mc alias set local https://127.0.0.1:9000 ${var.minio_root_user} ${var.minio_root_password} --insecure
        /usr/local/bin/mc mb local/${var.minio_bucket} --insecure 2>/dev/null || true
      # --- Firewall ---
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
        iptables -A INPUT -p tcp --dport 9000 -j ACCEPT
        iptables -A INPUT -p tcp --dport 9001 -j ACCEPT
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
      MinIO S3: https://${var.ip_address}:9000 (bucket: ${var.minio_bucket})
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

  description = "NFS + MinIO S3 backup server for k3k Rancher backups"

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
