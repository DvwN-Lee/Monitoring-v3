"""
user-service user_service.py 단위 테스트

테스트 대상:
- UserIn: 입력 검증 (username, password)
- 예약어 필터링 (RESERVED_USERNAMES)
- 비밀번호 복잡도 검증
"""
import os
import sys
import pytest
from pydantic import ValidationError

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from user_service import UserIn, RESERVED_USERNAMES


class TestUserInUsernameValidation:
    """UserIn.username 검증 테스트"""

    def test_valid_username(self):
        """유효한 사용자명 테스트"""
        valid_usernames = [
            'testuser',
            'test_user',
            'TestUser123',
            'user_123_test',
            'abc',  # 최소 3자
        ]

        for username in valid_usernames:
            user = UserIn(
                username=username,
                email='test@example.com',
                password='ValidPassword123!'
            )
            assert user.username == username

    def test_invalid_username_too_short(self):
        """너무 짧은 사용자명 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='ab',  # 2자 (최소 3자 필요)
                email='test@example.com',
                password='ValidPassword123!'
            )
        assert 'username' in str(exc_info.value).lower()

    def test_invalid_username_too_long(self):
        """너무 긴 사용자명 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='a' * 51,  # 51자 (최대 50자)
                email='test@example.com',
                password='ValidPassword123!'
            )
        assert 'username' in str(exc_info.value).lower()

    def test_invalid_username_special_chars(self):
        """특수문자 포함 사용자명 거부 테스트"""
        invalid_usernames = [
            'test-user',  # 하이픈
            'test.user',  # 점
            'test@user',  # @
            'test user',  # 공백
            'test!user',  # 느낌표
        ]

        for username in invalid_usernames:
            with pytest.raises(ValidationError) as exc_info:
                UserIn(
                    username=username,
                    email='test@example.com',
                    password='ValidPassword123!'
                )
            assert 'alphanumeric' in str(exc_info.value).lower()

    def test_reserved_usernames_blocked(self):
        """예약어 사용자명 차단 테스트"""
        for reserved in RESERVED_USERNAMES:
            with pytest.raises(ValidationError) as exc_info:
                UserIn(
                    username=reserved,
                    email='test@example.com',
                    password='ValidPassword123!'
                )
            assert 'reserved' in str(exc_info.value).lower()

    def test_reserved_usernames_case_insensitive(self):
        """예약어 대소문자 무관 차단 테스트"""
        # 대문자, 혼합 케이스 모두 차단
        variations = ['ADMIN', 'Admin', 'aDmIn', 'ROOT', 'Root']

        for username in variations:
            with pytest.raises(ValidationError) as exc_info:
                UserIn(
                    username=username,
                    email='test@example.com',
                    password='ValidPassword123!'
                )
            assert 'reserved' in str(exc_info.value).lower()


class TestUserInPasswordValidation:
    """UserIn.password 검증 테스트"""

    def test_valid_password(self):
        """유효한 비밀번호 테스트"""
        valid_passwords = [
            'Password1!',
            'MyP@ssw0rd',
            'Test123!@#',
            'Abcd1234!',
            'Complex_Password_123!',
        ]

        for password in valid_passwords:
            user = UserIn(
                username='testuser',
                email='test@example.com',
                password=password
            )
            assert user.password == password

    def test_invalid_password_too_short(self):
        """너무 짧은 비밀번호 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='testuser',
                email='test@example.com',
                password='Pass1!'  # 6자 (최소 8자 필요)
            )
        assert 'password' in str(exc_info.value).lower()

    def test_invalid_password_no_uppercase(self):
        """대문자 없는 비밀번호 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='testuser',
                email='test@example.com',
                password='password123!'  # 대문자 없음
            )
        assert 'uppercase' in str(exc_info.value).lower()

    def test_invalid_password_no_lowercase(self):
        """소문자 없는 비밀번호 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='testuser',
                email='test@example.com',
                password='PASSWORD123!'  # 소문자 없음
            )
        assert 'lowercase' in str(exc_info.value).lower()

    def test_invalid_password_no_digit(self):
        """숫자 없는 비밀번호 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='testuser',
                email='test@example.com',
                password='Password!'  # 숫자 없음
            )
        assert 'digit' in str(exc_info.value).lower()

    def test_invalid_password_no_special_char(self):
        """특수문자 없는 비밀번호 거부 테스트"""
        with pytest.raises(ValidationError) as exc_info:
            UserIn(
                username='testuser',
                email='test@example.com',
                password='Password123'  # 특수문자 없음
            )
        assert 'special' in str(exc_info.value).lower()


class TestUserInEmailValidation:
    """UserIn.email 검증 테스트"""

    def test_valid_email(self):
        """유효한 이메일 테스트"""
        valid_emails = [
            'test@example.com',
            'user.name@domain.co.kr',
            'user+tag@example.org',
        ]

        for email in valid_emails:
            user = UserIn(
                username='testuser',
                email=email,
                password='ValidPassword123!'
            )
            assert user.email == email

    def test_invalid_email_format(self):
        """잘못된 이메일 형식 거부 테스트"""
        invalid_emails = [
            'not-an-email',
            '@example.com',
            'user@',
            'user@.com',
        ]

        for email in invalid_emails:
            with pytest.raises(ValidationError):
                UserIn(
                    username='testuser',
                    email=email,
                    password='ValidPassword123!'
                )


class TestReservedUsernames:
    """RESERVED_USERNAMES 검증 테스트"""

    def test_reserved_usernames_completeness(self):
        """예약어 목록 완전성 테스트"""
        expected_reserved = {
            'admin', 'root', 'system', 'api', 'auth',
            'user', 'blog', 'www', 'mail', 'ftp', 'localhost'
        }

        assert RESERVED_USERNAMES == expected_reserved

    def test_reserved_usernames_not_empty(self):
        """예약어 목록 비어있지 않음 테스트"""
        assert len(RESERVED_USERNAMES) > 0

    def test_all_reserved_are_lowercase(self):
        """모든 예약어가 소문자인지 테스트"""
        for reserved in RESERVED_USERNAMES:
            assert reserved == reserved.lower()
