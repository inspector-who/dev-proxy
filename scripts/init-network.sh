#!/bin/bash
set -eu

NETWORK_NAME="${TRAEFIK_NETWORK:-traefik}"
echo "Ensuring shared network '${NETWORK_NAME}' exists..."

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  if docker network create -d bridge "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "Created network '${NETWORK_NAME}'"
  else
    echo "Default network create failed. Will try explicit subnets..."
    CANDIDATE_SUBNETS="${TRAEFIK_SUBNETS:-${TRAEFIK_SUBNET:-} 172.30.0.0/16 172.31.0.0/16 10.10.0.0/16 192.168.100.0/24}"
    CREATED=0
    for net in $CANDIDATE_SUBNETS; do
      [ -z "$net" ] && continue
      echo "Trying subnet $net ..."
      if docker network create -d bridge --subnet "$net" "$NETWORK_NAME" >/dev/null 2>&1; then
        echo "Created network '${NETWORK_NAME}' with subnet $net"
        CREATED=1
        break
      fi
    done
    if [ "$CREATED" -ne 1 ]; then
      echo "Failed to create network '${NETWORK_NAME}'."
      echo "Hints:"
      echo " - Provide a free subnet via TRAEFIK_SUBNET=10.123.0.0/16 make init-network"
      echo " - Or run 'make networks-prune' to clean up unused docker networks and retry"
      exit 1
    fi
  fi
else
  echo "Network '${NETWORK_NAME}' already exists."
fi

if [ -z "$(${SHELL:-bash} -lc 'docker ps -q -f ancestor=traefik')" ]; then
  echo "No running Traefik found. Starting local Traefik stack..."
  docker compose -p dev-proxy -f docker-compose.yml up -d
else
  echo "Traefik seems to be running already. Skipping local Traefik start."
fi
