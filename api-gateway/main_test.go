// api-gateway/main_test.go
// 단위 테스트: 라우팅, Rate Limiting, Security Headers, CORS

package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/time/rate"
)

// TestGetEnv tests the getEnv function
func TestGetEnv(t *testing.T) {
	tests := []struct {
		name     string
		key      string
		fallback string
		setEnv   bool
		envValue string
		expected string
	}{
		{
			name:     "환경변수 설정됨",
			key:      "TEST_VAR_1",
			fallback: "default",
			setEnv:   true,
			envValue: "custom_value",
			expected: "custom_value",
		},
		{
			name:     "환경변수 미설정 - 기본값 사용",
			key:      "TEST_VAR_2",
			fallback: "default_value",
			setEnv:   false,
			expected: "default_value",
		},
		{
			name:     "빈 환경변수 설정",
			key:      "TEST_VAR_3",
			fallback: "default",
			setEnv:   true,
			envValue: "",
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.setEnv {
				t.Setenv(tt.key, tt.envValue)
			}
			result := getEnv(tt.key, tt.fallback)
			if result != tt.expected {
				t.Errorf("getEnv(%s, %s) = %s; want %s", tt.key, tt.fallback, result, tt.expected)
			}
		})
	}
}

// TestGetClientIP tests client IP extraction from various headers
func TestGetClientIP(t *testing.T) {
	tests := []struct {
		name       string
		xff        string
		xri        string
		remoteAddr string
		expected   string
	}{
		{
			name:       "X-Forwarded-For 헤더 사용",
			xff:        "192.168.1.1, 10.0.0.1, 172.16.0.1",
			xri:        "",
			remoteAddr: "127.0.0.1:12345",
			expected:   "192.168.1.1",
		},
		{
			name:       "X-Real-IP 헤더 사용",
			xff:        "",
			xri:        "192.168.1.100",
			remoteAddr: "127.0.0.1:12345",
			expected:   "192.168.1.100",
		},
		{
			name:       "RemoteAddr 폴백",
			xff:        "",
			xri:        "",
			remoteAddr: "10.0.0.50:54321",
			expected:   "10.0.0.50",
		},
		{
			name:       "단일 IP X-Forwarded-For",
			xff:        "203.0.113.50",
			xri:        "",
			remoteAddr: "127.0.0.1:12345",
			expected:   "203.0.113.50",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tt.xff != "" {
				req.Header.Set("X-Forwarded-For", tt.xff)
			}
			if tt.xri != "" {
				req.Header.Set("X-Real-IP", tt.xri)
			}
			req.RemoteAddr = tt.remoteAddr

			result := getClientIP(req)
			if result != tt.expected {
				t.Errorf("getClientIP() = %s; want %s", result, tt.expected)
			}
		})
	}
}

// TestSecurityHeadersMiddleware tests security headers are properly set
func TestSecurityHeadersMiddleware(t *testing.T) {
	// 간단한 핸들러 생성
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := securityHeadersMiddleware(nextHandler)

	tests := []struct {
		name           string
		path           string
		expectedCSP    string
		checkCacheCtrl bool
	}{
		{
			name:           "API 엔드포인트 - strict CSP",
			path:           "/api/users",
			expectedCSP:    "default-src 'none'; frame-ancestors 'none'",
			checkCacheCtrl: true,
		},
		{
			name:           "Blog API 엔드포인트 - strict CSP",
			path:           "/blog/api/posts",
			expectedCSP:    "default-src 'none'; frame-ancestors 'none'",
			checkCacheCtrl: true,
		},
		{
			name:           "Blog HTML 페이지 - 완화된 CSP",
			path:           "/blog/",
			expectedCSP:    "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;",
			checkCacheCtrl: false,
		},
		{
			name:           "Health 엔드포인트",
			path:           "/health",
			expectedCSP:    "default-src 'none'; frame-ancestors 'none'",
			checkCacheCtrl: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, tt.path, nil)
			rr := httptest.NewRecorder()

			handler.ServeHTTP(rr, req)

			// 공통 보안 헤더 확인
			headers := map[string]string{
				"Strict-Transport-Security": "max-age=31536000; includeSubDomains",
				"X-Frame-Options":           "DENY",
				"X-Content-Type-Options":    "nosniff",
				"X-XSS-Protection":          "1; mode=block",
				"Referrer-Policy":           "strict-origin-when-cross-origin",
			}

			for header, expected := range headers {
				if got := rr.Header().Get(header); got != expected {
					t.Errorf("Header %s = %s; want %s", header, got, expected)
				}
			}

			// CSP 확인
			if got := rr.Header().Get("Content-Security-Policy"); got != tt.expectedCSP {
				t.Errorf("CSP = %s; want %s", got, tt.expectedCSP)
			}

			// Cache-Control 확인 (API 엔드포인트만)
			if tt.checkCacheCtrl {
				if got := rr.Header().Get("Cache-Control"); got != "no-store" {
					t.Errorf("Cache-Control = %s; want no-store", got)
				}
			}
		})
	}
}

// TestCORSMiddleware tests CORS headers
func TestCORSMiddleware(t *testing.T) {
	// 테스트용 allowed origins 설정
	originalOrigins := allowedOrigins
	allowedOrigins = []string{"http://localhost:3000", "https://example.com"}
	defer func() { allowedOrigins = originalOrigins }()

	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := corsMiddleware(nextHandler)

	tests := []struct {
		name           string
		origin         string
		method         string
		expectCORS     bool
		expectedStatus int
	}{
		{
			name:           "허용된 origin - GET 요청",
			origin:         "http://localhost:3000",
			method:         http.MethodGet,
			expectCORS:     true,
			expectedStatus: http.StatusOK,
		},
		{
			name:           "허용된 origin - OPTIONS preflight",
			origin:         "https://example.com",
			method:         http.MethodOptions,
			expectCORS:     true,
			expectedStatus: http.StatusNoContent,
		},
		{
			name:           "허용되지 않은 origin",
			origin:         "http://malicious.com",
			method:         http.MethodGet,
			expectCORS:     false,
			expectedStatus: http.StatusOK,
		},
		{
			name:           "origin 헤더 없음",
			origin:         "",
			method:         http.MethodGet,
			expectCORS:     false,
			expectedStatus: http.StatusOK,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, "/api/users", nil)
			if tt.origin != "" {
				req.Header.Set("Origin", tt.origin)
			}
			rr := httptest.NewRecorder()

			handler.ServeHTTP(rr, req)

			if rr.Code != tt.expectedStatus {
				t.Errorf("Status = %d; want %d", rr.Code, tt.expectedStatus)
			}

			if tt.expectCORS {
				if got := rr.Header().Get("Access-Control-Allow-Origin"); got != tt.origin {
					t.Errorf("Access-Control-Allow-Origin = %s; want %s", got, tt.origin)
				}
				if got := rr.Header().Get("Access-Control-Allow-Credentials"); got != "true" {
					t.Errorf("Access-Control-Allow-Credentials = %s; want true", got)
				}
			} else {
				if got := rr.Header().Get("Access-Control-Allow-Origin"); got != "" {
					t.Errorf("Access-Control-Allow-Origin should be empty, got %s", got)
				}
			}
		})
	}
}

// TestRateLimiter tests the rate limiter functionality
func TestRateLimiter(t *testing.T) {
	// 테스트용 Rate Limiter 생성 (낮은 값으로 테스트)
	rl := NewRateLimiter(2, 2) // 2 req/sec, burst 2

	t.Run("새 IP에 대한 limiter 생성", func(t *testing.T) {
		limiter := rl.GetLimiter("192.168.1.1")
		if limiter == nil {
			t.Error("GetLimiter returned nil")
		}
	})

	t.Run("동일 IP는 동일 limiter 반환", func(t *testing.T) {
		limiter1 := rl.GetLimiter("192.168.1.2")
		limiter2 := rl.GetLimiter("192.168.1.2")
		if limiter1 != limiter2 {
			t.Error("Same IP should return same limiter")
		}
	})

	t.Run("다른 IP는 다른 limiter 반환", func(t *testing.T) {
		limiter1 := rl.GetLimiter("192.168.1.3")
		limiter2 := rl.GetLimiter("192.168.1.4")
		if limiter1 == limiter2 {
			t.Error("Different IPs should return different limiters")
		}
	})

	t.Run("Rate Limit 초과 시 거부", func(t *testing.T) {
		testRL := &RateLimiter{
			visitors: make(map[string]*visitor),
			r:        rate.Limit(1), // 1 req/sec
			burst:    1,
		}

		ip := "10.0.0.1"
		limiter := testRL.GetLimiter(ip)

		// 첫 번째 요청 - 허용
		if !limiter.Allow() {
			t.Error("First request should be allowed")
		}

		// 버스트 초과 후 요청 - 거부
		if limiter.Allow() {
			t.Error("Request after burst should be denied")
		}
	})
}

// TestRateLimitMiddleware tests the rate limit middleware behavior
func TestRateLimitMiddleware(t *testing.T) {
	// 테스트용 global limiter 백업 및 교체
	originalLimiter := globalLimiter
	globalLimiter = NewRateLimiter(1, 1) // 매우 낮은 값으로 설정
	defer func() { globalLimiter = originalLimiter }()

	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := rateLimitMiddleware(nextHandler)

	t.Run("Health 엔드포인트 bypass", func(t *testing.T) {
		for i := 0; i < 10; i++ {
			req := httptest.NewRequest(http.MethodGet, "/health", nil)
			req.RemoteAddr = "192.168.100.1:12345"
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Errorf("Health endpoint should bypass rate limit, got %d", rr.Code)
			}
		}
	})

	t.Run("Metrics 엔드포인트 bypass", func(t *testing.T) {
		for i := 0; i < 10; i++ {
			req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
			req.RemoteAddr = "192.168.100.2:12345"
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Errorf("Metrics endpoint should bypass rate limit, got %d", rr.Code)
			}
		}
	})

	t.Run("일반 엔드포인트 Rate Limit 적용", func(t *testing.T) {
		// 새로운 IP로 테스트 (기존 limiter 영향 없이)
		testIP := "192.168.200.1:12345"

		// 첫 번째 요청 - 허용
		req1 := httptest.NewRequest(http.MethodGet, "/api/users", nil)
		req1.RemoteAddr = testIP
		rr1 := httptest.NewRecorder()
		handler.ServeHTTP(rr1, req1)
		if rr1.Code != http.StatusOK {
			t.Errorf("First request should be allowed, got %d", rr1.Code)
		}

		// 버스트 초과 요청 - 거부 예상
		req2 := httptest.NewRequest(http.MethodGet, "/api/users", nil)
		req2.RemoteAddr = testIP
		rr2 := httptest.NewRecorder()
		handler.ServeHTTP(rr2, req2)
		if rr2.Code != http.StatusTooManyRequests {
			t.Errorf("Second request should be rate limited, got %d", rr2.Code)
		}

		// 429 응답 확인
		if !strings.Contains(rr2.Body.String(), "Too Many Requests") {
			t.Error("Response should contain 'Too Many Requests'")
		}

		// Retry-After 헤더 확인
		if rr2.Header().Get("Retry-After") == "" {
			t.Error("Response should include Retry-After header")
		}
	})
}

// TestStatusRecorder tests the status recorder
func TestStatusRecorder(t *testing.T) {
	t.Run("기본 상태 코드 200", func(t *testing.T) {
		rr := httptest.NewRecorder()
		sr := &statusRecorder{ResponseWriter: rr, status: http.StatusOK}

		if sr.status != http.StatusOK {
			t.Errorf("Default status = %d; want %d", sr.status, http.StatusOK)
		}
	})

	t.Run("WriteHeader 호출 시 상태 기록", func(t *testing.T) {
		rr := httptest.NewRecorder()
		sr := &statusRecorder{ResponseWriter: rr, status: http.StatusOK}

		sr.WriteHeader(http.StatusNotFound)

		if sr.status != http.StatusNotFound {
			t.Errorf("Status after WriteHeader = %d; want %d", sr.status, http.StatusNotFound)
		}
	})
}

// TestRequestSizeLimitMiddleware tests request size limiting
func TestRequestSizeLimitMiddleware(t *testing.T) {
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Body 읽기 시도
		buf := make([]byte, 1024)
		_, err := r.Body.Read(buf)
		if err != nil && err.Error() != "EOF" && !strings.Contains(err.Error(), "request body too large") {
			// 에러가 있지만 예상된 에러가 아닌 경우
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusOK)
	})

	handler := requestSizeLimitMiddleware(nextHandler)

	t.Run("정상 크기 요청 허용", func(t *testing.T) {
		body := strings.NewReader("small body")
		req := httptest.NewRequest(http.MethodPost, "/api/posts", body)
		rr := httptest.NewRecorder()

		handler.ServeHTTP(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("Small request should be allowed, got %d", rr.Code)
		}
	})
}

// TestMaxRequestBodySize tests the constant value
func TestMaxRequestBodySize(t *testing.T) {
	expected := 10 << 20 // 10MB
	if MaxRequestBodySize != expected {
		t.Errorf("MaxRequestBodySize = %d; want %d (10MB)", MaxRequestBodySize, expected)
	}
}

// BenchmarkGetClientIP benchmarks IP extraction
func BenchmarkGetClientIP(b *testing.B) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("X-Forwarded-For", "192.168.1.1, 10.0.0.1")
	req.RemoteAddr = "127.0.0.1:12345"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		getClientIP(req)
	}
}

// BenchmarkRateLimiterGetLimiter benchmarks limiter retrieval
func BenchmarkRateLimiterGetLimiter(b *testing.B) {
	rl := &RateLimiter{
		visitors: make(map[string]*visitor),
		r:        20,
		burst:    50,
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rl.GetLimiter("192.168.1.1")
	}
}

// TestVisitorTTLUpdate tests that lastSeen is updated on access
func TestVisitorTTLUpdate(t *testing.T) {
	rl := &RateLimiter{
		visitors: make(map[string]*visitor),
		r:        20,
		burst:    50,
	}

	ip := "192.168.1.1"

	// 첫 접근
	rl.GetLimiter(ip)
	firstAccess := rl.visitors[ip].lastSeen

	// 잠시 대기
	time.Sleep(10 * time.Millisecond)

	// 두 번째 접근
	rl.GetLimiter(ip)
	secondAccess := rl.visitors[ip].lastSeen

	if !secondAccess.After(firstAccess) {
		t.Error("lastSeen should be updated on access")
	}
}
