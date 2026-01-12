"""
user-service 단위 테스트를 위한 pytest fixtures
"""
import os
import sys
import pytest
import tempfile

# 프로젝트 루트를 path에 추가
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(scope="session", autouse=True)
def setup_test_environment():
    """테스트 환경 설정 (SQLite 사용)"""
    # SQLite 사용 설정 (PostgreSQL mock 불필요)
    os.environ['USE_POSTGRES'] = 'false'
    os.environ['ALLOWED_ORIGINS'] = 'http://localhost:3000'
    yield


@pytest.fixture
def temp_db_path():
    """테스트용 임시 SQLite 데이터베이스 경로"""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, 'test_users.db')
        os.environ['DATABASE_PATH'] = db_path
        yield db_path


@pytest.fixture
def sample_user():
    """테스트용 사용자 데이터"""
    return {
        'username': 'testuser123',
        'email': 'test@example.com',
        'password': 'TestPassword123!',
    }


@pytest.fixture
def sample_users():
    """테스트용 다중 사용자 데이터"""
    return [
        {'username': 'user1', 'email': 'user1@example.com', 'password': 'Password1!'},
        {'username': 'user2', 'email': 'user2@example.com', 'password': 'Password2!'},
        {'username': 'user3', 'email': 'user3@example.com', 'password': 'Password3!'},
    ]
