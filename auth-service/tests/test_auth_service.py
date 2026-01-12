"""
auth-service 단위 테스트

테스트 대상:
- AuthService.login(): JWT 토큰 발급
- AuthService.verify_token(): 토큰 검증 (만료, 서명)
- AuthService._verify_user_from_service(): User-service 통신
"""
import os
import sys
import jwt
import pytest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch, AsyncMock, MagicMock
from aioresponses import aioresponses
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


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


# 테스트용 키 쌍 생성
TEST_PRIVATE_KEY, TEST_PUBLIC_KEY = generate_test_rsa_keys()

# 환경변수 설정 (import 전에 설정해야 함)
os.environ['JWT_PRIVATE_KEY'] = TEST_PRIVATE_KEY
os.environ['JWT_PUBLIC_KEY'] = TEST_PUBLIC_KEY
os.environ['INTERNAL_API_SECRET'] = 'test-internal-secret'
os.environ['USER_SERVICE_URL'] = 'http://test-user-service:8001'

# 프로젝트 루트 경로 추가
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from auth_service import AuthService


# Fixtures
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


class TestAuthServiceLogin:
    """AuthService.login() 테스트"""

    @pytest.fixture
    def auth_service(self):
        """AuthService 인스턴스 생성"""
        return AuthService()

    @pytest.mark.asyncio
    async def test_login_success(self, auth_service, sample_user_data, sample_credentials):
        """정상 로그인 시 JWT 토큰 발급 테스트"""
        with aioresponses() as mocked:
            # User-service 응답 mock
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                payload=sample_user_data
            )

            result = await auth_service.login(
                sample_credentials['username'],
                sample_credentials['password']
            )

            assert result['status'] == 'success'
            assert 'token' in result

            # JWT 토큰 디코딩 검증
            decoded = jwt.decode(
                result['token'],
                auth_service._public_key,
                algorithms=['RS256'],
                issuer='auth-service'
            )
            assert decoded['username'] == sample_credentials['username']
            assert decoded['user_id'] == sample_user_data['id']
            assert decoded['iss'] == 'auth-service'

    @pytest.mark.asyncio
    async def test_login_invalid_credentials(self, auth_service, sample_credentials):
        """잘못된 자격증명 시 실패 응답 테스트"""
        with aioresponses() as mocked:
            # User-service에서 인증 실패 응답
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                status=401
            )

            result = await auth_service.login(
                sample_credentials['username'],
                'WrongPassword123!'
            )

            assert result['status'] == 'failed'
            assert 'Invalid username or password' in result['message']

    @pytest.mark.asyncio
    async def test_login_user_service_unavailable(self, auth_service, sample_credentials):
        """User-service 불가용 시 실패 처리 테스트"""
        import aiohttp

        with aioresponses() as mocked:
            # User-service 연결 실패 시뮬레이션 (aiohttp.ClientError 사용)
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                exception=aiohttp.ClientError('Connection refused')
            )

            result = await auth_service.login(
                sample_credentials['username'],
                sample_credentials['password']
            )

            assert result['status'] == 'failed'
            assert 'Invalid username or password' in result['message']

    @pytest.mark.asyncio
    async def test_login_jwt_token_structure(self, auth_service, sample_user_data, sample_credentials):
        """발급된 JWT 토큰 구조 검증"""
        with aioresponses() as mocked:
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                payload=sample_user_data
            )

            result = await auth_service.login(
                sample_credentials['username'],
                sample_credentials['password']
            )

            token = result['token']
            decoded = jwt.decode(
                token,
                auth_service._public_key,
                algorithms=['RS256'],
                issuer='auth-service'
            )

            # JWT 필수 클레임 확인
            assert 'user_id' in decoded
            assert 'username' in decoded
            assert 'exp' in decoded
            assert 'iat' in decoded
            assert 'jti' in decoded
            assert 'iss' in decoded

            # 만료 시간 검증 (24시간)
            exp_time = datetime.fromtimestamp(decoded['exp'], tz=timezone.utc)
            iat_time = datetime.fromtimestamp(decoded['iat'], tz=timezone.utc)
            assert (exp_time - iat_time) == timedelta(hours=24)


class TestAuthServiceVerifyToken:
    """AuthService.verify_token() 테스트"""

    @pytest.fixture
    def auth_service(self):
        """AuthService 인스턴스 생성"""
        return AuthService()

    def test_verify_token_success(self, auth_service, sample_user_data):
        """유효한 토큰 검증 성공 테스트"""
        # 유효한 토큰 생성
        now = datetime.now(timezone.utc)
        payload = {
            'user_id': sample_user_data['id'],
            'username': sample_user_data['username'],
            'exp': now + timedelta(hours=24),
            'iat': now,
            'jti': 'test-jti-123',
            'iss': 'auth-service'
        }
        token = jwt.encode(payload, auth_service._private_key, algorithm='RS256')

        result = auth_service.verify_token(token)

        assert result['status'] == 'success'
        assert result['data']['user_id'] == sample_user_data['id']
        assert result['data']['username'] == sample_user_data['username']

    def test_verify_token_expired(self, auth_service, sample_user_data):
        """만료된 토큰 검증 실패 테스트"""
        # 이미 만료된 토큰 생성
        now = datetime.now(timezone.utc)
        payload = {
            'user_id': sample_user_data['id'],
            'username': sample_user_data['username'],
            'exp': now - timedelta(hours=1),  # 1시간 전 만료
            'iat': now - timedelta(hours=25),
            'jti': 'test-jti-expired',
            'iss': 'auth-service'
        }
        token = jwt.encode(payload, auth_service._private_key, algorithm='RS256')

        result = auth_service.verify_token(token)

        assert result['status'] == 'failed'
        assert 'Token has expired' in result['message']

    def test_verify_token_invalid_signature(self, auth_service, sample_user_data):
        """위조된 토큰 (잘못된 서명) 검증 실패 테스트"""
        # 다른 키로 서명된 토큰 생성
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives import serialization

        # 다른 키 쌍 생성
        other_private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )

        now = datetime.now(timezone.utc)
        payload = {
            'user_id': sample_user_data['id'],
            'username': sample_user_data['username'],
            'exp': now + timedelta(hours=24),
            'iat': now,
            'jti': 'test-jti-forged',
            'iss': 'auth-service'
        }

        # 다른 키로 서명
        token = jwt.encode(payload, other_private_key, algorithm='RS256')

        result = auth_service.verify_token(token)

        assert result['status'] == 'failed'
        assert 'Invalid token' in result['message']

    def test_verify_token_invalid_issuer(self, auth_service, sample_user_data):
        """잘못된 issuer 토큰 검증 실패 테스트"""
        now = datetime.now(timezone.utc)
        payload = {
            'user_id': sample_user_data['id'],
            'username': sample_user_data['username'],
            'exp': now + timedelta(hours=24),
            'iat': now,
            'jti': 'test-jti-wrong-issuer',
            'iss': 'wrong-issuer'  # 잘못된 issuer
        }
        token = jwt.encode(payload, auth_service._private_key, algorithm='RS256')

        result = auth_service.verify_token(token)

        assert result['status'] == 'failed'
        assert 'Invalid token' in result['message']

    def test_verify_token_malformed(self, auth_service):
        """잘못된 형식의 토큰 검증 실패 테스트"""
        malformed_tokens = [
            'not-a-valid-jwt',
            'eyJhbGciOiJSUzI1NiJ9.invalid.payload',
            '',
            'a.b.c.d.e',
        ]

        for token in malformed_tokens:
            result = auth_service.verify_token(token)
            assert result['status'] == 'failed'
            assert 'Invalid token' in result['message']


class TestAuthServiceVerifyUserFromService:
    """AuthService._verify_user_from_service() 테스트"""

    @pytest.fixture
    def auth_service(self):
        """AuthService 인스턴스 생성"""
        return AuthService()

    @pytest.mark.asyncio
    async def test_verify_user_success(self, auth_service, sample_user_data):
        """User-service 정상 응답 테스트"""
        with aioresponses() as mocked:
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                payload=sample_user_data
            )

            result = await auth_service._verify_user_from_service(
                'testuser',
                'TestPassword123!'
            )

            assert result is not None
            assert result['id'] == sample_user_data['id']
            assert result['username'] == sample_user_data['username']

    @pytest.mark.asyncio
    async def test_verify_user_not_found(self, auth_service):
        """User-service에서 사용자를 찾지 못한 경우 테스트"""
        with aioresponses() as mocked:
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                status=404
            )

            result = await auth_service._verify_user_from_service(
                'nonexistent',
                'password'
            )

            assert result is None

    @pytest.mark.asyncio
    async def test_verify_user_wrong_password(self, auth_service):
        """User-service에서 비밀번호 불일치 응답 테스트"""
        with aioresponses() as mocked:
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                status=401
            )

            result = await auth_service._verify_user_from_service(
                'testuser',
                'wrongpassword'
            )

            assert result is None

    @pytest.mark.asyncio
    async def test_verify_user_service_timeout(self, auth_service):
        """User-service 타임아웃 처리 테스트"""
        import aiohttp

        with aioresponses() as mocked:
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                exception=aiohttp.ClientError('Connection timeout')
            )

            result = await auth_service._verify_user_from_service(
                'testuser',
                'password'
            )

            assert result is None

    @pytest.mark.asyncio
    async def test_verify_user_service_500_error(self, auth_service):
        """User-service 내부 서버 오류 처리 테스트"""
        with aioresponses() as mocked:
            mocked.post(
                'http://test-user-service:8001/users/verify-credentials',
                status=500
            )

            result = await auth_service._verify_user_from_service(
                'testuser',
                'password'
            )

            assert result is None


class TestAuthServiceSession:
    """AuthService 세션 관리 테스트"""

    @pytest.mark.asyncio
    async def test_get_session_singleton(self):
        """세션 싱글톤 패턴 테스트"""
        # 세션 초기화
        AuthService._session = None

        session1 = await AuthService.get_session()
        session2 = await AuthService.get_session()

        assert session1 is session2

        # 테스트 후 세션 정리
        await AuthService.close_session()

    @pytest.mark.asyncio
    async def test_close_session(self):
        """세션 종료 테스트"""
        # 세션 초기화
        AuthService._session = None

        session = await AuthService.get_session()
        assert session is not None
        assert not session.closed

        await AuthService.close_session()

        # close 후에도 _session이 존재하지만 closed 상태
        # 새로운 세션 요청 시 새로운 세션 생성
        new_session = await AuthService.get_session()
        assert new_session is not session or not new_session.closed

        # 테스트 후 정리
        await AuthService.close_session()
