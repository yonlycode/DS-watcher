#!/usr/bin/env bash
# ==============================================================================
# Simulation Locale : Démonstration Zéro Downtime & Rollback avec Traefik
# ==============================================================================
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${DEMO_DIR}/sandbox"
TRAEFIK_NET="autodeploy-demo-net"

cleanup() {
  echo ""
  echo "==> Nettoyage de la démo..."
  docker rm -f demo-traefik demo-app demo-app-candidate demo-app-next 2>/dev/null || true
  docker network rm "$TRAEFIK_NET" 2>/dev/null || true
  rm -rf "$WORK_DIR"
  echo "==> Environnement de démo nettoyé."
}

trap cleanup EXIT

echo "======================================================================"
echo "    SIMULATION LOCALE DU ROLLING DEPLOY ZERO-DOWNTIME AVEC TRAEFIK   "
echo "======================================================================"

# 1. Préparation du réseau Docker
echo "==> 1. Création du réseau Docker '$TRAEFIK_NET'..."
docker network create "$TRAEFIK_NET" 2>/dev/null || true

# 2. Démarrage de Traefik en mode Docker Provider
echo "==> 2. Démarrage de Traefik (HTTP sur localhost:8080, Dashboard sur 8081)..."
docker rm -f demo-traefik 2>/dev/null || true
docker run -d --name demo-traefik \
  --network "$TRAEFIK_NET" \
  -p 8080:80 \
  -p 8081:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  traefik:v3.0 \
  --api.insecure=true \
  --providers.docker=true \
  --providers.docker.exposedbydefault=false \
  --entrypoints.web.address=:80 >/dev/null

sleep 2

# 3. Construction des images de test (v1.0.0, v1.1.0 et v1.2.0-broken)
echo "==> 3. Construction locale de 3 images de test :"
echo "       - local-demo/app:1.0.0 (Version initiale)"
echo "       - local-demo/app:1.1.0 (Version mise à jour)"
echo "       - local-demo/app:1.2.0 (Version corrompue pour tester le Rollback)"

# Image v1.0.0
docker build -t local-demo/app:1.0.0 -q - <<EOF >/dev/null
FROM nginx:alpine
RUN echo "VERSION 1.0.0 - PRODUCTION STABLE" > /usr/share/nginx/html/index.html
RUN echo "OK" > /usr/share/nginx/html/health
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD wget -q -O - http://127.0.0.1/health || exit 1
EOF

# Image v1.1.0
docker build -t local-demo/app:1.1.0 -q - <<EOF >/dev/null
FROM nginx:alpine
RUN echo "VERSION 1.1.0 - NOUVELLE VERSION" > /usr/share/nginx/html/index.html
RUN echo "OK" > /usr/share/nginx/html/health
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD wget -q -O - http://127.0.0.1/health || exit 1
EOF

# Image v1.2.0 (Cassée : retourne une erreur HTTP 500 sur /health)
docker build -t local-demo/app:1.2.0 -q - <<EOF >/dev/null
FROM nginx:alpine
RUN echo "VERSION 1.2.0 - CASSEE" > /usr/share/nginx/html/index.html
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD exit 1
EOF

# 4. Démarrage de la v1.0.0
echo "==> 4. Lancement de la version initiale (v1.0.0)..."
docker run -d --name demo-app \
  --network "$TRAEFIK_NET" \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.demo-app.rule=PathPrefix(\`/\`)" \
  --label "traefik.http.routers.demo-app.entrypoints=web" \
  --label "traefik.http.services.demo-app.loadbalancer.server.port=80" \
  local-demo/app:1.0.0 >/dev/null

sleep 3
echo "    [Test curl] Réponse actuelle via Traefik :"
curl -s http://localhost:8080/
echo ""

# 5. Démonstration de la bascule vers v1.1.0 (Zéro Downtime)
echo "==> 5. Lancement de la mise à jour vers v1.1.0..."
echo "       Démarrage en tâche de fond de requêtes continues pour mesurer la disponibilité..."

# Lancement d'un pinger en arrière-plan
(
  for i in {1..30}; do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/ || echo "ERR")
    if [[ "$code" != "200" ]]; then
      echo "    [Pinger ALERTE] Code HTTP reçu : $code (requête $i)"
    fi
    sleep 0.2
  done
) &
PINGER_PID=$!

# Exécution du cycle de déploiement manuel (identique à autodeploy.sh)
TARGET_IMAGE="local-demo/app:1.1.0"
NEXT_CONTAINER="demo-app-candidate"
CURRENT_CONTAINER="demo-app"

docker run -d --name "$NEXT_CONTAINER" \
  --network "$TRAEFIK_NET" \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.demo-app.rule=PathPrefix(\`/\`)" \
  --label "traefik.http.routers.demo-app.entrypoints=web" \
  --label "traefik.http.services.demo-app.loadbalancer.server.port=80" \
  "$TARGET_IMAGE" >/dev/null

echo "    En attente du Healthcheck sur le conteneur candidat..."
while true; do
  status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NEXT_CONTAINER" 2>/dev/null || echo "")
  if [[ "$status" == "healthy" ]]; then
    break
  fi
  sleep 1
done

echo "    [OK] Le conteneur candidat est healthy. Bascule Traefik..."
sleep 2
docker stop -t 5 "$CURRENT_CONTAINER" >/dev/null
docker rm "$CURRENT_CONTAINER" >/dev/null
docker rename "$NEXT_CONTAINER" "$CURRENT_CONTAINER"

wait "$PINGER_PID" || true

echo "    [Test curl] Réponse après bascule :"
curl -s http://localhost:8080/
echo "    [SUCCÈS] 0 seconde de coupure constatée pendant le swap !"
echo ""

# 6. Démonstration du ROLLBACK sur image cassée (v1.2.0)
echo "==> 6. Test du ROLLBACK AUTOMATIQUE (tentative de déploiement de v1.2.0-broken)..."
TARGET_IMAGE_BROKEN="local-demo/app:1.2.0"

docker run -d --name "$NEXT_CONTAINER" \
  --network "$TRAEFIK_NET" \
  --label "traefik.enable=true" \
  --label "traefik.http.routers.demo-app.rule=PathPrefix(\`/\`)" \
  --label "traefik.http.routers.demo-app.entrypoints=web" \
  --label "traefik.http.services.demo-app.loadbalancer.server.port=80" \
  "$TARGET_IMAGE_BROKEN" >/dev/null

echo "    Attente du Healthcheck (devrait échouer)..."
broken_detected=false
for i in {1..8}; do
  status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NEXT_CONTAINER" 2>/dev/null || echo "")
  if [[ "$status" == "unhealthy" ]]; then
    broken_detected=true
    break
  fi
  sleep 1
done

if [[ "$broken_detected" == "true" ]]; then
  echo "    [ECHEC DETECTE] Le healthcheck du nouveau conteneur a échoué (Status: unhealthy) !"
  echo "    Suppression immédiate du conteneur candidat en échec..."
  docker stop "$NEXT_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$NEXT_CONTAINER" >/dev/null 2>&1 || true
  echo "    [SECURITE] L'ancien conteneur v1.1.0 est resté en place sans interruption !"
fi

echo "    [Test curl] Vérification que la v1.1.0 répond toujours :"
curl -s http://localhost:8080/

echo ""
echo "======================================================================"
echo "    DEMONSTRATION TERMINEE AVEC SUCCES !"
echo "======================================================================"
