#!/usb/bin/env bash
set -e

if [ -z "$DOCKER_ENV" ]; then
  DOCKER_ENV=''
fi

if [ -z "$DOCKER_ENV_FILE" ]; then
  DOCKER_ENV_FILE=''
fi
echo "========================================================================"
echo $DOCKER_ENV
echo $DOCKER_ENV_FILE

echo -n "$DOCKER_ENV_FILE" | base64 -d > .env
cat .env

echo "========================================================================"

log() {
  echo ">> [local]" $@
}

cleanup() {
  set +e
  log "Killing ssh agent."
  ssh-agent -k
  log "Removing workspace archive."
  rm -f /tmp/workspace.tar.bz2
}
trap cleanup EXIT

log "Packing workspace into archive to transfer onto remote machine."
tar cjvf /tmp/workspace.tar.bz2 --exclude .git .

log "Launching ssh agent."
eval `ssh-agent -s`

# Construct the remote_command with Docker environment variables
remote_command="set -e ; $DOCKER_ENV  log() { echo '>> [remote]' \$@ ; } ; cleanup() { log 'Removing workspace...'; rm -rf \"\$HOME/workspace\" ; } ; log 'Creating workspace directory...' ; mkdir -p \"\$HOME/workspace\" ; trap cleanup EXIT ; log 'Unpacking workspace...' ; tar -C \"\$HOME/workspace\" -xjv ;"
if $PULL; then
  remote_command="$remote_command log 'Launching docker compose...' ; cd \"\$HOME/workspace\" ; log 'Pull images...' ; docker compose pull ; docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" up -d --remove-orphans --build ;"
else
  remote_command="$remote_command log 'Launching docker compose...' ; cd \"\$HOME/workspace\" ; docker compose -f \"$DOCKER_COMPOSE_FILENAME\" -p \"$DOCKER_COMPOSE_PREFIX\" up -d --remove-orphans --build ;"
fi

if $USE_DOCKER_STACK; then
  remote_command="$remote_command log 'Launching docker stack deploy...' ; cd \"\$HOME/workspace/$DOCKER_COMPOSE_PREFIX\" ; docker stack deploy -c \"$DOCKER_COMPOSE_FILENAME\" --prune \"$DOCKER_COMPOSE_PREFIX\" ;"
fi

#
ssh-add <(echo "$SSH_PRIVATE_KEY")

echo ">> [local] Connecting to remote host."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$SSH_USER@$SSH_HOST" -p "$SSH_PORT" \
  "$remote_command" \
  < /tmp/workspace.tar.bz2
