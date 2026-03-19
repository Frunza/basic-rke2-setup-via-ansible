#!/bin/sh

# Exit immediately if a simple command exits with a nonzero exit value
set -e

docker build --build-arg SSH_PRIVATE_KEY="$SSH_PRIVATE_KEY" -t ansiblerke2 .
#docker build --build-arg SSH_PRIVATE_KEY="$TARGET_MACHINE_SSH_PRIVATE_KEY" -t ansiblerke2 .
docker compose -f dockerCompose.yml run --rm main
