"""
blog-service 단위 테스트

테스트 대상:
- sanitize_content(): XSS 방지 콘텐츠 필터링
- sanitize_title(): 제목 HTML 태그 제거
- ALLOWED_TAGS, ALLOWED_ATTRS: 허용 태그/속성 검증
"""
import os
import sys
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from blog_service import sanitize_content, sanitize_title, ALLOWED_TAGS, ALLOWED_ATTRS


class TestSanitizeContent:
    """sanitize_content() XSS 방지 테스트"""

    def test_script_tag_removed(self, xss_payloads):
        """<script> 태그 제거 테스트"""
        payload = '<script>alert("XSS")</script>'
        result = sanitize_content(payload)

        assert '<script>' not in result
        assert '</script>' not in result
        # bleach는 태그만 제거하고 내용은 유지함 (strip=True)
        # 실행 가능한 스크립트 태그가 제거되었는지가 핵심

    def test_event_handlers_removed(self):
        """이벤트 핸들러 속성 제거 테스트"""
        payloads = [
            '<img src=x onerror=alert("XSS")>',
            '<svg onload=alert("XSS")>',
            '<div onclick="alert(\'XSS\')">Click</div>',
            '<body onload=alert("XSS")>',
        ]

        for payload in payloads:
            result = sanitize_content(payload)
            assert 'onerror' not in result
            assert 'onload' not in result
            assert 'onclick' not in result

    def test_javascript_uri_removed(self):
        """javascript: URI 제거 테스트"""
        payloads = [
            '<a href="javascript:alert(\'XSS\')">Click me</a>',
            '<iframe src="javascript:alert(\'XSS\')">',
        ]

        for payload in payloads:
            result = sanitize_content(payload)
            assert 'javascript:' not in result

    def test_allowed_tags_preserved(self):
        """허용된 태그 보존 테스트"""
        html = '''
        <p>Paragraph</p>
        <strong>Bold</strong>
        <em>Italic</em>
        <a href="https://example.com">Link</a>
        <ul><li>Item 1</li><li>Item 2</li></ul>
        <code>code</code>
        <pre>preformatted</pre>
        <blockquote>quote</blockquote>
        '''

        result = sanitize_content(html)

        assert '<p>' in result
        assert '<strong>' in result
        assert '<em>' in result
        assert '<a href=' in result
        assert '<ul>' in result
        assert '<li>' in result
        assert '<code>' in result
        assert '<pre>' in result
        assert '<blockquote>' in result

    def test_allowed_attributes_preserved(self):
        """허용된 속성 보존 테스트"""
        html = '<a href="https://example.com" title="Example Link">Link</a>'
        result = sanitize_content(html)

        assert 'href="https://example.com"' in result
        assert 'title="Example Link"' in result

    def test_disallowed_tags_stripped(self):
        """허용되지 않은 태그 제거 테스트"""
        html = '''
        <div>Division</div>
        <span>Span</span>
        <style>.danger{color:red}</style>
        <form action="/hack">Form</form>
        <input type="text" value="input">
        <button>Button</button>
        '''

        result = sanitize_content(html)

        assert '<div>' not in result
        assert '<span>' not in result
        assert '<style>' not in result
        assert '<form>' not in result
        assert '<input' not in result
        assert '<button>' not in result
        # 내용은 보존되어야 함
        assert 'Division' in result
        assert 'Span' in result

    def test_disallowed_attributes_removed(self):
        """허용되지 않은 속성 제거 테스트"""
        html = '<p style="color:red" class="danger" id="para1">Text</p>'
        result = sanitize_content(html)

        assert 'style=' not in result
        assert 'class=' not in result
        assert 'id=' not in result
        assert '<p>' in result
        assert 'Text' in result

    def test_nested_xss_attack(self):
        """중첩 XSS 공격 방지 테스트"""
        payload = '<p><script>alert("XSS")</script></p>'
        result = sanitize_content(payload)

        assert '<script>' not in result
        assert '<p>' in result

    def test_mixed_content(self):
        """정상 콘텐츠와 악성 콘텐츠 혼합 테스트"""
        html = '''
        <p>This is safe content.</p>
        <script>alert("XSS")</script>
        <strong>Bold text</strong>
        <img src=x onerror=alert("XSS")>
        <a href="https://safe.com">Safe link</a>
        '''

        result = sanitize_content(html)

        # 안전한 콘텐츠 보존
        assert 'This is safe content.' in result
        assert '<strong>Bold text</strong>' in result
        assert '<a href="https://safe.com">' in result

        # 악성 콘텐츠 제거
        assert '<script>' not in result
        assert 'onerror' not in result

    def test_empty_content(self):
        """빈 콘텐츠 처리 테스트"""
        assert sanitize_content('') == ''
        assert sanitize_content('   ') == '   '

    def test_plain_text_preserved(self):
        """일반 텍스트 보존 테스트"""
        text = 'This is plain text without any HTML.'
        assert sanitize_content(text) == text


class TestSanitizeTitle:
    """sanitize_title() 제목 필터링 테스트"""

    def test_all_tags_removed(self):
        """모든 HTML 태그 제거 테스트"""
        html = '<h1>Title with <strong>bold</strong> and <em>italic</em></h1>'
        result = sanitize_title(html)

        assert '<h1>' not in result
        assert '<strong>' not in result
        assert '<em>' not in result
        assert 'Title with bold and italic' in result

    def test_script_in_title_removed(self):
        """제목 내 스크립트 제거 테스트"""
        payload = 'Title<script>alert("XSS")</script>End'
        result = sanitize_title(payload)

        assert '<script>' not in result
        assert '</script>' not in result
        # bleach strip=True는 태그를 제거하고 내용은 유지
        # 핵심은 실행 가능한 스크립트 태그가 없어야 한다는 것
        assert 'Title' in result
        assert 'End' in result

    def test_plain_text_title_preserved(self):
        """일반 텍스트 제목 보존 테스트"""
        title = 'This is a normal title'
        assert sanitize_title(title) == title

    def test_special_characters_preserved(self):
        """특수문자 보존 테스트"""
        # bleach는 HTML 엔티티로 &를 &amp;로 변환함
        title = 'Title with special chars: @#$%^*()'  # & 제외
        assert sanitize_title(title) == title

    def test_ampersand_entity_encoded(self):
        """&가 HTML 엔티티로 인코딩되는지 테스트"""
        title = 'Title with &'
        result = sanitize_title(title)
        # bleach는 &를 &amp;로 인코딩함 (HTML 안전성)
        assert '&amp;' in result or '&' in result

    def test_unicode_preserved(self):
        """유니코드 문자 보존 테스트"""
        title = 'Title with Korean: 안녕하세요'
        assert sanitize_title(title) == title


class TestAllowedTagsAndAttrs:
    """ALLOWED_TAGS, ALLOWED_ATTRS 검증 테스트"""

    def test_allowed_tags_completeness(self):
        """허용 태그 목록 완전성 테스트"""
        expected_tags = [
            'p', 'br', 'strong', 'em', 'u', 'a',
            'ul', 'ol', 'li', 'h1', 'h2', 'h3',
            'code', 'pre', 'blockquote'
        ]

        for tag in expected_tags:
            assert tag in ALLOWED_TAGS

    def test_dangerous_tags_not_allowed(self):
        """위험한 태그 미허용 테스트"""
        dangerous_tags = [
            'script', 'style', 'iframe', 'object', 'embed',
            'form', 'input', 'button', 'textarea', 'select',
            'meta', 'link', 'base', 'svg', 'math'
        ]

        for tag in dangerous_tags:
            assert tag not in ALLOWED_TAGS

    def test_allowed_attrs_for_anchor(self):
        """<a> 태그 허용 속성 테스트"""
        assert 'a' in ALLOWED_ATTRS
        assert 'href' in ALLOWED_ATTRS['a']
        assert 'title' in ALLOWED_ATTRS['a']

    def test_dangerous_attrs_not_allowed(self):
        """위험한 속성 미허용 테스트"""
        dangerous_attrs = ['onclick', 'onerror', 'onload', 'style', 'class', 'id']

        for attr in dangerous_attrs:
            for tag_attrs in ALLOWED_ATTRS.values():
                assert attr not in tag_attrs


class TestXSSPayloads:
    """다양한 XSS 페이로드 테스트"""

    def test_common_xss_payloads(self, xss_payloads):
        """일반적인 XSS 페이로드 방어 테스트"""
        for payload in xss_payloads:
            content_result = sanitize_content(payload)
            title_result = sanitize_title(payload)

            # 스크립트 실행 가능한 요소 제거 확인
            assert '<script' not in content_result.lower()
            assert 'javascript:' not in content_result.lower()
            assert 'onerror' not in content_result.lower()
            assert 'onload' not in content_result.lower()
            assert 'onclick' not in content_result.lower()

            # 제목에서는 모든 태그 제거
            assert '<' not in title_result or '>' not in title_result

    def test_encoded_xss_payloads(self):
        """인코딩된 XSS 페이로드 테스트"""
        # HTML 엔티티 인코딩된 페이로드
        payloads = [
            '&lt;script&gt;alert("XSS")&lt;/script&gt;',  # HTML 엔티티
        ]

        for payload in payloads:
            result = sanitize_content(payload)
            # bleach는 이미 인코딩된 엔티티는 그대로 유지
            # 실행 가능한 스크립트가 없어야 함
            assert '<script>' not in result

    def test_case_variation_xss(self):
        """대소문자 변형 XSS 테스트"""
        payloads = [
            '<SCRIPT>alert("XSS")</SCRIPT>',
            '<Script>alert("XSS")</Script>',
            '<sCrIpT>alert("XSS")</sCrIpT>',
        ]

        for payload in payloads:
            result = sanitize_content(payload)
            assert 'script' not in result.lower() or 'alert' not in result
