# Loki + Grafana 로깅 시스템 구축 가이드

## 개요

모든 서비스의 로그를 중앙 집중화하여 Grafana에서 조회/분석할 수 있는 로깅 시스템 구축

### 아키텍처

```
┌─────────────────────────────────────┐     ┌─────────────────────────────────┐
│         API 서버 (오토스케일링)        │     │       DB 서버 (고정)              │
│                                     │     │                                 │
│  ┌───────────┐  ┌───────────┐       │     │  ┌──────┐     ┌─────────┐      │
│  │spring-app │  │fastapi-app│       │     │  │ Loki │ ◀── │ Grafana │      │
│  └─────┬─────┘  └─────┬─────┘       │     │  └──▲───┘     └─────────┘      │
│        │              │             │     │     │                          │
│        ▼              ▼             │     │     │                          │
│  ┌─────────────────────────┐        │     │     │                          │
│  │       Promtail          │ ───────────────────┘                          │
│  │  (로그 수집 → Loki 전송)  │        │     │                                 │
│  └─────────────────────────┘        │     │  ┌──────────┐  ┌───────┐       │
│                                     │     │  │PostgreSQL│  │ Redis │       │
└─────────────────────────────────────┘     │  └──────────┘  └───────┘       │
                                            └─────────────────────────────────┘
```

**핵심 포인트:**
- **Loki/Grafana**: DB 서버에 배치 (오토스케일링 영향 없음, 로그 데이터 영구 보존)
- **Promtail**: API 서버에 배치 (컨테이너 로그 수집 → DB 서버 Loki로 전송)

### 로깅 대상 서비스
| 서비스 | 컨테이너명 | 타입 | 로그 포맷 |
|--------|------------|------|-----------|
| Spring Backend | spring-app | Spring Boot 3.5.3 | JSON |
| FastAPI | fastapi-app | FastAPI | JSON |
| Overview Consumer | overview-consumer | Kafka Worker | JSON |
| Analysis Consumer | analysis-consumer | Kafka Worker | JSON |
| Idea Consumer | idea-consumer | Kafka Worker | JSON |
| SSE Server | sse-app | Spring Boot 3.5.8 | JSON |

---

## 1. 인프라 구성 (DEPLOY-CONFIGS)

### 1.1 DB 서버 docker-compose.yml (db-docker-compose.yml)

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:17.4
    container_name: postgres
    # ... (기존 설정)

  redis:
    image: redis:7-alpine
    container_name: redis
    # ... (기존 설정)

  # ===== Logging Infrastructure =====
  loki:
    image: grafana/loki:2.9.0
    container_name: loki
    ports:
      - "3100:3100"
    command: -config.file=/etc/loki/local-config.yaml
    volumes:
      - loki-data:/loki
    restart: unless-stopped

  grafana:
    image: grafana/grafana:10.2.0
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana-data:/var/lib/grafana
    restart: unless-stopped
    depends_on:
      - loki

volumes:
  loki-data:
  grafana-data:
```

### 1.2 API 서버 docker-compose.yml (promtail 부분)

```yaml
  # ===== Logging (Promtail -> DB서버 Loki) =====
  promtail:
    image: grafana/promtail:2.9.0
    container_name: promtail
    volumes:
      - ./promtail-config.yml:/etc/promtail/config.yml
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
    command: -config.file=/etc/promtail/config.yml
    networks:
      - app-network
    restart: unless-stopped
```

### 1.3 promtail-config.yml (API 서버용)

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://<DB서버_프라이빗_IP>:3100/loki/api/v1/push  

scrape_configs:
  - job_name: docker
    static_configs:
      - targets:
          - localhost
        labels:
          job: docker
          __path__: /var/lib/docker/containers/*/*-json.log
    pipeline_stages:
      - json:
          expressions:
            log: log
            attrs: attrs
      - json:
          expressions:
            container: tag
          source: attrs
      - labels:
          container:
      - output:
          source: log
```

### 1.4 디렉토리 구조

```
DEPLOY-CONFIGS/
├── docker-compose.yml        # API 서버용 (promtail 포함)
├── db-docker-compose.yml     # DB 서버용 (loki, grafana 포함)
├── promtail-config.yml       # Promtail 설정 (S3에 업로드)
├── asg-userdata.sh           # ASG 시작 스크립트
└── docs/
    └── logging-setup.md
```

### 1.5 보안그룹 설정

**DB 서버 보안그룹 인바운드 규칙:**
| 포트 | 소스 | 용도 |
|------|------|------|
| 3100 | API 서버 asg 보안그룹 | Promtail → Loki |
| 3000 | API 서버 asg 보안그룹 | Grafana 접속 |

---

## 2. 배포 설정

### 2.1 S3 업로드 파일

```bash
aws s3 cp docker-compose.yml s3://channeling-bucket/deploy-configs/
aws s3 cp promtail-config.yml s3://channeling-bucket/deploy-configs/
aws s3 cp .env s3://channeling-bucket/deploy-configs/
```

---

## 4. Grafana에서 로그 조회하기

### 4.1 접속 방법

```bash
# 로컬에서 포트포워딩 (배스천 경유)
ssh -L 3000:<DB_프라이빗_IP>:3000 -i <키페어 이름> ec2-user@<배스천_퍼블릭_IP>
```

브라우저에서 http://localhost:3000 접속
- 계정: admin / admin

### 4.2 Data Source 설정

1. 좌측 메뉴 → **Connections** → **Data sources**
2. **Add data source** → **Loki** 선택
3. URL: `http://loki:3100`
4. **Save & test**

### 4.3 기본 쿼리 (LogQL)

**컨테이너별 로그 조회:**
```logql
{container="spring-app"}
{container="fastapi-app"}
{container="overview-consumer"}
{container="analysis-consumer"}
{container="idea-consumer"}
{container="sse-app"}
```

**여러 컨테이너 동시 조회:**
```logql
{container=~"spring-app|fastapi-app|sse-app"}
```

**JSON 필드 파싱 및 필터링:**
```logql
{container="spring-app"} | json | level="ERROR"
{container="spring-app"} | json | level=~"ERROR|WARN"
{container="fastapi-app"} | json | message=~".*Kafka.*"
```

---

## 5. 레포별 변경 파일 요약

### DEPLOY-CONFIGS
- `docker-compose.yml` - promtail만 포함 (loki, grafana 제거)
- `db-docker-compose.yml` - loki, grafana 추가 (DB 서버용)
- `promtail-config.yml` - DB 서버 Loki로 전송하도록 URL 변경
- `asg-userdata.sh` - promtail-config.yml S3 다운로드 추가

### BE (channeling-be)
- `build.gradle` - logstash-logback-encoder, discord-appender 의존성 추가
- `src/main/resources/logback-spring.xml` - JSON 로깅 + Discord 에러 알림 설정

### LLM (channeling-llm)
- `core/config/logging_config.py` - 신규 생성
- `main.py` - setup_logging() 호출 추가
- `kafka_*_consumer.py` - setup_logging() 호출 추가

### SSE (channeling-sse)
- `build.gradle` - logstash-logback-encoder 의존성 추가
- `src/main/resources/logback-spring.xml` - 신규 생성
