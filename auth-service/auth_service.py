import jwt
import uuid
import aiohttp
import logging
from typing import Optional
from datetime import datetime, timedelta, timezone
from cryptography.hazmat.primitives import serialization
from config import config

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class AuthService:
    _session: Optional[aiohttp.ClientSession] = None

    def __init__(self):
        self.JWT_ALGORITHM = "RS256"
        self.JWT_EXP_DELTA_SECONDS = timedelta(hours=24)
        self.USER_SERVICE_VERIFY_URL = f"{config.USER_SERVICE_URL}/users/verify-credentials"

        # RS256 Key Pair 로드
        self._private_key = serialization.load_pem_private_key(
            config.JWT_PRIVATE_KEY.encode(),
            password=None
        )
        self._public_key = serialization.load_pem_public_key(
            config.JWT_PUBLIC_KEY.encode()
        )

        logger.info("Auth service initialized with RS256 JWT authentication.")

    @classmethod
    async def get_session(cls) -> aiohttp.ClientSession:
        """Get or create singleton aiohttp ClientSession."""
        if cls._session is None or cls._session.closed:
            cls._session = aiohttp.ClientSession()
            logger.info("Created new aiohttp ClientSession")
        return cls._session

    @classmethod
    async def close_session(cls):
        """Close the singleton aiohttp ClientSession."""
        if cls._session and not cls._session.closed:
            await cls._session.close()
            logger.info("Closed aiohttp ClientSession")

    async def _verify_user_from_service(self, username, password):
        """User-service에 자격 증명 확인을 요청하는 로직"""
        payload = {"username": username, "password": password}
        try:
            session = await self.get_session()
            async with session.post(self.USER_SERVICE_VERIFY_URL, json=payload) as response:
                if response.status == 200:
                    return await response.json()
                return None
        except aiohttp.ClientError as e:
            logger.error(f"Error connecting to user-service: {e}")
            return None

    async def login(self, username, password):
        """사용자 로그인 및 JWT 토큰 발급"""
        # 헬퍼 함수를 통해 자격 증명 확인
        user_data = await self._verify_user_from_service(username, password)

        if not user_data:
            logger.warning(f"Login failed for '{username}': Invalid credentials or service error.")
            return {"status": "failed", "message": "Invalid username or password"}

        user_id = user_data.get("id")
        now = datetime.now(timezone.utc)
        jwt_payload = {
            'user_id': user_id,
            'username': username,
            'exp': now + self.JWT_EXP_DELTA_SECONDS,
            'iat': now,
            'jti': str(uuid.uuid4()),
            'iss': 'auth-service'
        }
        token = jwt.encode(jwt_payload, self._private_key, algorithm=self.JWT_ALGORITHM)

        logger.info(f"Login successful for '{username}'. JWT token created.")
        return {"status": "success", "token": token}

    def verify_token(self, token):
        try:
            decoded_payload = jwt.decode(
                token,
                self._public_key,
                algorithms=[self.JWT_ALGORITHM],
                issuer='auth-service'
            )
            logger.info(f"Token verified successfully for user_id: {decoded_payload.get('user_id')}")
            return {"status": "success", "data": decoded_payload}
        except jwt.ExpiredSignatureError:
            logger.warning("Token verification failed: Token has expired.")
            return {"status": "failed", "message": "Token has expired"}
        except jwt.InvalidTokenError as e:
            logger.error(f"Token verification failed: Invalid token. Reason: {e}")
            return {"status": "failed", "message": "Invalid token"}