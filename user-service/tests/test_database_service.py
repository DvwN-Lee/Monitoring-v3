"""
user-service database_service.py 단위 테스트

테스트 대상:
- UserServiceDatabase.add_user(): 사용자 등록
- UserServiceDatabase.get_user_by_username(): 사용자 조회
- UserServiceDatabase.verify_user_credentials(): 자격증명 검증 (Argon2, PBKDF2)
- UserServiceDatabase._update_password_hash(): 해시 업데이트
"""
import os
import sys
import pytest
from argon2 import PasswordHasher
from werkzeug.security import generate_password_hash

# conftest에서 환경변수 설정됨
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from database_service import UserServiceDatabase, ph


class TestUserServiceDatabaseAddUser:
    """UserServiceDatabase.add_user() 테스트"""

    @pytest.mark.asyncio
    async def test_add_user_success(self, temp_db_path, sample_user):
        """정상 사용자 등록 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        user_id = await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        assert user_id is not None
        assert isinstance(user_id, int)
        assert user_id > 0

    @pytest.mark.asyncio
    async def test_add_user_duplicate_username(self, temp_db_path, sample_user):
        """중복 사용자명 거부 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        # 첫 번째 등록
        first_id = await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )
        assert first_id is not None

        # 동일 사용자명으로 두 번째 등록 시도
        second_id = await db.add_user(
            sample_user['username'],
            'different@example.com',
            'DifferentPassword123!'
        )
        assert second_id is None

    @pytest.mark.asyncio
    async def test_add_user_password_hashed(self, temp_db_path, sample_user):
        """비밀번호가 Argon2로 해시되는지 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        # DB에서 직접 조회하여 해시 확인
        user = await db.get_user_by_username(sample_user['username'])
        assert user is not None
        assert user['password_hash'].startswith('$argon2')
        assert user['password_hash'] != sample_user['password']


class TestUserServiceDatabaseGetUser:
    """UserServiceDatabase.get_user_by_* 테스트"""

    @pytest.mark.asyncio
    async def test_get_user_by_username_exists(self, temp_db_path, sample_user):
        """존재하는 사용자 조회 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        user_id = await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        user = await db.get_user_by_username(sample_user['username'])

        assert user is not None
        assert user['id'] == user_id
        assert user['username'] == sample_user['username']
        assert user['email'] == sample_user['email']

    @pytest.mark.asyncio
    async def test_get_user_by_username_not_exists(self, temp_db_path):
        """존재하지 않는 사용자 조회 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        user = await db.get_user_by_username('nonexistent_user')

        assert user is None

    @pytest.mark.asyncio
    async def test_get_user_by_id_exists(self, temp_db_path, sample_user):
        """ID로 사용자 조회 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        user_id = await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        user = await db.get_user_by_id(user_id)

        assert user is not None
        assert user['id'] == user_id
        assert user['username'] == sample_user['username']

    @pytest.mark.asyncio
    async def test_get_user_by_id_not_exists(self, temp_db_path):
        """존재하지 않는 ID로 조회 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        user = await db.get_user_by_id(99999)

        assert user is None


class TestUserServiceDatabaseVerifyCredentials:
    """UserServiceDatabase.verify_user_credentials() 테스트"""

    @pytest.mark.asyncio
    async def test_verify_credentials_argon2_success(self, temp_db_path, sample_user):
        """Argon2 비밀번호 검증 성공 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        result = await db.verify_user_credentials(
            sample_user['username'],
            sample_user['password']
        )

        assert result is not None
        assert result['username'] == sample_user['username']
        assert result['email'] == sample_user['email']
        assert 'password_hash' not in result  # 비밀번호 해시는 반환하지 않음

    @pytest.mark.asyncio
    async def test_verify_credentials_wrong_password(self, temp_db_path, sample_user):
        """잘못된 비밀번호 검증 실패 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        result = await db.verify_user_credentials(
            sample_user['username'],
            'WrongPassword123!'
        )

        assert result is None

    @pytest.mark.asyncio
    async def test_verify_credentials_nonexistent_user(self, temp_db_path):
        """존재하지 않는 사용자 검증 실패 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        result = await db.verify_user_credentials(
            'nonexistent',
            'password'
        )

        assert result is None

    @pytest.mark.asyncio
    async def test_verify_credentials_pbkdf2_legacy_migration(self, temp_db_path, sample_user):
        """PBKDF2 Legacy 해시 마이그레이션 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        # 먼저 사용자 추가 (Argon2)
        await db.add_user(
            sample_user['username'],
            sample_user['email'],
            sample_user['password']
        )

        # PBKDF2 해시로 직접 업데이트 (Legacy 시뮬레이션)
        pbkdf2_hash = generate_password_hash(sample_user['password'])

        import aiosqlite
        async with aiosqlite.connect(db.db_file) as conn:
            await conn.execute(
                "UPDATE users SET password_hash = ? WHERE username = ?",
                (pbkdf2_hash, sample_user['username'])
            )
            await conn.commit()

        # PBKDF2 해시로 로그인 시도 - 성공 후 Argon2로 마이그레이션되어야 함
        result = await db.verify_user_credentials(
            sample_user['username'],
            sample_user['password']
        )

        assert result is not None

        # 마이그레이션 확인: 해시가 Argon2로 변경되었는지 확인
        user = await db.get_user_by_username(sample_user['username'])
        assert user['password_hash'].startswith('$argon2')


class TestUserServiceDatabaseHealthCheck:
    """UserServiceDatabase.health_check() 테스트"""

    @pytest.mark.asyncio
    async def test_health_check_success(self, temp_db_path):
        """DB Health Check 성공 테스트"""
        db = UserServiceDatabase()
        await db.initialize()

        result = await db.health_check()

        assert result is True

    @pytest.mark.asyncio
    async def test_health_check_uninitialized(self, temp_db_path):
        """초기화되지 않은 DB Health Check 테스트"""
        # SQLite는 파일 기반이므로 초기화 없이도 health_check 가능
        db = UserServiceDatabase()
        # initialize() 호출하지 않음

        # SQLite의 경우 파일 접근 시도
        result = await db.health_check()
        # SQLite는 파일이 없어도 생성하므로 성공할 수 있음
        assert isinstance(result, bool)
