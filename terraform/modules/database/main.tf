# Database Module - PostgreSQL on Kubernetes
# Manages PostgreSQL deployment via Kubernetes resources

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

variable "namespace" {
  description = "Kubernetes namespace for PostgreSQL"
  type        = string
  default     = "titanium-prod"
}

variable "postgres_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "15-alpine"
}

variable "storage_size" {
  description = "Storage size for PostgreSQL PVC"
  type        = string
  default     = "10Gi"
}

variable "postgres_password" {
  description = "PostgreSQL root password"
  type        = string
  sensitive   = true
}

# PostgreSQL Secret
resource "kubernetes_secret" "postgresql" {
  metadata {
    name      = "postgresql-secret"
    namespace = var.namespace
    labels = {
      app        = "postgresql"
      managed_by = "terraform"
    }
  }

  data = {
    POSTGRES_USER     = "postgres"
    POSTGRES_PASSWORD = var.postgres_password
    POSTGRES_DB       = "titanium"
  }

  type = "Opaque"
}

# PostgreSQL ConfigMap for init scripts
resource "kubernetes_config_map" "postgresql_init" {
  metadata {
    name      = "postgresql-init"
    namespace = var.namespace
    labels = {
      app = "postgresql"
    }
  }

  data = {
    "init.sql" = <<-EOT
      -- Initialize users table for user-service
      CREATE TABLE IF NOT EXISTS users (
          id SERIAL PRIMARY KEY,
          username VARCHAR(100) UNIQUE NOT NULL,
          email VARCHAR(255) NOT NULL,
          password_hash VARCHAR(255) NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

      -- Initialize categories table for blog-service
      CREATE TABLE IF NOT EXISTS categories (
          id SERIAL PRIMARY KEY,
          name VARCHAR(50) NOT NULL UNIQUE,
          slug VARCHAR(50) NOT NULL UNIQUE
      );

      -- Insert default categories
      INSERT INTO categories (id, name, slug) VALUES
          (1, '기술 스택', 'tech-stack'),
          (2, 'Troubleshooting', 'troubleshooting'),
          (3, 'Test', 'test')
      ON CONFLICT (id) DO NOTHING;

      -- Initialize posts table for blog-service
      CREATE TABLE IF NOT EXISTS posts (
          id SERIAL PRIMARY KEY,
          title VARCHAR(200) NOT NULL,
          content TEXT NOT NULL,
          author VARCHAR(100) NOT NULL,
          category_id INTEGER NOT NULL REFERENCES categories(id),
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_posts_author ON posts(author);
      CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at DESC);
      CREATE INDEX IF NOT EXISTS idx_posts_category_id ON posts(category_id);

      -- Grant permissions
      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO postgres;
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO postgres;
    EOT
  }
}

# PostgreSQL PersistentVolumeClaim
resource "kubernetes_persistent_volume_claim" "postgresql" {
  wait_until_bound = true

  metadata {
    name      = "postgresql-pvc"
    namespace = var.namespace
    labels = {
      app = "postgresql"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "local-path"
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# PostgreSQL StatefulSet
resource "kubernetes_stateful_set" "postgresql" {
  metadata {
    name      = "postgresql"
    namespace = var.namespace
    labels = {
      app        = "postgresql"
      managed_by = "terraform"
    }
  }

  spec {
    service_name = "postgresql-service"
    replicas     = 1

    selector {
      match_labels = {
        app = "postgresql"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgresql"
        }
      }

      spec {
        container {
          name  = "postgresql"
          image = "postgres:${var.postgres_version}"

          port {
            container_port = 5432
            name           = "postgres"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret.postgresql.metadata[0].name
            }
          }

          volume_mount {
            name       = "postgresql-data"
            mount_path = "/var/lib/postgresql/data"
          }

          volume_mount {
            name       = "init-scripts"
            mount_path = "/docker-entrypoint-initdb.d"
          }

          resources {
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres"]
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres"]
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }

        volume {
          name = "postgresql-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgresql.metadata[0].name
          }
        }

        volume {
          name = "init-scripts"
          config_map {
            name = kubernetes_config_map.postgresql_init.metadata[0].name
          }
        }
      }
    }
  }
}

# PostgreSQL Service
resource "kubernetes_service" "postgresql" {
  metadata {
    name      = "postgresql-service"
    namespace = var.namespace
    labels = {
      app = "postgresql"
    }
  }

  spec {
    selector = {
      app = "postgresql"
    }

    port {
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

output "service_name" {
  description = "PostgreSQL service name"
  value       = kubernetes_service.postgresql.metadata[0].name
}

output "service_port" {
  description = "PostgreSQL service port"
  value       = kubernetes_service.postgresql.spec[0].port[0].port
}

output "database_name" {
  description = "PostgreSQL database name"
  value       = "titanium"
}
