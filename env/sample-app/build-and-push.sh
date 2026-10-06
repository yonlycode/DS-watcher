#!/usr/bin/env bash
# ==============================================================================
# Build et Push d'une version de l'application test vers le Registry local
# Usage:
#   ./build-and-push.sh 1.0.0
#   ./build-and-push.sh 1.1.0
#   ./build-and-push.sh 1.2.0 --broken
# ==============================================================================
set -euo pipefail

VERSION="${1:-}"
FLAG="${2:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--broken]"
  echo "Exemple: $0 1.0.0"
  echo "         $0 1.2.0 --broken"
  exit 1
fi

REGISTRY="${REGISTRY_HOST:-localhost:5001}"
IMAGE_NAME="${REGISTRY}/sample-app:${VERSION}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL_HEALTH="false"
if [[ "$FLAG" == "--broken" ]]; then
  FAIL_HEALTH="true"
  echo "==> ATTENTION : Construction d'une version corrompue (FAIL_HEALTH=true)"
fi

# Marqueur de build (optionnel) : change le contenu de l'image sans changer le tag.
# Permet de tester la détection de "tag repoussé, contenu changé" (Phase 4/5).
BUILD_MARKER="${BUILD_MARKER:-none}"

echo "==> 1. Construction de l'image Docker : ${IMAGE_NAME}..."
docker build \
  --build-arg APP_VERSION="$VERSION" \
  -t "$IMAGE_NAME" \
  -f - "$APP_DIR" <<EOF
FROM node:20-alpine
WORKDIR /app
COPY server.js /app/server.js
ENV PORT=3000
ENV APP_VERSION=${VERSION}
ENV FAIL_HEALTH=${FAIL_HEALTH}
ENV BUILD_MARKER=${BUILD_MARKER}
HEALTHCHECK --interval=2s --timeout=1s --retries=2 --start-period=2s \
  CMD wget -q -O - http://127.0.0.1:3000/health || exit 1
EXPOSE 3000
CMD ["node", "server.js"]
EOF

echo "==> 2. Envoi (Push) vers le registre ${REGISTRY}..."
docker push "$IMAGE_NAME"

echo "==> [SUCCÈS] Image ${IMAGE_NAME} publiée sur le registry local !"
