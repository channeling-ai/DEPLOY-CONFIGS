#!/bin/bash
set -e

# 로깅 설정
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=========================================="
echo "User Data Started: $(date)"
echo "=========================================="

# 앱 디렉토리 생성
mkdir -p /home/ec2-user/app
cd /home/ec2-user/app

# S3에서 설정 파일 다운로드
echo "Downloading config files from S3..."
aws s3 cp s3://channeling-bucket/deploy-configs/docker-compose.yml . || {
  echo "❌ Failed to download docker-compose.yml"
  exit 1
}

aws s3 cp s3://channeling-bucket/deploy-configs/.env . || {
  echo "❌ Failed to download .env"
  exit 1
}

# CRLF를 LF로 변환 (Windows 파일 대비)
sed -i 's/\r$//' .env
sed -i 's/\r$//' docker-compose.yml

# Docker 서비스 시작
systemctl is-active docker || systemctl start docker
systemctl enable docker

# 환경변수 로드
source .env

# Docker 로그인
echo "Logging in to DockerHub..."
echo "${DOCKER_ACCESS_TOKEN}" | docker login -u "${DOCKER_USERNAME}" --password-stdin || {
  echo "❌ Docker login failed"
  exit 1
}

# 이미지 Pull
echo "Pulling Docker images..."
docker-compose pull || {
  echo "❌ Failed to pull images"
  exit 1
}

# 컨테이너 시작
echo "Starting services..."
docker-compose up -d || {
  echo "❌ Failed to start containers"
  docker-compose logs
  exit 1
}

# 헬스체크 대기 (Spring Boot) - 10분
echo "Waiting for Spring Boot to be healthy..."
SPRING_HEALTHY=false
for i in {1..120}; do
  if curl -f http://localhost:8080/actuator/health 2>/dev/null; then
    echo "✅ Spring Boot is healthy! (attempt $i)"
    SPRING_HEALTHY=true
    break
  fi
  echo "Spring Boot health check attempt $i/120..."
  sleep 5
done

if [ "$SPRING_HEALTHY" = false ]; then
  echo "❌ Spring Boot health check failed after 10 minutes"
  docker-compose logs spring-app
  exit 1
fi

# 헬스체크 대기 (FastAPI) - 10분
echo "Waiting for FastAPI to be healthy..."
FASTAPI_HEALTHY=false
for i in {1..120}; do
  if curl -f http://localhost:8000/health 2>/dev/null; then
    echo "✅ FastAPI is healthy! (attempt $i)"
    FASTAPI_HEALTHY=true
    break
  fi
  echo "FastAPI health check attempt $i/120..."
  sleep 5
done

if [ "$FASTAPI_HEALTHY" = false ]; then
  echo "❌ FastAPI health check failed after 10 minutes"
  docker-compose logs fastapi-app
  exit 1
fi

# 권한 설정
chown -R ec2-user:ec2-user /home/ec2-user/app

echo "=========================================="
echo "✅ All services are healthy!"
echo "User Data Completed: $(date)"
echo "=========================================="
