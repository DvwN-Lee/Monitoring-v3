// Monitoring-v3/api-gateway/main.go
// Version: 1.1.0 - Security Enhancement (CORS, Security Headers, Rate Limiting, Request Size Limit)

package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/time/rate"
)

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"method", "status"},
	)
	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Duration of HTTP requests",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method"},
	)
)

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

// === CORS Configuration ===
var allowedOrigins = strings.Split(getEnv("ALLOWED_ORIGINS", ""), ",")

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		for _, o := range allowedOrigins {
			if strings.TrimSpace(o) == origin {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Access-Control-Allow-Credentials", "true")
				w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
				w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With")
				w.Header().Set("Access-Control-Max-Age", "86400")
				break
			}
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// === Security Headers Middleware ===
func securityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// HSTS - HTTPS 강제
		w.Header().Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		// Clickjacking 방지
		w.Header().Set("X-Frame-Options", "DENY")
		// MIME type sniffing 방지
		w.Header().Set("X-Content-Type-Options", "nosniff")
		// XSS Filter (legacy browsers)
		w.Header().Set("X-XSS-Protection", "1; mode=block")
		// Referrer Policy
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		// Permissions Policy
		w.Header().Set("Permissions-Policy", "geolocation=(), microphone=(), camera=()")

		// CSP: API endpoint는 strict, Blog HTML 페이지는 완화
		if strings.HasPrefix(r.URL.Path, "/blog/") && !strings.HasPrefix(r.URL.Path, "/blog/api/") {
			w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;")
		} else {
			w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		}

		// 민감한 API endpoint에 Cache-Control 추가
		if strings.HasPrefix(r.URL.Path, "/api/") || strings.HasPrefix(r.URL.Path, "/blog/api/") {
			w.Header().Set("Cache-Control", "no-store")
		}

		next.ServeHTTP(w, r)
	})
}

// === Rate Limiting with TTL Cleanup ===
type visitor struct {
	limiter  *rate.Limiter
	lastSeen time.Time
}

type RateLimiter struct {
	visitors map[string]*visitor
	mu       sync.RWMutex
	r        rate.Limit
	burst    int
}

func NewRateLimiter(r rate.Limit, burst int) *RateLimiter {
	rl := &RateLimiter{
		visitors: make(map[string]*visitor),
		r:        r,
		burst:    burst,
	}
	go rl.cleanupVisitors()
	return rl
}

func (rl *RateLimiter) cleanupVisitors() {
	for {
		time.Sleep(time.Minute)
		rl.mu.Lock()
		for ip, v := range rl.visitors {
			if time.Since(v.lastSeen) > 3*time.Minute {
				delete(rl.visitors, ip)
			}
		}
		rl.mu.Unlock()
	}
}

func (rl *RateLimiter) GetLimiter(ip string) *rate.Limiter {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	v, exists := rl.visitors[ip]
	if !exists {
		limiter := rate.NewLimiter(rl.r, rl.burst)
		rl.visitors[ip] = &visitor{limiter: limiter, lastSeen: time.Now()}
		return limiter
	}
	v.lastSeen = time.Now()
	return v.limiter
}

// Rate Limit: 20 req/sec, burst 50 (Gemini recommendation)
var globalLimiter = NewRateLimiter(20, 50)

func getClientIP(r *http.Request) string {
	// X-Forwarded-For header (reverse proxy)
	xff := r.Header.Get("X-Forwarded-For")
	if xff != "" {
		ips := strings.Split(xff, ",")
		return strings.TrimSpace(ips[0])
	}
	// X-Real-IP header
	xri := r.Header.Get("X-Real-IP")
	if xri != "" {
		return xri
	}
	// Fallback to RemoteAddr
	ip, _, _ := net.SplitHostPort(r.RemoteAddr)
	return ip
}

func rateLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health/Metrics endpoint bypass
		if r.URL.Path == "/health" || r.URL.Path == "/metrics" {
			next.ServeHTTP(w, r)
			return
		}

		ip := getClientIP(r)
		limiter := globalLimiter.GetLimiter(ip)
		if !limiter.Allow() {
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			json.NewEncoder(w).Encode(map[string]string{"error": "Too Many Requests"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// === Request Size Limit ===
const MaxRequestBodySize = 10 << 20 // 10MB (Gemini recommendation)

func requestSizeLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, MaxRequestBodySize)
		next.ServeHTTP(w, r)
	})
}

// statusRecorder records the status code of the response
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func prometheusMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &statusRecorder{
			ResponseWriter: w,
			status:         http.StatusOK,
		}
		timer := prometheus.NewTimer(httpRequestDuration.WithLabelValues(r.Method))
		next.ServeHTTP(recorder, r)
		timer.ObserveDuration()

		// Record status code
		statusClass := "unknown"
		if recorder.status >= 500 {
			statusClass = "5xx"
		} else if recorder.status >= 400 {
			statusClass = "4xx"
		} else if recorder.status >= 300 {
			statusClass = "3xx"
		} else if recorder.status >= 200 {
			statusClass = "2xx"
		}
		httpRequestsTotal.WithLabelValues(r.Method, statusClass).Inc()
	})
}

func main() {
	port := getEnv("API_GATEWAY_PORT", "8000")

	// 각 서비스 URL 파싱
	userServiceURL, _ := url.Parse(getEnv("USER_SERVICE_URL", "http://user-service:8001"))
	authServiceURL, _ := url.Parse(getEnv("AUTH_SERVICE_URL", "http://auth-service:8002"))
	blogServiceURL, _ := url.Parse(getEnv("BLOG_SERVICE_URL", "http://blog-service:8005"))

	// Create proxies with custom director to preserve hostname for Istio
	userProxy := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = userServiceURL.Scheme
			req.URL.Host = userServiceURL.Host
			req.Host = userServiceURL.Host
		},
	}

	authProxy := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = authServiceURL.Scheme
			req.URL.Host = authServiceURL.Host
			req.Host = authServiceURL.Host
		},
	}

	blogProxy := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = blogServiceURL.Scheme
			req.URL.Host = blogServiceURL.Host
			req.Host = blogServiceURL.Host
		},
	}

	mux := http.NewServeMux()

	apiHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// /api/ 접두사를 제거하여 실제 경로 추출
		trimmedPath := strings.TrimPrefix(path, "/api")

		// /blog/api/ 같은 다른 접두사도 처리
		if strings.HasPrefix(path, "/blog/api/") {
			trimmedPath = strings.TrimPrefix(path, "/blog/api")
		}

		if strings.HasSuffix(trimmedPath, "/login") {
			r.URL.Path = "/login"
			authProxy.ServeHTTP(w, r)
		} else if strings.HasSuffix(trimmedPath, "/register") {
			r.URL.Path = "/users" // Register는 user-service의 /users 엔드포인트를 사용
			userProxy.ServeHTTP(w, r)
		} else if strings.HasPrefix(trimmedPath, "/users") {
			r.URL.Path = trimmedPath
			userProxy.ServeHTTP(w, r)
		} else if strings.HasPrefix(trimmedPath, "/posts") || strings.HasPrefix(trimmedPath, "/categories") {
			r.URL.Path = path // blog service의 전체 경로 사용
			blogProxy.ServeHTTP(w, r)
		} else {
			http.NotFound(w, r)
		}
	})

	mux.Handle("/api/", apiHandler)
	mux.Handle("/blog/api/", apiHandler)
	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		stats := map[string]interface{}{
			"api-gateway": map[string]interface{}{
				"service_status": "online",
				"info":           "Proxying API requests",
			},
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(stats)
	})

	// Middleware Chain: CORS -> RequestSize -> RateLimit -> Security -> Prometheus -> Mux
	// CORS must be outermost to ensure CORS headers are included in rate limit errors
	handler := corsMiddleware(
		requestSizeLimitMiddleware(
			rateLimitMiddleware(
				securityHeadersMiddleware(
					prometheusMiddleware(mux)))))

	log.Printf("Go API Gateway started on :%s", port)
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 2 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 14, // 16KB max header size
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
