# Makefile for GCP k3s Terraform Environment
# 사용법: make help

.PHONY: help init plan apply destroy kubeconfig status clean

# 기본 변수
KUBECONFIG_PATH ?= $(HOME)/.kube/config-gcp
BOOTSTRAP_TIMEOUT ?= 600
SSH_KEY ?= $(HOME)/.ssh/titanium-key

help: ## 도움말 표시
	@echo "GCP k3s Terraform Environment"
	@echo ""
	@echo "사용 가능한 명령어:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "일반적인 워크플로우:"
	@echo "  1. make init      # Terraform 초기화"
	@echo "  2. make plan      # 변경사항 확인"
	@echo "  3. make apply     # 인프라 배포"
	@echo "  4. make kubeconfig  # kubeconfig 설정 (Bootstrap 완료 대기)"
	@echo "  5. make status    # 클러스터 상태 확인"

init: ## Terraform 초기화
	terraform init

plan: ## Terraform plan 실행
	terraform plan

apply: ## Terraform apply 실행 (인프라 배포)
	@echo "환경 변수 확인 중..."
	@if [ -z "$$TF_VAR_grafana_admin_password" ]; then \
		echo "ERROR: TF_VAR_grafana_admin_password 환경 변수가 설정되지 않았습니다."; \
		echo "  export TF_VAR_grafana_admin_password='your-secure-password'"; \
		exit 1; \
	fi
	@if [ -z "$$TF_VAR_postgres_password" ]; then \
		echo "ERROR: TF_VAR_postgres_password 환경 변수가 설정되지 않았습니다."; \
		echo "  export TF_VAR_postgres_password='your-secure-password'"; \
		exit 1; \
	fi
	terraform apply

apply-auto: ## Terraform apply 자동 승인 (CI/CD용)
	@if [ -z "$$TF_VAR_grafana_admin_password" ] || [ -z "$$TF_VAR_postgres_password" ]; then \
		echo "ERROR: 필수 환경 변수가 설정되지 않았습니다."; \
		exit 1; \
	fi
	terraform apply -auto-approve

destroy: ## Terraform destroy 실행 (인프라 삭제)
	terraform destroy

destroy-auto: ## Terraform destroy 자동 승인 (주의!)
	terraform destroy -auto-approve

kubeconfig: ## Bootstrap 완료 대기 후 kubeconfig 설정
	@echo "kubeconfig 설정 중..."
	@chmod +x ./scripts/get-kubeconfig.sh
	./scripts/get-kubeconfig.sh --timeout $(BOOTSTRAP_TIMEOUT) --output $(KUBECONFIG_PATH) --ssh-key $(SSH_KEY)

kubeconfig-nowait: ## 즉시 kubeconfig 가져오기 (Bootstrap 완료 가정)
	@echo "kubeconfig 즉시 가져오기..."
	@MASTER_IP=$$(terraform output -raw master_external_ip); \
	mkdir -p $$(dirname $(KUBECONFIG_PATH)); \
	ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) ubuntu@$$MASTER_IP "sudo cat /etc/rancher/k3s/k3s.yaml" | \
		sed "s/127.0.0.1/$$MASTER_IP/g" > $(KUBECONFIG_PATH); \
	chmod 600 $(KUBECONFIG_PATH); \
	echo "kubeconfig 저장됨: $(KUBECONFIG_PATH)"

status: ## 클러스터 및 서비스 상태 확인
	@echo "=== Cluster Nodes ==="
	@KUBECONFIG=$(KUBECONFIG_PATH) kubectl get nodes 2>/dev/null || echo "클러스터에 연결할 수 없습니다."
	@echo ""
	@echo "=== ArgoCD Applications ==="
	@KUBECONFIG=$(KUBECONFIG_PATH) kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD 정보를 가져올 수 없습니다."
	@echo ""
	@echo "=== Pods (all namespaces) ==="
	@KUBECONFIG=$(KUBECONFIG_PATH) kubectl get pods -A 2>/dev/null || echo "Pod 정보를 가져올 수 없습니다."

urls: ## 서비스 URL 출력
	@echo "=== Service URLs ==="
	@MASTER_IP=$$(terraform output -raw master_external_ip 2>/dev/null); \
	echo "ArgoCD:     http://$$MASTER_IP:30080"; \
	echo "Grafana:    http://$$MASTER_IP:31300"; \
	echo "Prometheus: http://$$MASTER_IP:31090"; \
	echo "Kiali:      http://$$MASTER_IP:31200"; \
	echo "Blog:       http://$$MASTER_IP:31080/blog/"

argocd-password: ## ArgoCD admin 비밀번호 출력
	@KUBECONFIG=$(KUBECONFIG_PATH) kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' 2>/dev/null | base64 -d && echo "" || \
		echo "ArgoCD 비밀번호를 가져올 수 없습니다."

ssh: ## Master 노드에 SSH 접속
	@MASTER_IP=$$(terraform output -raw master_external_ip); \
	echo "Connecting to ubuntu@$$MASTER_IP..."; \
	ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) ubuntu@$$MASTER_IP

logs: ## Bootstrap 로그 확인
	@MASTER_IP=$$(terraform output -raw master_external_ip); \
	ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) ubuntu@$$MASTER_IP "tail -100 /var/log/k3s-bootstrap.log"

clean: ## 로컬 캐시 및 임시 파일 정리
	rm -rf .terraform/
	rm -f .terraform.lock.hcl
	rm -f terraform.tfstate.backup
	@echo "정리 완료. terraform.tfstate는 보존됨."

full-deploy: apply kubeconfig status urls ## 전체 배포 (apply + kubeconfig + status)
	@echo ""
	@echo "배포 완료!"
