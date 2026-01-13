# API Gateway 코드 리뷰 개선사항

## 요약

| 심각도 | 개수 |
|--------|------|
| Critical | 4 |
| High | 4 |
| Medium | 4 |

---

## 1. 코드 품질 개선

### 1.1 URL 파싱 에러 무시

- **위치:** `api-gateway/main.go:85-87`
- **심각도:** Critical
- **문제:** URL 파싱 실패 시 에러를 무시하고 nil 값으로 진행하여 런타임 Panic 발생 가능

**현재 코드:**
```go
userServiceURL, _ := url.Parse(getEnv("USER_SERVICE_URL", "http://user-service:8001"))
authServiceURL, _ := url.Parse(getEnv("AUTH_SERVICE_URL", "http://auth-service:8002"))
blogServiceURL, _ := url.Parse(getEnv("BLOG_SERVICE_URL", "http://blog-service:8005"))
```

**개선 코드:**
```go
userServiceURL, err := url.Parse(getEnv("USER_SERVICE_URL", "http://user-service:8001"))
if err != nil {
    log.Fatalf("Invalid USER_SERVICE_URL: %v", err)
}

authServiceURL, err := url.Parse(getEnv("AUTH_SERVICE_URL", "http://auth-service:8002"))
if err != nil {
    log.Fatalf("Invalid AUTH_SERVICE_URL: %v", err)
}

blogServiceURL, err := url.Parse(getEnv("BLOG_SERVICE_URL", "http://blog-service:8005"))
if err != nil {
    log.Fatalf("Invalid BLOG_SERVICE_URL: %v", err)
}
```

---

### 1.2 JSON 인코딩 에러 무시

- **위치:** `api-gateway/main.go:160`
- **심각도:** Medium
- **문제:** JSON 인코딩 실패 시 에러가 반환되나 무시됨

**현재 코드:**
```go
json.NewEncoder(w).Encode(stats)
```

**개선 코드:**
```go
if err := json.NewEncoder(w).Encode(stats); err != nil {
    log.Printf("Failed to encode stats response: %v", err)
}
```

---

### 1.3 ReverseProxy Director 로직 중복

- **위치:** `api-gateway/main.go:90-112`
- **심각도:** Medium
- **문제:** 동일한 패턴이 3번 반복됨 (DRY 원칙 위반)

**현재 코드:**
```go
userProxy := &httputil.ReverseProxy{
    Director: func(req *http.Request) {
        req.URL.Scheme = userServiceURL.Scheme
        req.URL.Host = userServiceURL.Host
        req.Host = userServiceURL.Host
    },
}
// authProxy, blogProxy도 동일한 패턴
```

**개선 코드:**
```go
func createReverseProxy(targetURL *url.URL) *httputil.ReverseProxy {
    return &httputil.ReverseProxy{
        Director: func(req *http.Request) {
            req.URL.Scheme = targetURL.Scheme
            req.URL.Host = targetURL.Host
            req.Host = targetURL.Host
        },
    }
}

// 사용
userProxy := createReverseProxy(userServiceURL)
authProxy := createReverseProxy(authServiceURL)
blogProxy := createReverseProxy(blogServiceURL)
```

---

### 1.4 경로 처리 로직 복잡성

- **위치:** `api-gateway/main.go:116-142`
- **심각도:** Medium
- **문제:** 경로 라우팅 로직이 복잡하고 일관성이 부족함

**개선 코드:**
```go
type Route struct {
    Prefix  string
    Target  *httputil.ReverseProxy
    Rewrite func(string) string
}

type Router struct {
    routes []Route
}

func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    path := req.URL.Path

    for _, route := range r.routes {
        if strings.HasPrefix(path, route.Prefix) {
            if route.Rewrite != nil {
                req.URL.Path = route.Rewrite(path)
            }
            route.Target.ServeHTTP(w, req)
            return
        }
    }
    http.NotFound(w, req)
}

// 라우팅 설정
router := &Router{
    routes: []Route{
        {"/api/login", authProxy, func(p string) string { return "/login" }},
        {"/api/register", userProxy, func(p string) string { return "/users" }},
        {"/api/users", userProxy, func(p string) string { return strings.TrimPrefix(p, "/api") }},
        {"/blog/api/", blogProxy, func(p string) string { return strings.TrimPrefix(p, "/blog/api") }},
    },
}
```

---

## 2. 보안 개선

### 2.1 경로 탐색 공격 방어

- **위치:** `api-gateway/main.go:134, 137`
- **심각도:** Critical
- **문제:** 사용자 입력 경로를 직접 백엔드로 전달하여 `/../` 같은 경로 탐색 패턴이 필터링되지 않음

**개선 코드:**
```go
import "path/filepath"

func isValidPath(p string) bool {
    cleaned := filepath.Clean(p)
    if strings.Contains(cleaned, "..") {
        return false
    }
    return true
}

// apiHandler 내에서
func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    path := req.URL.Path

    if !isValidPath(path) {
        http.Error(w, "Invalid path", http.StatusBadRequest)
        return
    }

    // 라우팅 로직...
}
```

---

### 2.2 HTTP 메서드 검증

- **위치:** `api-gateway/main.go:116-142`
- **심각도:** High
- **문제:** 모든 HTTP 메서드를 무조건 백엔드로 전달

**개선 코드:**
```go
type Route struct {
    Prefix         string
    Target         *httputil.ReverseProxy
    AllowedMethods []string
    Rewrite        func(string) string
}

func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    path := req.URL.Path

    for _, route := range r.routes {
        if strings.HasPrefix(path, route.Prefix) {
            // 메서드 검증
            if len(route.AllowedMethods) > 0 {
                allowed := false
                for _, m := range route.AllowedMethods {
                    if m == req.Method {
                        allowed = true
                        break
                    }
                }
                if !allowed {
                    http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
                    return
                }
            }
            // 라우팅...
        }
    }
}

// 사용
routes := []Route{
    {"/api/login", authProxy, []string{"POST"}, nil},
    {"/api/register", userProxy, []string{"POST"}, nil},
    {"/api/users", userProxy, []string{"GET", "POST", "PUT", "DELETE"}, nil},
}
```

---

### 2.3 X-Forwarded 헤더 추가

- **위치:** `api-gateway/main.go:94, 102, 110`
- **심각도:** Medium
- **문제:** 원본 클라이언트 정보가 백엔드로 전달되지 않음

**개선 코드:**
```go
func createReverseProxy(targetURL *url.URL) *httputil.ReverseProxy {
    return &httputil.ReverseProxy{
        Director: func(req *http.Request) {
            originalHost := req.Host
            originalIP := req.RemoteAddr

            req.URL.Scheme = targetURL.Scheme
            req.URL.Host = targetURL.Host
            req.Host = targetURL.Host

            // X-Forwarded 헤더 추가
            req.Header.Set("X-Forwarded-Host", originalHost)
            req.Header.Set("X-Forwarded-For", originalIP)
            req.Header.Set("X-Forwarded-Proto", "http") // HTTPS 사용 시 동적 처리 필요
            req.Header.Set("X-Real-IP", strings.Split(originalIP, ":")[0])
        },
    }
}
```

---

## 3. 성능 개선

### 3.1 ReverseProxy 타임아웃 및 에러 핸들러

- **위치:** `api-gateway/main.go:90-112`
- **심각도:** High
- **문제:** ReverseProxy에 타임아웃, 재시도 로직, 에러 핸들러가 없음

**개선 코드:**
```go
func createReverseProxy(targetURL *url.URL) *httputil.ReverseProxy {
    transport := &http.Transport{
        MaxIdleConns:        100,
        MaxIdleConnsPerHost: 100,
        IdleConnTimeout:     90 * time.Second,
        DialContext: (&net.Dialer{
            Timeout:   5 * time.Second,
            KeepAlive: 30 * time.Second,
        }).DialContext,
        TLSHandshakeTimeout:   10 * time.Second,
        ResponseHeaderTimeout: 10 * time.Second,
    }

    proxy := &httputil.ReverseProxy{
        Director: func(req *http.Request) {
            req.URL.Scheme = targetURL.Scheme
            req.URL.Host = targetURL.Host
            req.Host = targetURL.Host
        },
        Transport: transport,
        ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
            log.Printf("ReverseProxy error for %s: %v", r.URL.Path, err)
            http.Error(w, "Service Unavailable", http.StatusServiceUnavailable)
        },
    }
    return proxy
}
```

---

### 3.2 메트릭 경로 레이블 추가

- **위치:** `api-gateway/main.go:21-35`
- **심각도:** Medium
- **문제:** 메트릭에 경로 정보가 없어 엔드포인트별 성능 분석 불가

**개선 코드:**
```go
var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "status", "path"},
    )

    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "Duration of HTTP requests",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "path"},
    )
)

// 경로 정규화 (카디널리티 제한)
func normalizePath(path string) string {
    // /api/users/123 -> /api/users/:id
    re := regexp.MustCompile(`/\d+`)
    return re.ReplaceAllString(path, "/:id")
}

func prometheusMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
        normalizedPath := normalizePath(r.URL.Path)

        timer := prometheus.NewTimer(httpRequestDuration.WithLabelValues(r.Method, normalizedPath))
        next.ServeHTTP(recorder, r)
        timer.ObserveDuration()

        statusGroup := fmt.Sprintf("%dxx", recorder.status/100)
        httpRequestsTotal.WithLabelValues(r.Method, statusGroup, normalizedPath).Inc()
    })
}
```

---

### 3.3 statusRecorder sync.Pool 사용

- **위치:** `api-gateway/main.go:56-79`
- **심각도:** Low
- **문제:** 매 요청마다 새로운 statusRecorder 할당으로 GC 부담 증가

**개선 코드:**
```go
var recorderPool = sync.Pool{
    New: func() interface{} {
        return &statusRecorder{}
    },
}

func prometheusMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        recorder := recorderPool.Get().(*statusRecorder)
        recorder.ResponseWriter = w
        recorder.status = http.StatusOK
        defer recorderPool.Put(recorder)

        timer := prometheus.NewTimer(httpRequestDuration.WithLabelValues(r.Method))
        next.ServeHTTP(recorder, r)
        timer.ObserveDuration()

        statusGroup := fmt.Sprintf("%dxx", recorder.status/100)
        httpRequestsTotal.WithLabelValues(r.Method, statusGroup).Inc()
    })
}
```

---

## 4. 아키텍처 개선

### 4.1 설정 구조체 도입

- **위치:** `api-gateway/main.go:82-87`
- **심각도:** Medium
- **문제:** 환경 변수 처리가 main() 함수에 산재

**개선 코드:**
```go
type Config struct {
    Port         string
    UserService  string
    AuthService  string
    BlogService  string
    ReadTimeout  time.Duration
    WriteTimeout time.Duration
}

func loadConfig() Config {
    return Config{
        Port:         getEnv("API_GATEWAY_PORT", "8000"),
        UserService:  getEnv("USER_SERVICE_URL", "http://user-service:8001"),
        AuthService:  getEnv("AUTH_SERVICE_URL", "http://auth-service:8002"),
        BlogService:  getEnv("BLOG_SERVICE_URL", "http://blog-service:8005"),
        ReadTimeout:  10 * time.Second,
        WriteTimeout: 10 * time.Second,
    }
}

func main() {
    config := loadConfig()

    userServiceURL, err := url.Parse(config.UserService)
    if err != nil {
        log.Fatalf("Invalid USER_SERVICE_URL: %v", err)
    }
    // ...
}
```

---

### 4.2 구조화된 로깅 도입

- **위치:** `api-gateway/main.go` 전체
- **심각도:** Medium
- **문제:** 표준 log 패키지만 사용하여 구조화된 로깅 불가

**개선 코드:**
```go
import "log/slog"

func main() {
    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
    slog.SetDefault(logger)

    // 사용 예시
    slog.Info("starting api-gateway",
        slog.String("port", config.Port),
        slog.String("user_service", config.UserService),
    )
}

func prometheusMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        // ...
        slog.Debug("request completed",
            slog.String("method", r.Method),
            slog.String("path", r.URL.Path),
            slog.Int("status", recorder.status),
            slog.Duration("duration", time.Since(start)),
        )
    })
}
```

---

## 5. 모니터링/로깅 개선

### 5.1 백엔드 헬스 체크

- **위치:** `api-gateway/main.go:148-150`
- **심각도:** High
- **문제:** /health 엔드포인트가 백엔드 서비스 상태를 확인하지 않음

**개선 코드:**
```go
func checkBackendHealth(serviceURL *url.URL, timeout time.Duration) map[string]interface{} {
    client := &http.Client{Timeout: timeout}
    healthURL := fmt.Sprintf("%s://%s/health", serviceURL.Scheme, serviceURL.Host)

    resp, err := client.Get(healthURL)
    if err != nil {
        return map[string]interface{}{
            "status": "unhealthy",
            "error":  err.Error(),
        }
    }
    defer resp.Body.Close()

    if resp.StatusCode == http.StatusOK {
        return map[string]interface{}{"status": "healthy"}
    }
    return map[string]interface{}{
        "status":      "unhealthy",
        "status_code": resp.StatusCode,
    }
}

mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
    backends := map[string]interface{}{
        "user-service": checkBackendHealth(userServiceURL, 2*time.Second),
        "auth-service": checkBackendHealth(authServiceURL, 2*time.Second),
        "blog-service": checkBackendHealth(blogServiceURL, 2*time.Second),
    }

    allHealthy := true
    for _, status := range backends {
        if s, ok := status.(map[string]interface{}); ok {
            if s["status"] != "healthy" {
                allHealthy = false
                break
            }
        }
    }

    w.Header().Set("Content-Type", "application/json")
    if !allHealthy {
        w.WriteHeader(http.StatusServiceUnavailable)
    }

    json.NewEncoder(w).Encode(map[string]interface{}{
        "status":   map[bool]string{true: "healthy", false: "degraded"}[allHealthy],
        "backends": backends,
    })
})
```

---

### 5.2 슬로우 리퀘스트 로깅

- **위치:** `api-gateway/main.go:56-79`
- **심각도:** Medium
- **문제:** 응답 시간이 느린 요청에 대한 로깅 없음

**개선 코드:**
```go
const slowRequestThreshold = 1 * time.Second

func prometheusMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
        startTime := time.Now()

        next.ServeHTTP(recorder, r)

        duration := time.Since(startTime)

        if duration > slowRequestThreshold {
            slog.Warn("slow request detected",
                slog.String("method", r.Method),
                slog.String("path", r.URL.Path),
                slog.Duration("duration", duration),
                slog.Int("status", recorder.status),
            )
        }

        // 메트릭 기록...
    })
}
```

---

### 5.3 요청/응답 크기 메트릭

- **위치:** `api-gateway/main.go:20-36`
- **심각도:** Low
- **문제:** 요청/응답 크기 메트릭이 없어 대역폭 모니터링 불가

**개선 코드:**
```go
var (
    httpRequestSize = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_size_bytes",
            Help:    "Size of HTTP requests in bytes",
            Buckets: []float64{100, 1000, 10000, 100000, 1000000},
        },
        []string{"method"},
    )

    httpResponseSize = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_response_size_bytes",
            Help:    "Size of HTTP responses in bytes",
            Buckets: []float64{100, 1000, 10000, 100000, 1000000},
        },
        []string{"method", "status"},
    )
)

type responseRecorder struct {
    http.ResponseWriter
    status int
    size   int
}

func (r *responseRecorder) Write(b []byte) (int, error) {
    size, err := r.ResponseWriter.Write(b)
    r.size += size
    return size, err
}

func prometheusMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}

        // 요청 크기 기록
        if r.ContentLength > 0 {
            httpRequestSize.WithLabelValues(r.Method).Observe(float64(r.ContentLength))
        }

        next.ServeHTTP(recorder, r)

        // 응답 크기 기록
        httpResponseSize.WithLabelValues(r.Method, fmt.Sprintf("%dxx", recorder.status/100)).
            Observe(float64(recorder.size))
    })
}
```

---

## 수정 우선순위

1. **즉시 수정 (Critical)**
   - URL 파싱 에러 처리
   - 경로 탐색 공격 방어

2. **1주 내 수정 (High)**
   - HTTP 메서드 검증
   - ReverseProxy 타임아웃/에러 핸들러
   - 백엔드 헬스 체크

3. **2주 내 수정 (Medium)**
   - 구조화된 로깅 도입
   - 설정 구조체 도입
   - 메트릭 경로 레이블 추가
   - 코드 중복 제거
