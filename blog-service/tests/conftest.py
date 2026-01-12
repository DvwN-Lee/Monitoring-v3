"""
blog-service 단위 테스트를 위한 pytest fixtures
"""
import os
import sys
import pytest
import tempfile

# 프로젝트 루트를 path에 추가
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture(scope="session", autouse=True)
def setup_test_environment():
    """테스트 환경 설정"""
    os.environ['USE_POSTGRES'] = 'false'
    os.environ['ALLOWED_ORIGINS'] = 'http://localhost:3000'
    os.environ['AUTH_SERVICE_URL'] = 'http://test-auth-service:8002'
    yield


@pytest.fixture
def temp_db_path():
    """테스트용 임시 SQLite 데이터베이스 경로"""
    with tempfile.TemporaryDirectory() as tmpdir:
        db_path = os.path.join(tmpdir, 'test_blog.db')
        os.environ['DATABASE_PATH'] = db_path
        yield db_path


@pytest.fixture
def sample_post():
    """테스트용 게시물 데이터"""
    return {
        'title': 'Test Post Title',
        'content': 'This is the content of the test post.',
        'category': 'general',
        'author_id': 1,
        'author_name': 'testuser',
    }


@pytest.fixture
def sample_posts():
    """테스트용 다중 게시물 데이터"""
    return [
        {'title': 'Post 1', 'content': 'Content 1', 'category': 'tech', 'author_id': 1, 'author_name': 'user1'},
        {'title': 'Post 2', 'content': 'Content 2', 'category': 'life', 'author_id': 2, 'author_name': 'user2'},
        {'title': 'Post 3', 'content': 'Content 3', 'category': 'tech', 'author_id': 1, 'author_name': 'user1'},
    ]


@pytest.fixture
def xss_payloads():
    """XSS 공격 테스트용 페이로드"""
    return [
        '<script>alert("XSS")</script>',
        '<img src=x onerror=alert("XSS")>',
        '<svg onload=alert("XSS")>',
        '<body onload=alert("XSS")>',
        '<iframe src="javascript:alert(\'XSS\')">',
        '<a href="javascript:alert(\'XSS\')">Click me</a>',
        '<div onclick="alert(\'XSS\')">Click</div>',
        '"><script>alert("XSS")</script>',
        '\';alert(String.fromCharCode(88,83,83))//\'',
    ]
