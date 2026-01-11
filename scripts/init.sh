#!/bin/bash
set -eu

if [ -f .env ]; then
  echo ".env already exists; skip copying."
else
  if [ -f .env.dist ]; then
    cp .env.dist .env
    echo "Created .env from .env.dist"
  else
    echo "Warning: .env.dist not found; nothing to copy" >&2
  fi
fi
