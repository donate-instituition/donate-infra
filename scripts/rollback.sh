#!/bin/bash
set -euo pipefail

# =============================================================================
# rollback.sh — Rollback the Docker Compose stack to previously deployed images
# =============================================================================

# Constants
COMPOSE_DIR="/opt/elodoar"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.prod.yml"
PREVIOUS_DEPLOY_FILE="$COMPOSE_DIR/previous-deploy.env"
ENV_FILE="$COMPOSE_DIR/.env"
ROLLBACK_LOG="/var/log/user-data.log"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] [rollback] $1" | tee -a "$ROLLBACK_LOG"
}

error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] [rollback] $1" | tee -a "$ROLLBACK_LOG"
}

# -----------------------------------------------------------------------------
# Step 1: Verify previous-deploy.env exists and is readable
# -----------------------------------------------------------------------------
if [ ! -f "$PREVIOUS_DEPLOY_FILE" ] || [ ! -r "$PREVIOUS_DEPLOY_FILE" ]; then
  error "No rollback target available — previous-deploy.env is missing or corrupted"
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: Source previous-deploy.env to get previous image tags
# -----------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$PREVIOUS_DEPLOY_FILE"

# -----------------------------------------------------------------------------
# Step 3: Validate that SERVER_IMAGE and WORKERS_IMAGE are non-empty
# -----------------------------------------------------------------------------
if [ -z "${SERVER_IMAGE:-}" ] || [ -z "${WORKERS_IMAGE:-}" ]; then
  error "previous-deploy.env is corrupted (missing image tags)"
  exit 1
fi

log "Rolling back to: SERVER_IMAGE=$SERVER_IMAGE, WORKERS_IMAGE=$WORKERS_IMAGE"

# -----------------------------------------------------------------------------
# Step 4: Update .env file with the previous image tags
# -----------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  sed -i "s|^SERVER_IMAGE=.*|SERVER_IMAGE=$SERVER_IMAGE|" "$ENV_FILE"
  sed -i "s|^WORKERS_IMAGE=.*|WORKERS_IMAGE=$WORKERS_IMAGE|" "$ENV_FILE"
else
  error ".env file not found at $ENV_FILE"
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 5: Bring down current stack
# -----------------------------------------------------------------------------
log "Stopping current Docker Compose stack..."
docker compose -f "$COMPOSE_FILE" down >> "$ROLLBACK_LOG" 2>&1

# -----------------------------------------------------------------------------
# Step 6: Start stack with previous images
# -----------------------------------------------------------------------------
log "Starting Docker Compose stack with previous images..."
docker compose -f "$COMPOSE_FILE" up -d >> "$ROLLBACK_LOG" 2>&1

# -----------------------------------------------------------------------------
# Step 7: Wait for health checks (300s / 5 minutes timeout, check every 5s)
# -----------------------------------------------------------------------------
log "Waiting for containers to become healthy (300s timeout)..."
TIMEOUT=300
ELAPSED=0
TOTAL_SERVICES=8

while [ $ELAPSED -lt $TIMEOUT ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))

  HEALTHY_COUNT=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | grep -c '"healthy"' || true)

  if [ "$HEALTHY_COUNT" -ge $TOTAL_SERVICES ]; then
    log "Rollback successful — all $TOTAL_SERVICES containers healthy after ${ELAPSED}s"
    exit 0
  fi
done

# -----------------------------------------------------------------------------
# Step 8: Health check failed — report which services could not be restored
# -----------------------------------------------------------------------------
error "Rollback health check failed after ${TIMEOUT}s"

# Report unhealthy/non-running services
UNHEALTHY_SERVICES=$(docker compose -f "$COMPOSE_FILE" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | grep -v "healthy" | tail -n +2 || true)

if [ -n "$UNHEALTHY_SERVICES" ]; then
  error "Services that could not be restored:"
  echo "$UNHEALTHY_SERVICES" | while IFS= read -r line; do
    error "  $line"
  done
fi

exit 1
