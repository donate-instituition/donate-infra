#!/bin/bash
set -o pipefail

# =============================================================================
# EC2 User Data Bootstrap Script
# Environment: ${environment} | Region: ${aws_region} | Domain: ${domain_name}
# =============================================================================

LOG_FILE="/var/log/user-data.log"
STATUS_FILE="/opt/elodoar/bootstrap-status.json"
COMPOSE_DIR="/opt/elodoar"
ENV_FILE="/root/.env"

# Track step results for final status
declare -A STEP_STATUS
declare -A STEP_DURATION
OVERALL_STATUS="success"
CRITICAL_FAILURE=false

# -----------------------------------------------------------------------------
# Logging helper
# -----------------------------------------------------------------------------
log() {
  local level="$${1}"
  local step="$${2}"
  local message="$${3}"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$${level}] [$${step}] $${message}" | tee -a "$${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# Step execution wrapper
# -----------------------------------------------------------------------------
run_step() {
  local step_name="$${1}"
  local step_func="$${2}"
  local start_time end_time duration_ms

  start_time=$(date +%s%N)
  log "INFO" "$${step_name}" "Starting step..."

  if $${step_func}; then
    end_time=$(date +%s%N)
    duration_ms=$(( (end_time - start_time) / 1000000 ))
    STEP_STATUS["$${step_name}"]="success"
    STEP_DURATION["$${step_name}"]="$${duration_ms}"
    log "INFO" "$${step_name}" "Completed successfully in $${duration_ms}ms"
    return 0
  else
    local exit_code=$$?
    end_time=$(date +%s%N)
    duration_ms=$(( (end_time - start_time) / 1000000 ))
    STEP_STATUS["$${step_name}"]="failed"
    STEP_DURATION["$${step_name}"]="$${duration_ms}"
    OVERALL_STATUS="partial"
    log "ERROR" "$${step_name}" "Failed with exit code $${exit_code} after $${duration_ms}ms"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Step 1: Install Docker Engine and Docker Compose plugin
# -----------------------------------------------------------------------------
step_docker_install() {
  log "INFO" "docker_install" "Installing Docker Engine and Compose plugin..."

  dnf install -y docker >> "$${LOG_FILE}" 2>&1 || return 1

  # Add docker group (already exists after install, but ensure)
  groupadd -f docker >> "$${LOG_FILE}" 2>&1

  # Start and enable Docker service
  systemctl start docker >> "$${LOG_FILE}" 2>&1 || return 1
  systemctl enable docker >> "$${LOG_FILE}" 2>&1 || return 1

  # Install Docker Compose plugin
  mkdir -p /usr/local/lib/docker/cli-plugins
  COMPOSE_VERSION="v2.29.2"
  curl -fsSL "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose >> "$${LOG_FILE}" 2>&1 || return 1
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

  # Verify installations
  docker --version >> "$${LOG_FILE}" 2>&1 || return 1
  docker compose version >> "$${LOG_FILE}" 2>&1 || return 1

  log "INFO" "docker_install" "Docker and Compose plugin installed successfully"
  return 0
}

# -----------------------------------------------------------------------------
# Step 2: Install and configure CloudWatch Agent
# -----------------------------------------------------------------------------
step_cloudwatch_agent() {
  log "INFO" "cloudwatch_agent" "Installing CloudWatch Agent..."

  dnf install -y amazon-cloudwatch-agent >> "$${LOG_FILE}" 2>&1 || return 1

  # Write CloudWatch Agent configuration
  cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/lib/docker/containers/**/*-json.log",
            "log_group_name": "/elodoar/${environment}/ec2",
            "log_stream_name": "docker-containers",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%fZ"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/elodoar/${environment}/ec2",
            "log_stream_name": "system",
            "timestamp_format": "%Y-%m-%dT%H:%M:%SZ"
          },
          {
            "file_path": "/var/log/dnf-automatic.log",
            "log_group_name": "/elodoar/${environment}/ec2",
            "log_stream_name": "system",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "Elodoar/${environment}",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      }
    }
  }
}
CWCONFIG

  # Start CloudWatch Agent with the configuration
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
    -s >> "$${LOG_FILE}" 2>&1 || return 1

  log "INFO" "cloudwatch_agent" "CloudWatch Agent configured and started"
  return 0
}

# -----------------------------------------------------------------------------
# Step 3: Authenticate to ECR and pull latest images
# -----------------------------------------------------------------------------
step_ecr_pull() {
  local max_retries=3
  local retry_interval=10
  local attempt=0
  local account_id

  log "INFO" "ecr_pull" "Authenticating to ECR..."

  # Get AWS account ID
  account_id=$(aws sts get-caller-identity --query Account --output text --region ${aws_region} 2>> "$${LOG_FILE}") || {
    log "ERROR" "ecr_pull" "Failed to get AWS account ID"
    return 1
  }

  local ecr_endpoint="$${account_id}.dkr.ecr.${aws_region}.amazonaws.com"

  # Authenticate to ECR with retries
  while [ $${attempt} -lt $${max_retries} ]; do
    attempt=$((attempt + 1))
    log "INFO" "ecr_pull" "ECR login attempt $${attempt}/$${max_retries}..."

    if aws ecr get-login-password --region ${aws_region} 2>> "$${LOG_FILE}" | \
       docker login --username AWS --password-stdin "$${ecr_endpoint}" >> "$${LOG_FILE}" 2>&1; then
      log "INFO" "ecr_pull" "ECR authentication successful"
      break
    fi

    if [ $${attempt} -lt $${max_retries} ]; then
      log "WARN" "ecr_pull" "ECR login failed, retrying in $${retry_interval}s..."
      sleep $${retry_interval}
    else
      log "ERROR" "ecr_pull" "ECR authentication failed after $${max_retries} attempts"
      return 1
    fi
  done

  # Pull latest images
  log "INFO" "ecr_pull" "Pulling donate-server image..."
  docker pull "$${ecr_endpoint}/elodoar/donate-server:latest" >> "$${LOG_FILE}" 2>&1 || {
    log "ERROR" "ecr_pull" "Failed to pull donate-server image"
    return 1
  }

  log "INFO" "ecr_pull" "Pulling donate-workers image..."
  docker pull "$${ecr_endpoint}/elodoar/donate-workers:latest" >> "$${LOG_FILE}" 2>&1 || {
    log "ERROR" "ecr_pull" "Failed to pull donate-workers image"
    return 1
  }

  log "INFO" "ecr_pull" "All images pulled successfully"
  return 0
}

# -----------------------------------------------------------------------------
# Step 4: Retrieve SSM parameters and generate /root/.env
# -----------------------------------------------------------------------------
step_ssm_secrets() {
  local max_retries=3
  local retry_interval=5
  local attempt=0
  local ssm_output

  log "INFO" "ssm_secrets" "Retrieving secrets from SSM Parameter Store..."

  while [ $${attempt} -lt $${max_retries} ]; do
    attempt=$((attempt + 1))
    log "INFO" "ssm_secrets" "SSM retrieval attempt $${attempt}/$${max_retries}..."

    ssm_output=$(aws ssm get-parameters-by-path \
      --path "/elodoar/${environment}/" \
      --with-decryption \
      --region ${aws_region} \
      --query "Parameters[*].[Name,Value]" \
      --output text 2>> "$${LOG_FILE}")

    if [ $$? -eq 0 ] && [ -n "$${ssm_output}" ]; then
      log "INFO" "ssm_secrets" "SSM parameters retrieved successfully"
      break
    fi

    if [ $${attempt} -lt $${max_retries} ]; then
      log "WARN" "ssm_secrets" "SSM retrieval failed, retrying in $${retry_interval}s..."
      sleep $${retry_interval}
    else
      log "ERROR" "ssm_secrets" "SSM parameter retrieval failed after $${max_retries} attempts"
      return 1
    fi
  done

  # Parse SSM output and write .env file
  log "INFO" "ssm_secrets" "Writing environment file..."

  # Start with non-secret environment variables
  cat > "$${ENV_FILE}" <<EOF
# Generated by user-data bootstrap script at $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Environment: ${environment}
DOMAIN_NAME=${domain_name}
NODE_ENV=production
RABBITMQ_DEFAULT_USER=elodoar
EOF

  # Parse SSM parameters (format: /elodoar/{env}/KEY\tVALUE)
  while IFS=$'\t' read -r param_name param_value; do
    if [ -n "$${param_name}" ] && [ -n "$${param_value}" ]; then
      # Extract key name from full path (e.g., /elodoar/production/MONGODB_URI → MONGODB_URI)
      local key_name
      key_name=$(echo "$${param_name}" | awk -F'/' '{print $NF}')
      echo "$${key_name}=$${param_value}" >> "$${ENV_FILE}"
    fi
  done <<< "$${ssm_output}"

  # Set strict permissions: only root can read
  chmod 600 "$${ENV_FILE}"
  chown root:root "$${ENV_FILE}"

  log "INFO" "ssm_secrets" "Environment file written to $${ENV_FILE} with permissions 600"
  return 0
}

# -----------------------------------------------------------------------------
# Step 5: Install dnf-automatic for security patches
# -----------------------------------------------------------------------------
step_dnf_automatic() {
  log "INFO" "dnf_automatic" "Installing and configuring dnf-automatic..."

  dnf install -y dnf-automatic >> "$${LOG_FILE}" 2>&1 || return 1

  # Configure dnf-automatic for security-only updates
  cat > /etc/dnf/automatic.conf <<'DNFCONF'
[commands]
upgrade_type = security
random_sleep = 10800
apply_updates = yes
download_updates = yes

[emitters]
emit_via = stdio

[command]
command_format = cat

[command_email]
email_from = root@localhost
email_to = root@localhost
DNFCONF

  # Enable and start the timer
  systemctl enable dnf-automatic-install.timer >> "$${LOG_FILE}" 2>&1 || return 1
  systemctl start dnf-automatic-install.timer >> "$${LOG_FILE}" 2>&1 || return 1

  log "INFO" "dnf_automatic" "dnf-automatic configured for security updates (randomized 02:00-05:00 UTC)"
  return 0
}

# -----------------------------------------------------------------------------
# Step 6: Deploy Docker Compose stack
# -----------------------------------------------------------------------------
step_compose_start() {
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text --region ${aws_region} 2>> "$${LOG_FILE}") || {
    log "ERROR" "compose_start" "Failed to get AWS account ID"
    return 1
  }

  local ecr_endpoint="$${account_id}.dkr.ecr.${aws_region}.amazonaws.com"

  log "INFO" "compose_start" "Setting up Docker Compose stack..."

  # Create application directory
  mkdir -p "$${COMPOSE_DIR}"

  # Write docker-compose.prod.yml
  cat > "$${COMPOSE_DIR}/docker-compose.prod.yml" <<COMPOSEFILE
services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $${COMPOSE_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - frontend
      - backend
    depends_on:
      donate-server:
        condition: service_healthy
    environment:
      - DOMAIN_NAME=${domain_name}
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:80"]
      interval: 30s
      timeout: 10s
      retries: 3

  donate-server:
    image: $${ecr_endpoint}/elodoar/donate-server:latest
    container_name: donate-server
    restart: unless-stopped
    env_file: /root/.env
    networks:
      - frontend
      - backend
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  donate-workers-email:
    image: $${ecr_endpoint}/elodoar/donate-workers:latest
    container_name: donate-workers-email
    restart: unless-stopped
    env_file: /root/.env
    environment:
      - WORKER_NAME=email
    networks:
      - backend
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f node || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  donate-workers-stripe-webhook:
    image: $${ecr_endpoint}/elodoar/donate-workers:latest
    container_name: donate-workers-stripe-webhook
    restart: unless-stopped
    env_file: /root/.env
    environment:
      - WORKER_NAME=stripe-webhook
    networks:
      - backend
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f node || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  donate-workers-receipt-generate:
    image: $${ecr_endpoint}/elodoar/donate-workers:latest
    container_name: donate-workers-receipt-generate
    restart: unless-stopped
    env_file: /root/.env
    environment:
      - WORKER_NAME=receipt-generate
    networks:
      - backend
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f node || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  donate-workers-notification-push:
    image: $${ecr_endpoint}/elodoar/donate-workers:latest
    container_name: donate-workers-notification-push
    restart: unless-stopped
    env_file: /root/.env
    environment:
      - WORKER_NAME=notification-push
    networks:
      - backend
    depends_on:
      redis:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f node || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    command: >
      redis-server
      --requirepass \$${REDIS_PASSWORD}
      --maxmemory 256mb
      --maxmemory-policy allkeys-lru
    env_file: /root/.env
    volumes:
      - redis-data:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\$${REDIS_PASSWORD}", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

  rabbitmq:
    image: rabbitmq:4-alpine
    container_name: rabbitmq
    restart: unless-stopped
    environment:
      - RABBITMQ_DEFAULT_USER=elodoar
      - RABBITMQ_DEFAULT_PASS=\$${RABBITMQ_DEFAULT_PASS}
    env_file: /root/.env
    volumes:
      - rabbitmq-data:/var/lib/rabbitmq
    networks:
      - backend
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge

volumes:
  caddy-data:
  caddy-config:
  redis-data:
  rabbitmq-data:
COMPOSEFILE

  # Write Caddyfile
  cat > "$${COMPOSE_DIR}/Caddyfile" <<'CADDYFILE'
{$DOMAIN_NAME} {
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }

    reverse_proxy donate-server:3000 {
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            read_timeout 300s
        }
    }
}
CADDYFILE

  # Write deploy script for future use
  cat > "$${COMPOSE_DIR}/deploy.sh" <<'DEPLOYSCRIPT'
#!/bin/bash
set -o pipefail

IMAGE_TAG="$${1}"
COMPOSE_DIR="/opt/elodoar"
COMPOSE_FILE="$${COMPOSE_DIR}/docker-compose.prod.yml"
PREVIOUS_DEPLOY_FILE="$${COMPOSE_DIR}/previous-deploy.env"
DEPLOY_LOG="/var/log/user-data.log"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] [deploy] $${1}" | tee -a "$${DEPLOY_LOG}"
}

error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] [deploy] $${1}" | tee -a "$${DEPLOY_LOG}"
}

if [ -z "$${IMAGE_TAG}" ]; then
  error "IMAGE_TAG argument is required"
  exit 1
fi

# Get ECR endpoint
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_ENDPOINT="$${ACCOUNT_ID}.dkr.ecr.${aws_region}.amazonaws.com"

# Save current image tags
CURRENT_SERVER=$(docker inspect --format='{{.Config.Image}}' donate-server 2>/dev/null || echo "")
CURRENT_WORKERS=$(docker inspect --format='{{.Config.Image}}' donate-workers-email 2>/dev/null || echo "")

if [ -n "$${CURRENT_SERVER}" ]; then
  cat > "$${PREVIOUS_DEPLOY_FILE}" <<EOF
SERVER_IMAGE=$${CURRENT_SERVER}
WORKERS_IMAGE=$${CURRENT_WORKERS}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  log "Saved previous deploy state"
fi

# ECR login
aws ecr get-login-password --region ${aws_region} | docker login --username AWS --password-stdin "$${ECR_ENDPOINT}" || {
  error "ECR login failed"
  exit 1
}

# Pull new images
NEW_SERVER_IMAGE="$${ECR_ENDPOINT}/elodoar/donate-server:$${IMAGE_TAG}"
NEW_WORKERS_IMAGE="$${ECR_ENDPOINT}/elodoar/donate-workers:$${IMAGE_TAG}"

docker pull "$${NEW_SERVER_IMAGE}" || { error "Failed to pull server image"; exit 1; }
docker pull "$${NEW_WORKERS_IMAGE}" || { error "Failed to pull workers image"; exit 1; }

# Update compose file with new tags
sed -i "s|$${ECR_ENDPOINT}/elodoar/donate-server:[^ ]*|$${NEW_SERVER_IMAGE}|g" "$${COMPOSE_FILE}"
sed -i "s|$${ECR_ENDPOINT}/elodoar/donate-workers:[^ ]*|$${NEW_WORKERS_IMAGE}|g" "$${COMPOSE_FILE}"

# Deploy
docker compose -f "$${COMPOSE_FILE}" down >> "$${DEPLOY_LOG}" 2>&1
docker compose -f "$${COMPOSE_FILE}" up -d >> "$${DEPLOY_LOG}" 2>&1

# Health check (120s timeout)
log "Waiting for containers to become healthy (120s timeout)..."
TIMEOUT=120
ELAPSED=0
while [ $${ELAPSED} -lt $${TIMEOUT} ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))

  UNHEALTHY=$(docker compose -f "$${COMPOSE_FILE}" ps --format json 2>/dev/null | grep -c '"unhealthy"' || true)
  HEALTH_STATUS=$(docker compose -f "$${COMPOSE_FILE}" ps --format json 2>/dev/null | grep -c '"healthy"' || true)

  if [ "$${HEALTH_STATUS}" -ge 8 ]; then
    log "All containers healthy after $${ELAPSED}s"
    exit 0
  fi
done

# Health check failed — rollback
error "Containers not healthy after $${TIMEOUT}s, initiating rollback..."

if [ ! -f "$${PREVIOUS_DEPLOY_FILE}" ]; then
  error "No previous deploy file found, cannot rollback"
  exit 1
fi

source "$${PREVIOUS_DEPLOY_FILE}"
sed -i "s|$${NEW_SERVER_IMAGE}|$${SERVER_IMAGE}|g" "$${COMPOSE_FILE}"
sed -i "s|$${NEW_WORKERS_IMAGE}|$${WORKERS_IMAGE}|g" "$${COMPOSE_FILE}"

docker compose -f "$${COMPOSE_FILE}" down >> "$${DEPLOY_LOG}" 2>&1
docker compose -f "$${COMPOSE_FILE}" up -d >> "$${DEPLOY_LOG}" 2>&1

error "Rollback completed, exiting with failure"
exit 1
DEPLOYSCRIPT

  chmod +x "$${COMPOSE_DIR}/deploy.sh"

  # Start Docker Compose stack
  log "INFO" "compose_start" "Starting Docker Compose stack..."
  docker compose -f "$${COMPOSE_DIR}/docker-compose.prod.yml" up -d >> "$${LOG_FILE}" 2>&1 || {
    log "ERROR" "compose_start" "Failed to start Docker Compose stack"
    return 1
  }

  log "INFO" "compose_start" "Docker Compose stack started successfully"
  return 0
}

# -----------------------------------------------------------------------------
# Write bootstrap status file
# -----------------------------------------------------------------------------
write_status() {
  mkdir -p "$(dirname "$${STATUS_FILE}")"

  local steps_json=""
  local first=true

  for step in docker_install cloudwatch_agent ecr_pull ssm_secrets dnf_automatic compose_start; do
    local status="$${STEP_STATUS[$${step}]:-skipped}"
    local duration="$${STEP_DURATION[$${step}]:-0}"

    if [ "$${first}" = true ]; then
      first=false
    else
      steps_json="$${steps_json},"
    fi
    steps_json="$${steps_json}\"$${step}\":{\"status\":\"$${status}\",\"duration_ms\":$${duration}}"
  done

  # Determine overall status
  if [ "$${OVERALL_STATUS}" = "success" ]; then
    # Check if all critical steps passed
    for step in docker_install ecr_pull ssm_secrets compose_start; do
      if [ "$${STEP_STATUS[$${step}]}" != "success" ]; then
        OVERALL_STATUS="failed"
        break
      fi
    done
  fi

  cat > "$${STATUS_FILE}" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "$${OVERALL_STATUS}",
  "steps": {$${steps_json}}
}
EOF

  log "INFO" "bootstrap" "Status file written to $${STATUS_FILE} — overall: $${OVERALL_STATUS}"
}

# =============================================================================
# Main execution flow
# =============================================================================
main() {
  log "INFO" "bootstrap" "=== EC2 Bootstrap Starting ==="
  log "INFO" "bootstrap" "Environment: ${environment} | Region: ${aws_region} | Domain: ${domain_name}"

  # Step 1: Docker (critical — all subsequent steps depend on this)
  run_step "docker_install" step_docker_install || {
    CRITICAL_FAILURE=true
    log "ERROR" "bootstrap" "Docker install failed — skipping dependent steps (ecr_pull, compose_start)"
  }

  # Step 2: CloudWatch Agent (independent of Docker for log collection)
  run_step "cloudwatch_agent" step_cloudwatch_agent || {
    log "WARN" "bootstrap" "CloudWatch Agent failed — logging will be limited"
  }

  # Step 3: ECR pull (depends on Docker)
  if [ "$${CRITICAL_FAILURE}" = false ]; then
    run_step "ecr_pull" step_ecr_pull || {
      CRITICAL_FAILURE=true
      log "ERROR" "bootstrap" "ECR pull failed — cannot start compose stack"
    }
  else
    STEP_STATUS["ecr_pull"]="skipped"
    log "WARN" "ecr_pull" "Skipped due to Docker install failure"
  fi

  # Step 4: SSM secrets (depends on nothing, but compose depends on it)
  run_step "ssm_secrets" step_ssm_secrets || {
    CRITICAL_FAILURE=true
    log "ERROR" "bootstrap" "SSM secrets retrieval failed — cannot start compose stack"
  }

  # Step 5: dnf-automatic (independent)
  run_step "dnf_automatic" step_dnf_automatic || {
    log "WARN" "bootstrap" "dnf-automatic setup failed — security auto-updates disabled"
  }

  # Step 6: Start Compose stack (depends on steps 1, 3, and 4)
  if [ "$${CRITICAL_FAILURE}" = false ]; then
    run_step "compose_start" step_compose_start || {
      log "ERROR" "bootstrap" "Docker Compose stack failed to start"
    }
  else
    STEP_STATUS["compose_start"]="skipped"
    log "WARN" "compose_start" "Skipped due to earlier critical failures"
  fi

  # Write final status
  write_status

  log "INFO" "bootstrap" "=== EC2 Bootstrap Complete (status: $${OVERALL_STATUS}) ==="
}

# Run main
main
