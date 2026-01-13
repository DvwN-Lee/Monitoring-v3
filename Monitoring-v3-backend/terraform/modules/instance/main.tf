# Instance Module - CloudStack Instances for k3s Cluster

terraform {
  required_providers {
    cloudstack = {
      source  = "cloudstack/cloudstack"
      version = "~> 0.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# SSH Keypair for instances
resource "cloudstack_ssh_keypair" "titanium" {
  name       = var.ssh_keypair
  public_key = file("~/.ssh/titanium-key.pub")
}

# Generate random token for k3s cluster
resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

# k3s Master Node
resource "cloudstack_instance" "k3s_master" {
  name             = "${var.cluster_name}-master-v2"
  service_offering = var.service_offering
  template         = var.template
  zone             = var.zone
  network_id       = var.network_id
  keypair          = cloudstack_ssh_keypair.titanium.name
  expunge          = true

  user_data = base64encode(templatefile("${path.module}/scripts/k3s-server.sh", {
    k3s_token = random_password.k3s_token.result
    postgres_password = var.postgres_password
  }))
}

# k3s Worker Nodes
resource "cloudstack_instance" "k3s_worker" {
  count            = var.worker_count
  name             = "${var.cluster_name}-worker-v2-${count.index + 1}"
  service_offering = var.service_offering
  template         = var.template
  zone             = var.zone
  network_id       = var.network_id
  keypair          = cloudstack_ssh_keypair.titanium.name
  expunge          = true

  user_data = base64encode(templatefile("${path.module}/scripts/k3s-agent.sh", {
    master_ip = cloudstack_instance.k3s_master.ip_address
    k3s_token = random_password.k3s_token.result
  }))

  depends_on = [cloudstack_instance.k3s_master]
}

# Wait for k3s cluster to be ready
resource "null_resource" "wait_for_k3s" {
  depends_on = [cloudstack_instance.k3s_worker]

  provisioner "local-exec" {
    command = "sleep 60"
  }
}

# Allocate public IP address
resource "cloudstack_ipaddress" "master_public_ip" {
  zone       = var.zone
  network_id = var.network_id
}

# Port forwarding for SSH, k3s API, and Dashboards
resource "cloudstack_port_forward" "master" {
  ip_address_id = cloudstack_ipaddress.master_public_ip.id

  forward {
    protocol           = "tcp"
    private_port       = 22
    public_port        = 22
    virtual_machine_id = cloudstack_instance.k3s_master.id
  }

  forward {
    protocol           = "tcp"
    private_port       = 6443
    public_port        = 6443
    virtual_machine_id = cloudstack_instance.k3s_master.id
  }

  forward {
    protocol           = "tcp"
    private_port       = 32491
    public_port        = 80
    virtual_machine_id = cloudstack_instance.k3s_master.id
  }

  # Grafana Dashboard
  forward {
    protocol           = "tcp"
    private_port       = 31300
    public_port        = 31300
    virtual_machine_id = cloudstack_instance.k3s_master.id
  }

  # Kiali Dashboard
  forward {
    protocol           = "tcp"
    private_port       = 31200
    public_port        = 31200
    virtual_machine_id = cloudstack_instance.k3s_master.id
  }
}

# Firewall rules for SSH, k3s API, and Dashboards
resource "cloudstack_firewall" "master" {
  ip_address_id = cloudstack_ipaddress.master_public_ip.id

  rule {
    protocol  = "tcp"
    cidr_list = ["0.0.0.0/0"]
    ports     = ["22", "6443", "80", "31300", "31200"]
  }
}

# Create kubeconfig locally pointing to public IP
# ArgoCD bootstrap script will set up the cluster internally
resource "null_resource" "create_kubeconfig" {
  depends_on = [
    cloudstack_instance.k3s_master,
    cloudstack_port_forward.master
  ]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ~/.kube
      cat > ~/.kube/config-solid-cloud <<'KUBE'
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: https://${cloudstack_ipaddress.master_public_ip.ip_address}:6443
  name: solid-cloud
contexts:
- context:
    cluster: solid-cloud
    user: solid-cloud-admin
  name: solid-cloud
current-context: solid-cloud
users:
- name: solid-cloud-admin
  user:
    username: admin
    password: placeholder
KUBE
      echo "Kubeconfig template created at ~/.kube/config-solid-cloud"
      echo "Note: This is a placeholder. Access cluster after k3s bootstrap completes (~5-10 min)"
      echo "To get actual kubeconfig, SSH into master and run: sudo cat /etc/rancher/k3s/k3s.yaml"
    EOT
  }

  triggers = {
    master_ip = cloudstack_ipaddress.master_public_ip.ip_address
  }
}
