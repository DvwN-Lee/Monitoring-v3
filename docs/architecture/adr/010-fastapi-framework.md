# ADR-010: Python FastAPI Framework 선택

**날짜**: 2025-12-19

---

## 상황 (Context)

3개 Backend Service(auth-service, user-service, blog-service)의 Web Framework를 선택해야 한다. Monitoring-v2에서는 Flask를 사용했으나, v3에서는 비동기 I/O 지원과 자동 API 문서화가 필요하다.

## 결정 (Decision)

Python FastAPI를 Backend Service Framework로 사용한다. ASGI 서버로 Uvicorn을 사용하고, 비동기 Database 접근을 위해 asyncpg(PostgreSQL)와 redis(async mode, `redis[hiredis]`)를 활용한다.

## 이유 (Rationale)

| 항목 | Flask | Django | FastAPI |
|------|-------|--------|---------|
| 비동기 지원 | WSGI (동기) | ASGI (3.1+, 부분적) | ASGI (네이티브 async/await) |
| API 문서 | 수동 (Swagger 별도) | DRF + Swagger | 자동 생성 (OpenAPI) |
| 성능 | 보통 | 보통 | 높음 (Starlette 기반) |
| 타입 검증 | 수동 | Serializer | Pydantic 자동 검증 |
| 학습 곡선 | 낮음 | 높음 (ORM, Admin 등) | 중간 |
| Prometheus 통합 | 수동 구현 | 수동 구현 | `prometheus-fastapi-instrumentator` |

FastAPI는 네이티브 async/await를 지원하여 PostgreSQL(asyncpg)과 Redis(`redis[hiredis]` async mode) 연동 시 비동기 I/O의 이점을 활용할 수 있다. Pydantic 기반 자동 타입 검증과 OpenAPI 문서 자동 생성이 개발 생산성을 높인다.

`prometheus-fastapi-instrumentator` 라이브러리를 통해 `/metrics` Endpoint를 자동 생성하며, Prometheus ServiceMonitor와의 통합이 간편하다.

### Microservice별 FastAPI 활용

| Service | 주요 의존성 | Port |
|---------|-----------|------|
| auth-service | PyJWT, cryptography, slowapi | 8002 |
| user-service | asyncpg, redis, argon2-cffi | 8001 |
| blog-service | SQLAlchemy, asyncpg, redis, Jinja2, Alembic | 8005 |

## 결과 (Consequences)

### 긍정적 측면
- 비동기 I/O로 DB/Cache 접근 시 동시 처리량 향상
- Pydantic 기반 Request/Response 자동 검증
- OpenAPI 문서 자동 생성으로 API 테스트 편의성 향상
- Prometheus Metrics 자동 수집 (instrumentator)
- Rate Limiting (slowapi) 내장 지원

### 부정적 측면 (Trade-offs)
- Flask 대비 생태계가 작음 (확장 라이브러리 수)
- async 코드의 디버깅 복잡도 증가
- Django 대비 ORM, Admin, Migration 등을 별도 라이브러리(SQLAlchemy, Alembic)로 구성해야 함
