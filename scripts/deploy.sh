#!/bin/bash
set -euo pipefail

# ==============================================================================
# deploy.sh — Deployment script for the Elodoar Docker Compose stack
# Pulls new images from ECR, updates the stack, and rolls back on failure.
#
# Usage: deploy.sh <IMAGE_TAG>
# Example: deploy.sh abc123f
#
# Requirements: 7.6, 7.7, 7.8, 7.11, 13.1, 13.2, 13.3, 13.4, 13.5, 13.6
# ==============================================================================

# --- Constants ---
COMPOSE_DIR="/opt/elodoar"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.prod.yml"
PREVIOUS_DEPLOY_FILE="$COMPOSE_DIR/previous-deploy.env"
ENV_FILE="$COMPOSE_DIR/.env"
HEALTH_CHECK_TIMEOUT=120
HEALTH_CHECK_INTERVAL=5

# --- Helpers ---

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [deploy] $*"
}

error() {
  log "ERROR: $*"
  exit 1
}

# --- Step 1: Validate IMAGE_TAG argument ---

IMAGE_TAG="${1:-}"

if [[ -z "$IMAGE_TAG" ]]; then
  error "IMAGE_TAG argument is required. Usage: deploy.sh <IMAGE_TAG>"
fi

log "Starting deployment with IMAGE_TAG=$IMAGE_TAG"

# --- Step 2: Determine ECR endpoint ---

AWS_REGION="${AWS_REGION:-$(grep -E '^AWS_REGION=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo 'us-east-1')}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text --region "$AWS_REGION")

if [[ -z "$AWS_ACCOUNT_ID" ]]; then
  error "Failed to retrieve AWS Account ID via sts get-caller-identity"
fi

ECR_ENDPOINT="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
SERVER_IMAGE="${ECR_ENDPOINT}/elodoar/donate-server:${IMAGE_TAG}"
WORKERS_IMAGE="${ECR_ENDPOINT}/elodoar/donate-workers:${IMAGE_TAG}"

log "ECR endpoint: $ECR_ENDPOINT"
log "Server image: $SERVER_IMAGE"
log "Workers image: $WORKERS_IMAGE"

# --- Step 3: Save current image tags to previous-deploy.env ---

log "Saving current image tags to $PREVIOUS_DEPLOY_FILE"

CURRENT_SERVER_IMAGE=""
CURRENT_WORKERS_IMAGE=""

# Try to read current image tags from running containers
if docker inspect donate-server >/dev/null 2>&1; then
  CURRENT_SERVER_IMAGE=$(docker inspect --format='{{.Config.Image}}' donate-server 2>/dev/null || true)
fi

if docker inspect donate-workers-email >/dev/null 2>&1; then
  CURRENT_WORKERS_IMAGE=$(docker inspect --format='{{.Config.Image}}' donate-workers-email 2>/dev/null || true)
fi

# Fallback: read from .env file if containers are not running
if [[ -z "$CURRENT_SERVER_IMAGE" ]]; then
  CURRENT_SERVER_IMAGE=$(grep -E '^SERVER_IMAGE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || true)
fi

if [[ -z "$CURRENT_WORKERS_IMAGE" ]]; then
  CURRENT_WORKERS_IMAGE=$(grep -E '^WORKERS_IMAGE=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || true)
fi

# Only save if we have valid previous tags
if [[ -n "$CURRENT_SERVER_IMAGE" && -n "$CURRENT_WORKERS_IMAGE" ]]; then
  cat > "$PREVIOUS_DEPLOY_FILE" <<EOF
SERVER_IMAGE=${CURRENT_SERVER_IMAGE}
WORKERS_IMAGE=${CURRENT_WORKERS_IMAGE}
DEPLOYED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  log "Saved previous deploy state: SERVER_IMAGE=$CURRENT_SERVER_IMAGE, WORKERS_IMAGE=$CURRENT_WORKERS_IMAGE"
else
  log "WARNING: Could not determine current image tags. No previous-deploy.env written (first deployment?)."
fi

# --- Step 4: Authenticate to ECR ---

log "Authenticating to ECR..."
if ! aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_ENDPOINT"; then
  error "Failed to authenticate to ECR"
fi
log "ECR authentication successful"

# --- Step 5: Pull new images ---

log "Pulling new images..."

if ! docker pull "$SERVER_IMAGE"; then
  error "Failed to pull server image: $SERVER_IMAGE"
fi

if ! docker pull "$WORKERS_IMAGE"; then
  error "Failed to pull workers image: $WORKERS_IMAGE"
fi

log "Images pulled successfully"

# --- Step 6: Update .env file with new image tags ---

log "Updating .env file with new image tags"

# Update SERVER_IMAGE in .env (replace if exists, append if not)
if grep -qE '^SERVER_IMAGE=' "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^SERVER_IMAGE=.*|SERVER_IMAGE=${SERVER_IMAGE}|" "$ENV_FILE"
else
  echo "SERVER_IMAGE=${SERVER_IMAGE}" >> "$ENV_FILE"
fi

# Update WORKERS_IMAGE in .env (replace if exists, append if not)
if grep -qE '^WORKERS_IMAGE=' "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^WORKERS_IMAGE=.*|WORKERS_IMAGE=${WORKERS_IMAGE}|" "$ENV_FILE"
else
  echo "WORKERS_IMAGE=${WORKERS_IMAGE}" >> "$ENV_FILE"
fi

log ".env updated: SERVER_IMAGE=$SERVER_IMAGE, WORKERS_IMAGE=$WORKERS_IMAGE"

# --- Step 7: Stop current stack ---

log "Stopping current Docker Compose stack..."
docker compose -f "$COMPOSE_FILE" down || log "WARNING: docker compose down returned non-zero (stack may not have been running)"

# --- Step 8: Start new stack ---

log "Starting new Docker Compose stack..."
if ! docker compose -f "$COMPOSE_FILE" up -d; then
  error "Failed to start Docker Compose stack"
fi

# --- Step 9: Wait for health checks ---

log "Waiting for health checks (timeout: ${HEALTH_CHECK_TIMEOUT}s)..."

ELAPSED=0

while [[ $ELAPSED -lt $HEALTH_CHECK_TIMEOUT ]]; do
  sleep "$HEALTH_CHECK_INTERVAL"
  ELAPSED=$((ELAPSED + HEALTH_CHECK_INTERVAL))

  # Get health status of all containers in the compose stack
  UNHEALTHY=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null | \
    grep -v '"Health":"healthy"' | grep -v '"Health":""' | grep '"Health"' || true)

  # Check if all services with health checks are healthy
  ALL_HEALTHY=true
  SERVICES=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' 2>/dev/null)

  for SERVICE in $SERVICES; do
    HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SERVICE" 2>/dev/null || echo "unknown")
    if [[ "$HEALTH" == "starting" || "$HEALTH" == "unhealthy" ]]; then
      ALL_HEALTHY=false
      break
    fi
  done

  if [[ "$ALL_HEALTHY" == "true" ]]; then
    log "All containers are healthy after ${ELAPSED}s"
    log "Deployment successful! IMAGE_TAG=$IMAGE_TAG"
    exit 0
  fi

  log "Health check in progress... (${ELAPSED}s/${HEALTH_CHECK_TIMEOUT}s)"
done

# --- Step 10/11: Health check timeout — rollback ---

log "ERROR: Health check timeout after ${HEALTH_CHECK_TIMEOUT}s. Containers did not become healthy."

# Report which containers are unhealthy
SERVICES=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' 2>/dev/null || true)
for SERVICE in $SERVICES; do
  HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SERVICE" 2>/dev/null || echo "unknown")
  if [[ "$HEALTH" != "healthy" && "$HEALTH" != "none" ]]; then
    log "  Unhealthy service: $SERVICE (status: $HEALTH)"
  fi
done

# --- Step 11b: Check for rollback target ---

if [[ ! -f "$PREVIOUS_DEPLOY_FILE" ]]; then
  log "ERROR: No rollback target available — $PREVIOUS_DEPLOY_FILE is missing"
  exit 1
fi

# Validate previous-deploy.env has required fields
PREV_SERVER_IMAGE=$(grep -E '^SERVER_IMAGE=' "$PREVIOUS_DEPLOY_FILE" 2>/dev/null | cut -d'=' -f2 || true)
PREV_WORKERS_IMAGE=$(grep -E '^WORKERS_IMAGE=' "$PREVIOUS_DEPLOY_FILE" 2>/dev/null | cut -d'=' -f2 || true)

if [[ -z "$PREV_SERVER_IMAGE" || -z "$PREV_WORKERS_IMAGE" ]]; then
  log "ERROR: $PREVIOUS_DEPLOY_FILE is corrupted — missing SERVER_IMAGE or WORKERS_IMAGE"
  log "ERROR: No rollback target available"
  exit 1
fi

# --- Step 11c: Perform rollback ---

log "Initiating rollback to previous images..."
log "  Previous SERVER_IMAGE: $PREV_SERVER_IMAGE"
log "  Previous WORKERS_IMAGE: $PREV_WORKERS_IMAGE"

# Restore previous image tags in .env
sed -i "s|^SERVER_IMAGE=.*|SERVER_IMAGE=${PREV_SERVER_IMAGE}|" "$ENV_FILE"
sed -i "s|^WORKERS_IMAGE=.*|WORKERS_IMAGE=${PREV_WORKERS_IMAGE}|" "$ENV_FILE"

# Stop failed stack and start with previous images
docker compose -f "$COMPOSE_FILE" down || true
docker compose -f "$COMPOSE_FILE" up -d

# Brief wait for rollback containers
log "Waiting for rollback containers to start..."
sleep 30

# Check rollback health
ROLLBACK_OK=true
SERVICES=$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}}' 2>/dev/null || true)
for SERVICE in $SERVICES; do
  HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$SERVICE" 2>/dev/null || echo "unknown")
  if [[ "$HEALTH" == "unhealthy" ]]; then
    ROLLBACK_OK=false
    log "  Rollback: service $SERVICE is unhealthy"
  fi
done

if [[ "$ROLLBACK_OK" == "true" ]]; then
  log "Rollback completed successfully. Stack restored to previous images."
else
  log "WARNING: Rollback completed but some services may be unhealthy. Manual intervention required."
fi

log "Deployment FAILED for IMAGE_TAG=$IMAGE_TAG — rolled back to previous version"
exit 1
