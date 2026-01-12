"""
auth-service 단위 테스트를 위한 pytest fixtures
"""
import os
import sys
import pytest
from unittest.mock import patch, MagicMock
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

# 프로젝트 루트를 path에 추가
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def generate_test_rsa_keys():
    """테스트용 RSA 키 쌍 생성"""
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )
    public_key = private_key.public_key()

    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    ).decode('utf-8')

    public_pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode('utf-8')

    return private_pem, public_pem


# 테스트용 키 쌍 (모듈 레벨에서 한 번만 생성)
TEST_PRIVATE_KEY, TEST_PUBLIC_KEY = generate_test_rsa_keys()


@pytest.fixture(scope="session", autouse=True)
def setup_test_environment():
    """테스트 환경 설정 (환경변수 mock)"""
    env_vars = {
        'JWT_PRIVATE_KEY': TEST_PRIVATE_KEY,
        'JWT_PUBLIC_KEY': TEST_PUBLIC_KEY,
        'INTERNAL_API_SECRET': 'test-internal-secret',
        'USER_SERVICE_URL': 'http://test-user-service:8001',
    }

    with patch.dict(os.environ, env_vars):
        yield


@pytest.fixture
def test_keys():
    """테스트용 RSA 키 쌍 반환"""
    return {
        'private_key': TEST_PRIVATE_KEY,
        'public_key': TEST_PUBLIC_KEY,
    }


@pytest.fixture
def mock_config():
    """테스트용 Config mock 객체"""
    config_mock = MagicMock()
    config_mock.JWT_PRIVATE_KEY = TEST_PRIVATE_KEY
    config_mock.JWT_PUBLIC_KEY = TEST_PUBLIC_KEY
    config_mock.USER_SERVICE_URL = 'http://test-user-service:8001'
    config_mock.INTERNAL_API_SECRET = 'test-internal-secret'
    return config_mock


@pytest.fixture
def sample_user_data():
    """테스트용 사용자 데이터"""
    return {
        'id': 1,
        'username': 'testuser',
        'email': 'test@example.com',
    }


@pytest.fixture
def sample_credentials():
    """테스트용 자격증명"""
    return {
        'username': 'testuser',
        'password': 'TestPassword123!',
    }
