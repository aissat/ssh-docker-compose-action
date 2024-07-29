#!/usr/bin/env bash
set -euo pipefail

# Default values
: "${DOCKER_ENV:=''}"
: "${DOCKER_ENV_FILE:=''}"
: "${PULL:=false}"
: "${DOCKER_DOWN:=false}"
: "${USE_DOCKER_STACK:=false}"
: "${DOCKER_COMPOSE_FILENAME:='docker-compose.yml'}"
: "${DOCKER_COMPOSE_PREFIX:='app'}"
: "${BEFORE_DEPLOY:=''}"
: "${AFTER_DEPLOY:=''}"

# Logging function
log() {
    echo ">> [$1]" "${@:2}"
}

# Cleanup function
cleanup() {
    set +e
    log "local" "Killing ssh agent."
    ssh-agent -k
    log "local" "Removing workspace archive."
    rm -f /tmp/workspace.tar.bz2
}
trap cleanup EXIT

# Main script
echo "========================================================================"
echo "DOCKER_ENV: $DOCKER_ENV"
echo "DOCKER_ENV_FILE: $DOCKER_ENV_FILE"
echo "DOCKER_DOWN: $DOCKER_DOWN"
echo "========================================================================"

echo -n "$DOCKER_ENV_FILE" | base64 -d > .env
cat .env

log "local" "Packing workspace into archive to transfer onto remote machine."
tar cjf /tmp/workspace.tar.bz2 --exclude .git .

log "local" "Launching ssh agent."
eval "$(ssh-agent -s)"

# Construct the remote command
remote_command=$(cat << EOF
set -euo pipefail

DOCKER_COMPOSE_FILENAME="$DOCKER_COMPOSE_FILENAME"
DOCKER_COMPOSE_PREFIX="$DOCKER_COMPOSE_PREFIX"
$DOCKER_ENV

log() {
    echo '>> [remote]' "\$@"
}

cleanup() {
    log 'Removing workspace...'
    rm -rf "\$HOME/workspace"
}

trap cleanup EXIT

log 'Creating workspace directory...'
mkdir -p "\$HOME/workspace"

log 'Unpacking workspace...'
tar -C "\$HOME/workspace" -xj

cd "\$HOME/workspace"
EOF
)

remote_command+=$'\n'"$BEFORE_DEPLOY"

if [ "$PULL" = true ]; then
    remote_command+=$'\nlog \'Pulling images...\'; docker compose -f "$DOCKER_COMPOSE_FILENAME" -p "$DOCKER_COMPOSE_PREFIX" pull;'
fi

if [ "$DOCKER_DOWN" = true ]; then
    remote_command+=$'\nlog \'Stopping docker compose...\'; docker compose -f "$DOCKER_COMPOSE_FILENAME" -p "$DOCKER_COMPOSE_PREFIX" down;'
else
    remote_command+=$'\nlog \'Launching docker compose...\'; docker compose -f "$DOCKER_COMPOSE_FILENAME" -p "$DOCKER_COMPOSE_PREFIX" up -d --remove-orphans --build;'
fi

if [ "$USE_DOCKER_STACK" = true ]; then
    remote_command+=$'\nlog \'Launching docker stack deploy...\'; cd "\$HOME/workspace/$DOCKER_COMPOSE_PREFIX"; docker stack deploy -c "$DOCKER_COMPOSE_FILENAME" --prune "$DOCKER_COMPOSE_PREFIX";'
fi

remote_command+=$'\n'"$AFTER_DEPLOY"

# Add SSH key and execute the remote command
ssh-add <(echo "$SSH_PRIVATE_KEY")

log "local" "Connecting to remote host."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SSH_USER@$SSH_HOST" -p "$SSH_PORT" \
    "$remote_command" \
    < /tmp/workspace.tar.bz2
