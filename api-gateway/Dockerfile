# 1. 빌드 스테이지
FROM golang:1.24-alpine AS builder

WORKDIR /app
# 모듈 캐시를 활용하여 의존성 다운로드 후 소스 복사
COPY go.* ./
RUN go mod download || true
COPY . .
RUN go mod tidy || true

# CGO_ENABLED=0:순수 Go 코드로 빌드 (이미지 경량화)
# -o /app/server: 빌드 결과물을 /app/server 파일로 생성
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o /app/server .

# 2. 최종 실행 스테이지
FROM scratch

# 빌더 스테이지에서 생성된 실행 파일만 복사
COPY --from=builder /app/server /server

# 실행 포트 노출
EXPOSE 8000

# Container 실행 명령어
CMD ["/server"]
