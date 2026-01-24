#!/bin/bash
ASG_NAME="channeling-asg"

# 현재 실행 중인 ASG 인스턴스 IP 가져오기
INSTANCE_IPS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PrivateIpAddress' \
  --output text | tr '\t' '\n' | sort | tr '\n' ' ')

# 현재 nginx.conf의 upstream IP 목록 추출
CURRENT_IPS=$(grep -E "server [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /etc/nginx/nginx.conf | awk '{print $2}' | cut -d: -f1 | sort | tr '\n' ' ')

# IP 목록이 변경되었는지 확인
if [ "$INSTANCE_IPS" = "$CURRENT_IPS" ]; then
  echo "[$(date)] No changes in backend instances"
  exit 0
fi

echo "[$(date)] Backend instances changed. Updating nginx config..."
echo "[$(date)] Current IPs: $CURRENT_IPS"
echo "[$(date)] New IPs: $INSTANCE_IPS"

# S3에서 최신 템플릿 다운로드 (원본 유지)
aws s3 cp s3://channeling-bucket/deploy-configs/nginx.conf /tmp/nginx.conf.template 2>/dev/null || {
  echo "[$(date)] ❌ Failed to download template from S3"
  exit 1
}

# upstream 블록 동적 생성
UPSTREAM_BLOCK="    # Upstream - Spring Boot 서버들 (ASG)\n    upstream backend {\n        least_conn;\n\n"
for IP in $INSTANCE_IPS; do
  if [ ! -z "$IP" ]; then
    UPSTREAM_BLOCK="${UPSTREAM_BLOCK}        server ${IP}:8080 max_fails=3 fail_timeout=30s;\n"
  fi
done
UPSTREAM_BLOCK="${UPSTREAM_BLOCK}    }"

# nginx.conf 업데이트
sed -n '1,25p' /tmp/nginx.conf.template > /tmp/nginx.conf.new
echo -e "$UPSTREAM_BLOCK" >> /tmp/nginx.conf.new
sed -n '34,$p' /tmp/nginx.conf.template >> /tmp/nginx.conf.new

# 설정 테스트 (에러 메시지 출력)
if nginx -t -c /tmp/nginx.conf.new 2>&1 | tee -a /var/log/nginx-upstream-update.log; then
  mv /tmp/nginx.conf.new /etc/nginx/nginx.conf
  systemctl reload nginx
  echo "[$(date)] ✅ Nginx reloaded with new backends: ${INSTANCE_IPS}"
else
  echo "[$(date)] ❌ Nginx config test failed"
  echo "[$(date)] Generated config:"
  cat /tmp/nginx.conf.new | head -40
  rm /tmp/nginx.conf.new
  exit 1
fi
