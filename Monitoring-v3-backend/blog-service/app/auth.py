# blog-service/app/auth.py
import aiohttp
import logging
from typing import Optional
from fastapi import Request, HTTPException
from app.config import AUTH_SERVICE_URL

logger = logging.getLogger(__name__)


class AuthClient:
    _session: Optional[aiohttp.ClientSession] = None

    @classmethod
    async def get_session(cls) -> aiohttp.ClientSession:
        """Get or create singleton aiohttp ClientSession."""
        if cls._session is None or cls._session.closed:
            cls._session = aiohttp.ClientSession()
            logger.info("Created new aiohttp ClientSession for auth verification")
        return cls._session

    @classmethod
    async def close(cls):
        """Close the singleton aiohttp ClientSession."""
        if cls._session and not cls._session.closed:
            await cls._session.close()
            logger.info("Closed aiohttp ClientSession for auth verification")


async def require_user(request: Request) -> str:
    """Verify user authentication via auth-service."""
    auth_header = request.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        raise HTTPException(status_code=401, detail='Authorization header missing or invalid')
    token = auth_header.split(' ')[1]

    verify_url = f"{AUTH_SERVICE_URL}/verify"
    try:
        session = await AuthClient.get_session()
        async with session.get(verify_url, headers={'Authorization': f'Bearer {token}'}) as resp:
            data = await resp.json()
            if resp.status != 200 or data.get('status') != 'success':
                raise HTTPException(status_code=401, detail='Invalid or expired token')
            username = data.get('data', {}).get('username')
            if not username:
                raise HTTPException(status_code=401, detail='Invalid token payload')
            return username
    except aiohttp.ClientError:
        raise HTTPException(status_code=502, detail='Auth service not reachable')
