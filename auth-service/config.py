import os
from dataclasses import dataclass, field

@dataclass
class ServerConfig:
    """Auth Service 서버 실행 설정"""
    host: str = '0.0.0.0'
    port: int = 8002 # 다른 서비스와 겹치지 않는 포트

@dataclass
class AuthConfig:
    """인증 관련 설정"""
    session_timeout: int = 86400  # 세션 유효 시간 (24시간)
    internal_api_secret: str = field(default_factory=lambda: os.getenv('INTERNAL_API_SECRET', ''))
    jwt_private_key: str = field(default_factory=lambda: os.getenv('JWT_PRIVATE_KEY', ''))
    jwt_public_key: str = field(default_factory=lambda: os.getenv('JWT_PUBLIC_KEY', ''))

    def __post_init__(self):
        if not self.internal_api_secret:
            raise ValueError(
                "INTERNAL_API_SECRET environment variable is required. "
                "Please set it in Kubernetes Secret or environment variables."
            )
        if not self.jwt_private_key or not self.jwt_public_key:
            raise ValueError(
                "JWT_PRIVATE_KEY and JWT_PUBLIC_KEY environment variables are required for RS256. "
                "Please set them in Kubernetes Secret or environment variables."
            )

@dataclass
class ServiceUrls:
    """호출할 다른 Microservice의 주소"""
    # k8s-configmap.yml에 정의된 환경 변수 값을 읽어옵니다.
    user_service: str = os.getenv('USER_SERVICE_URL', 'http://user-service:8001')

class Config:
    def __init__(self):
        self.server = ServerConfig()
        self.auth = AuthConfig()
        self.services = ServiceUrls()
        self.INTERNAL_API_SECRET = self.auth.internal_api_secret
        self.JWT_PRIVATE_KEY = self.auth.jwt_private_key
        self.JWT_PUBLIC_KEY = self.auth.jwt_public_key
        self.USER_SERVICE_URL = self.services.user_service


# 다른 파일에서 쉽게 임포트할 수 있도록 전역 인스턴스 생성
config = Config()
