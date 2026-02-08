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
