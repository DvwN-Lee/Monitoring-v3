#!/bin/bash
# 필요한 개발 도구 자동 설치 스크립트

# OS 감지
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Linux 배포판 감지
detect_linux_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# Homebrew 설치 (macOS)
install_homebrew() {
    if ! command -v brew &> /dev/null; then
        echo "📦 Homebrew가 설치되어 있지 않습니다. Homebrew를 설치합니다..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Apple Silicon Mac의 경우 PATH 설정
        if [ -f /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
    fi
}

# kubectl 설치
install_kubectl() {
    echo "📦 kubectl 설치 중..."

    local os=$(detect_os)

    case $os in
        macos)
            install_homebrew
            brew install kubectl
            ;;
        linux)
            local distro=$(detect_linux_distro)
            case $distro in
                ubuntu|debian)
                    sudo apt-get update
                    sudo apt-get install -y apt-transport-https ca-certificates curl
                    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
                    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
                    sudo apt-get update
                    sudo apt-get install -y kubectl
                    ;;
                rhel|centos|fedora)
                    cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
EOF
                    sudo yum install -y kubectl
                    ;;
                *)
                    echo "❌ 지원하지 않는 Linux 배포판입니다."
                    echo "   수동으로 kubectl을 설치해주세요: https://kubernetes.io/docs/tasks/tools/"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "❌ 지원하지 않는 운영체제입니다."
            return 1
            ;;
    esac

    echo "✅ kubectl 설치 완료"
}

# terraform 설치
install_terraform() {
    echo "📦 Terraform 설치 중..."

    local os=$(detect_os)

    case $os in
        macos)
            install_homebrew
            brew tap hashicorp/tap
            brew install hashicorp/tap/terraform
            ;;
        linux)
            local distro=$(detect_linux_distro)
            case $distro in
                ubuntu|debian)
                    sudo apt-get update
                    sudo apt-get install -y gnupg software-properties-common curl
                    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
                    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
                    sudo apt-get update
                    sudo apt-get install -y terraform
                    ;;
                rhel|centos|fedora)
                    sudo yum install -y yum-utils
                    sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
                    sudo yum install -y terraform
                    ;;
                *)
                    echo "❌ 지원하지 않는 Linux 배포판입니다."
                    echo "   수동으로 Terraform을 설치해주세요: https://developer.hashicorp.com/terraform/install"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "❌ 지원하지 않는 운영체제입니다."
            return 1
            ;;
    esac

    echo "✅ Terraform 설치 완료"
}

# skaffold 설치
install_skaffold() {
    echo "📦 Skaffold 설치 중..."

    local os=$(detect_os)

    case $os in
        macos)
            install_homebrew
            brew install skaffold
            ;;
        linux)
            curl -Lo skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64
            sudo install skaffold /usr/local/bin/
            rm skaffold
            ;;
        *)
            echo "❌ 지원하지 않는 운영체제입니다."
            return 1
            ;;
    esac

    echo "✅ Skaffold 설치 완료"
}

# minikube 설치
install_minikube() {
    echo "📦 Minikube 설치 중..."

    local os=$(detect_os)

    case $os in
        macos)
            install_homebrew
            brew install minikube
            ;;
        linux)
            curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
            sudo install minikube-linux-amd64 /usr/local/bin/minikube
            rm minikube-linux-amd64
            ;;
        *)
            echo "❌ 지원하지 않는 운영체제입니다."
            return 1
            ;;
    esac

    echo "✅ Minikube 설치 완료"
}

# 도구 확인 및 설치
ensure_tool_installed() {
    local tool=$1
    local install_func=$2

    if ! command -v "$tool" &> /dev/null; then
        echo "⚠️  $tool이(가) 설치되어 있지 않습니다."
        read -p "지금 설치하시겠습니까? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            $install_func
            if ! command -v "$tool" &> /dev/null; then
                echo "❌ $tool 설치에 실패했습니다."
                return 1
            fi
        else
            echo "❌ $tool이(가) 필요합니다. 수동으로 설치해주세요."
            return 1
        fi
    else
        echo "✅ $tool이(가) 이미 설치되어 있습니다."
    fi
    return 0
}

# 여러 도구 확인
check_and_install_tools() {
    local tools=("$@")
    local all_installed=true

    for tool in "${tools[@]}"; do
        case $tool in
            kubectl)
                ensure_tool_installed "kubectl" "install_kubectl" || all_installed=false
                ;;
            terraform)
                ensure_tool_installed "terraform" "install_terraform" || all_installed=false
                ;;
            skaffold)
                ensure_tool_installed "skaffold" "install_skaffold" || all_installed=false
                ;;
            minikube)
                ensure_tool_installed "minikube" "install_minikube" || all_installed=false
                ;;
            *)
                echo "⚠️  알 수 없는 도구: $tool"
                all_installed=false
                ;;
        esac
    done

    if [ "$all_installed" = false ]; then
        echo ""
        echo "❌ 일부 도구 설치에 실패했습니다."
        return 1
    fi

    echo ""
    echo "✅ 모든 필요한 도구가 설치되었습니다!"
    return 0
}
