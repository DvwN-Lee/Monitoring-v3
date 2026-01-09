# Managed Instance Group (MIG) for k3s Worker Nodes
# Auto-healing 기반 Self-healing Infrastructure 구현

# Health Check for Auto-healing
resource "google_compute_health_check" "k3s_autohealing" {
  name                = "${var.cluster_name}-worker-health-check"
  description         = "Health check for k3s worker nodes (Kubelet port)"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = "10250" # Kubelet port
  }
}

# Instance Template for Worker Nodes
resource "google_compute_instance_template" "k3s_worker" {
  name_prefix  = "${var.cluster_name}-worker-"
  machine_type = var.worker_machine_type
  region       = var.region

  tags = ["k3s-worker", "k3s-node"]

  labels = merge(local.common_labels, {
    role = "k3s-worker"
  })

  disk {
    source_image = var.os_image
    disk_size_gb = var.worker_disk_size
    disk_type    = "pd-balanced"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    # Ephemeral public IP
    access_config {
      network_tier = "STANDARD"
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"
  }

  metadata_startup_script = templatefile("${path.module}/scripts/k3s-agent.sh", {
    master_ip = google_compute_instance.k3s_master.network_interface[0].network_ip
    k3s_token = random_password.k3s_token.result
  })

  service_account {
    email  = google_service_account.k3s_sa.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Spot (Preemptible) VM configuration
  scheduling {
    preemptible                 = var.use_spot_for_workers
    automatic_restart           = false # Spot VM은 automatic_restart 불가
    on_host_maintenance         = "TERMINATE"
    provisioning_model          = var.use_spot_for_workers ? "SPOT" : "STANDARD"
    instance_termination_action = var.use_spot_for_workers ? "STOP" : null
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_compute_instance.k3s_master,
    google_service_account.k3s_sa,
    google_project_iam_member.sa_logging,
    google_project_iam_member.sa_monitoring
  ]
}

# Zone Managed Instance Group (단일 Zone에서 운영)
resource "google_compute_instance_group_manager" "k3s_workers" {
  name               = "${var.cluster_name}-worker-mig"
  base_instance_name = "${var.cluster_name}-worker"
  zone               = var.zone
  target_size        = var.worker_count

  # Issue #37: wait_for_instances 비활성화 - gcloud provisioner로 대기 책임 위임
  # Terraform은 MIG 리소스 생성만 담당, 안정화 대기는 provisioner에서 처리
  wait_for_instances = false

  version {
    instance_template = google_compute_instance_template.k3s_worker.id
  }

  # Auto-healing Policy
  auto_healing_policies {
    health_check      = google_compute_health_check.k3s_autohealing.id
    initial_delay_sec = 300 # k3s 설치 및 Join 대기 시간 (5분)
  }

  # Update Policy - Rolling update
  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    max_surge_fixed                = 1
    max_unavailable_fixed          = 0
    replacement_method             = "SUBSTITUTE"
  }

  # Named ports for potential future load balancing
  named_port {
    name = "kubelet"
    port = 10250
  }

  depends_on = [
    google_compute_instance.k3s_master,
    google_compute_health_check.k3s_autohealing
  ]

  # Issue #37: gcloud CLI로 인스턴스 안정화 대기 (Gemini 권장)
  # Terraform 리소스 생성 후 MIG가 STABLE 상태가 될 때까지 대기
  provisioner "local-exec" {
    command     = "gcloud compute instance-groups managed wait-until --stable ${self.name} --zone ${self.zone} --timeout 1200"
    interpreter = ["/bin/bash", "-c"]
    when        = create
  }
}
