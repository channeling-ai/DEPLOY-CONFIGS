#!/bin/bash
set -e

# 로깅 설정
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=========================================="
echo "Nginx + CI/CD Server Setup Started: $(date)"
echo "=========================================="

# ============================================
# 1. Nginx 설치
# ============================================
echo "Installing Nginx..."
sudo yum install -y nginx

# S3에서 Nginx 설정 템플릿 다운로드
echo "Downloading Nginx config template from S3..."
aws s3 cp s3://channeling-bucket/deploy-configs/nginx.conf /tmp/nginx.conf.template || {
  echo "❌ Failed to download nginx.conf"
  exit 1
}

# ASG 이름 설정 
ASG_NAME="channeling-asg"

# ASG에서 실행 중인 인스턴스의 Private IP 가져오기
echo "Fetching ASG instance IPs..."
INSTANCE_IPS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text)

if [ -z "$INSTANCE_IPS" ]; then
  echo "⚠️  No running instances found in ASG. Using template as-is."
  cp /tmp/nginx.conf.template /etc/nginx/nginx.conf
else
  echo "Found instances:"
  echo "$INSTANCE_IPS" | tr ' ' '\n' | sed 's/^/  - /'

  # upstream 블록 동적 생성
  UPSTREAM_BLOCK="    # Upstream - Spring Boot 서버들 (ASG)\n    upstream backend {\n        least_conn;\n\n"
  for IP in $INSTANCE_IPS; do
    UPSTREAM_BLOCK="${UPSTREAM_BLOCK}        server ${IP}:8080 max_fails=3 fail_timeout=30s;\n"
  done
  UPSTREAM_BLOCK="${UPSTREAM_BLOCK}    }"

  # 템플릿에서 기존 upstream 블록을 새로 생성한 블록으로 교체
  sed -n '1,25p' /tmp/nginx.conf.template > /etc/nginx/nginx.conf
  echo -e "$UPSTREAM_BLOCK" >> /etc/nginx/nginx.conf
  sed -n '34,$p' /tmp/nginx.conf.template >> /etc/nginx/nginx.conf

  echo "✅ Nginx config generated with ${INSTANCE_IPS} backend IPs"
fi

# Nginx 시작
systemctl start nginx
systemctl enable nginx

echo "✅ Nginx installed and configured"

# ============================================
# 2. Cloudflare Tunnel 실행 (Docker)
# ============================================
echo "Starting Cloudflare Tunnel..."

# Docker 서비스 확인 및 시작
systemctl is-active docker || systemctl start docker
systemctl enable docker

# Cloudflare Tunnel을 Docker로 실행
docker run -d \
  --name cloudflare-tunnel \
  --restart unless-stopped \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate run --token eyJhIjoiM2FhNmJmMjU1NzdmMDQ1OThhMjYyMGEwMzg4OWVkMzYiLCJ0IjoiNDU4NjhlYzEtOWIwNS00ODI4LTllMGQtMzc0Y2U1ODU5NWFmIiwicyI6Ik1tTXdNbUl5TW1VdE5qWXdaUzAwWkRFekxUaGtOelF0WXprMk9HUm1PREl3WkdNMSJ9

# 상태 확인
sleep 5
if docker ps | grep -q cloudflare-tunnel; then
  echo "✅ Cloudflare Tunnel is running"
  docker logs cloudflare-tunnel --tail 10
else
  echo "❌ Cloudflare Tunnel failed to start"
  docker logs cloudflare-tunnel
fi

# ============================================
# 3. GitHub Actions Self-hosted Runner 설치
# ============================================
echo "Setting up GitHub Actions Runner..."

# ec2-user 홈 디렉토리에 설치
cd /home/ec2-user
mkdir -p actions-runner
cd actions-runner

# Runner 다운로드
curl -o actions-runner-linux-x64-2.329.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.329.0/actions-runner-linux-x64-2.329.0.tar.gz

# 압축 해제
tar xzf ./actions-runner-linux-x64-2.329.0.tar.gz
rm -f actions-runner-linux-x64-2.329.0.tar.gz

# 소유권 변경
chown -R ec2-user:ec2-user /home/ec2-user/actions-runner

# ec2-user를 docker 그룹에 추가
usermod -aG docker ec2-user

echo "✅ GitHub Actions Runner downloaded"



# ============================================
# 4. 필요한 추가 패키지 설치
# ============================================
echo "Installing additional packages..."

# Git, jq, cronie 설치
sudo yum install -y git jq cronie

# crond 서비스 시작 및 활성화
systemctl start crond
systemctl enable crond

echo "✅ Additional packages installed"

# ============================================
# 5. Nginx Upstream 자동 업데이트 스크립트 설정
# ============================================
echo "Setting up auto-update script for Nginx upstream..."

# 업데이트 스크립트 생성
cat > /usr/local/bin/update-nginx-upstream.sh <<'SCRIPT_END'
#!/bin/bash
ASG_NAME="channeling-asg"

# 현재 실행 중인 ASG 인스턴스 IP 가져오기
INSTANCE_IPS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '\t' '\n' | sort | tr '\n' ' ')

# 현재 nginx.conf의 upstream backend IP 목록 추출
CURRENT_IPS=$(awk '/upstream backend/,/^    }/ {if (/server [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) print $2}' /etc/nginx/nginx.conf | cut -d: -f1 | sort | tr '\n' ' ')

# IP 목록이 변경되었는지 확인
if [ "$INSTANCE_IPS" = "$CURRENT_IPS" ]; then
  echo "[$(date)] No changes in backend instances"
  exit 0
fi

echo "[$(date)] Backend instances changed. Updating nginx config..."
echo "[$(date)] Current IPs: $CURRENT_IPS"
echo "[$(date)] New IPs: $INSTANCE_IPS"

# health check 통과한 인스턴스만 필터링
HEALTHY_IPS=""
HEALTHY_COUNT=0
for IP in $INSTANCE_IPS; do
  if [ ! -z "$IP" ]; then
    if curl -sf --max-time 3 "http://${IP}:8080/actuator/health" > /dev/null 2>&1; then
      HEALTHY_IPS="${HEALTHY_IPS} ${IP}"
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
      echo "[$(date)] ✅ Health check passed: ${IP}"
    else
      echo "[$(date)] ⏳ Health check failed, skipping: ${IP}"
    fi
  fi
done

# healthy 인스턴스가 없으면 업데이트 중단
if [ "$HEALTHY_COUNT" -eq 0 ]; then
  echo "[$(date)] ❌ No healthy instances found. Keeping current config."
  exit 0
fi

# upstream backend 블록 동적 생성 (8080 포트)
UPSTREAM_BACKEND="    # Upstream - Spring Boot 서버들 (ASG)\n    upstream backend {\n        least_conn;\n"
for IP in $HEALTHY_IPS; do
  if [ ! -z "$IP" ]; then
    UPSTREAM_BACKEND="${UPSTREAM_BACKEND}        server ${IP}:8080 max_fails=3 fail_timeout=30s;\n"
  fi
done
UPSTREAM_BACKEND="${UPSTREAM_BACKEND}    }"

# upstream sse_backend 블록 동적 생성 (8081 포트)
UPSTREAM_SSE="    # 새로 추가 — SSE 서버 (8081)\n    upstream sse_backend {\n        least_conn;\n"
for IP in $HEALTHY_IPS; do
  if [ ! -z "$IP" ]; then
    UPSTREAM_SSE="${UPSTREAM_SSE}        server ${IP}:8081 max_fails=3 fail_timeout=30s;\n"
  fi
done
UPSTREAM_SSE="${UPSTREAM_SSE}    }"

# 현재 nginx.conf를 백업
cp /etc/nginx/nginx.conf /tmp/nginx.conf.backup

# 두 upstream 블록 모두 교체
awk -v backend="$UPSTREAM_BACKEND" -v sse="$UPSTREAM_SSE" '
BEGIN { in_backend=0; in_sse=0 }

/# Upstream - Spring Boot/ {
    print backend
    in_backend=1
    next
}

/# 새로 추가 — SSE/ {
    print sse
    in_sse=1
    next
}

/^    }/ && in_backend {
    in_backend=0
    next
}

/^    }/ && in_sse {
    in_sse=0
    next
}

!in_backend && !in_sse { print }
' /etc/nginx/nginx.conf > /tmp/nginx.conf.new

# 설정 테스트
if nginx -t -c /tmp/nginx.conf.new 2>&1 | tee -a /var/log/nginx-upstream-update.log; then
  mv /tmp/nginx.conf.new /etc/nginx/nginx.conf
  systemctl reload nginx
  echo "[$(date)] ✅ Nginx reloaded with new backends (8080) and SSE backends (8081): ${HEALTHY_IPS}"
else
  echo "[$(date)] ❌ Nginx config test failed"
  echo "[$(date)] Generated config:"
  cat /tmp/nginx.conf.new | head -60
  rm /tmp/nginx.conf.new
  # 백업에서 복구
  mv /tmp/nginx.conf.backup /etc/nginx/nginx.conf
  exit 1
fi

# 백업 파일 정리
rm -f /tmp/nginx.conf.backup
SCRIPT_END

chmod +x /usr/local/bin/update-nginx-upstream.sh

# Cron 작업 등록 (30초마다 체크)
(echo "* * * * * /usr/local/bin/update-nginx-upstream.sh >> /var/log/nginx-upstream-update.log 2>&1"
echo "* * * * * sleep 30 && /usr/local/bin/update-nginx-upstream.sh >> /var/log/nginx-upstream-update.log 2>&1") | crontab -

echo "✅ Auto-update script configured (runs every 30 seconds)"

# ============================================
# 6. 상태 확인
# ============================================
echo "=========================================="
echo "Setup Summary:"
echo "=========================================="
echo "✅ Nginx: $(nginx -v 2>&1)"
echo "✅ Docker: $(docker --version)"
echo "✅ Docker Compose: $(docker-compose --version)"
echo "✅ AWS CLI: $(aws --version)"
echo "✅ Git: $(git --version)"
echo "✅ Cloudflare Tunnel: $(docker ps --filter name=cloudflare-tunnel --format '{{.Status}}')"
echo "✅ GitHub Runner: Ready for configuration"
echo ""
echo "Configuration files:"
echo "  - Nginx config: /etc/nginx/nginx.conf (from S3)"
echo ""
echo "Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo ""
echo "=========================================="
echo "Setup Completed: $(date)"
echo "=========================================="
