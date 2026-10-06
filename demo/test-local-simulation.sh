#!/usr/bin/env bash
# ==============================================================================
# Simulation Locale : Démonstration Zéro Downtime & Rollback avec Traefik
# ==============================================================================
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${DEMO_DIR}/sandbox"

# Buildkit legacy : le builder BuildKit écrit un fichier d'activité dans
# ~/.docker/buildx/activity/, ce qui fait échouer le build dans tout environnement
# où ce chemin n'est pas inscriptible (CI, sandbox, user sans HOME persistant) :
#   ERROR: failed to update builder last activity time: ... operation not permitted
# Même correctif que env/test-full-scenario.sh. Surchargeable : DOCKER_BUILDKIT=1.
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"
TRAEFIK_NET="autodeploy-demo-net"
# Ports configurables pour éviter les collisions avec d'autres stacks locales.
DEMO_HTTP_PORT="${DEMO_HTTP_PORT:-8080}"
DEMO_DASH_PORT="${DEMO_DASH_PORT:-8081}"
DEMO_URL="http://localhost:${DEMO_HTTP_PORT}"

# Suivi d'échec : ce script DOIT pouvoir rougir (un "SUCCÈS" inconditionnel ne prouve rien).
FAILED=0
fail() { echo "    [ÉCHEC] $*"; FAILED=1; }
pass() { echo "    [OK] $*"; }
assert_contains() { # <chaine> <motif> <label>
  if printf '%s' "$1" | grep -q "$2"; then pass "$3"; else fail "$3 (attendu motif: '$2')"; fi
}

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
mkdir -p "$WORK_DIR"   # le pinger y écrit ses résultats ; sans ça, touch/redirect échouent
docker network create "$TRAEFIK_NET" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Labels Traefik PARTAGÉS par TOUS les conteneurs de la démo (ancien, candidat,
# candidat cassé). C'est une condition dure du rolling zéro-downtime, pas un détail :
# si deux conteneurs déclarent le MÊME service avec des labels différents (ex: le
# candidat a healthcheck.* et pas l'ancien), Traefik v3 ne fusionne pas — il
# SUPPRIME le service et loggue :
#   ERR Service defined multiple times with different configurations serviceName=demo-app
#   ERR the service "demo-app@docker" does not exist  routerName=demo-app@docker
# Résultat : router 'disabled' => 404 sur TOUT le trafic pendant la phase parallèle.
# Labels identiques => les deux conteneurs deviennent 2 serveurs UP du même load
# balancer, et le swap est réellement sans coupure.
# ------------------------------------------------------------------------------
DEMO_LABELS=(
  --label "traefik.enable=true"
  --label "traefik.http.routers.demo-app.rule=PathPrefix(\`/\`)"
  # Priorite EXPLICITE, et pas pour faire joli. Un Traefik qui monte le socket
  # Docker voit TOUS les conteneurs labels de la machine, y compris ceux d'autres
  # stacks (le scenario env/ laisse son infra tourner apres son execution). Deux
  # routers en PathPrefix(/) = egalite de longueur, departage arbitraire : le
  # router etranger peut gagner et, son backend etant injoignable depuis ce
  # reseau, la demo repond "503 no available server" sans que rien ne soit casse
  # chez elle. Une priorite haute rend la victoire deterministe.
  --label "traefik.http.routers.demo-app.priority=1000"
  --label "traefik.http.routers.demo-app.entrypoints=web"
  --label "traefik.http.services.demo-app.loadbalancer.server.port=80"
  --label "traefik.http.services.demo-app.loadbalancer.healthcheck.path=/health"
  --label "traefik.http.services.demo-app.loadbalancer.healthcheck.interval=3s"
  --label "traefik.http.services.demo-app.loadbalancer.healthcheck.timeout=2s"

  # Middleware RETRY : absorbe la fenêtre de course résiduelle entre l'arrêt de
  # l'ancien conteneur (ou le rechargement lié au rename) et son retrait effectif
  # du pool. Sans lui, la requête routée sur le backend mourant ressort en
  # 502/504 côté client.
  # NB Traefik v3 : le retry est un MIDDLEWARE, pas un champ du load balancer.
  #   `loadbalancer.retry.*` => "field not found, node: retry" => service supprimé.
  # NB `tryDuration` n'existe qu'à partir de v3.1 ; sur v3.0 s'en tenir à attempts.
  --label "traefik.http.middlewares.demo-app-retry.retry.attempts=2"
  --label "traefik.http.routers.demo-app.middlewares=demo-app-retry"
)

# 2. Démarrage de Traefik en mode Docker Provider
echo "==> 2. Démarrage de Traefik (HTTP sur localhost:${DEMO_HTTP_PORT}, Dashboard sur ${DEMO_DASH_PORT})..."
docker rm -f demo-traefik 2>/dev/null || true
docker run -d --name demo-traefik \
  --network "$TRAEFIK_NET" \
  -p "${DEMO_HTTP_PORT}:80" \
  -p "${DEMO_DASH_PORT}:8080" \
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

# Un build qui échoue n'a aucune raison de ressembler à un échec de la démo :
# on sort avec un message qui nomme la cause (et sa parade) au lieu d'un stack trace.
build_demo_image() { # <tag>
  local tag="$1"
  if ! docker build -t "local-demo/app:${tag}" -q - >/dev/null; then
    echo "    [ÉCHEC] Construction de 'local-demo/app:${tag}' impossible — démo interrompue." >&2
    echo "    Cause fréquente : ~/.docker/buildx non inscriptible -> relancer avec DOCKER_BUILDKIT=0" >&2
    exit 1
  fi
  echo "    [OK] local-demo/app:${tag} construite"
}

# Image v1.0.0
build_demo_image 1.0.0 <<EOF
FROM nginx:alpine
RUN echo "VERSION 1.0.0 - PRODUCTION STABLE" > /usr/share/nginx/html/index.html
RUN echo "OK" > /usr/share/nginx/html/health
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD wget -q -O - http://127.0.0.1/health || exit 1
EOF

# Image v1.1.0
build_demo_image 1.1.0 <<EOF
FROM nginx:alpine
RUN echo "VERSION 1.1.0 - NOUVELLE VERSION" > /usr/share/nginx/html/index.html
RUN echo "OK" > /usr/share/nginx/html/health
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD wget -q -O - http://127.0.0.1/health || exit 1
EOF

# Image v1.2.0 (Cassée : le healthcheck échoue toujours)
build_demo_image 1.2.0 <<EOF
FROM nginx:alpine
RUN echo "VERSION 1.2.0 - CASSEE" > /usr/share/nginx/html/index.html
HEALTHCHECK --interval=2s --timeout=1s --retries=2 CMD exit 1
EOF

# 4. Démarrage de la v1.0.0
echo "==> 4. Lancement de la version initiale (v1.0.0)..."
docker run -d --name demo-app \
  --network "$TRAEFIK_NET" \
  "${DEMO_LABELS[@]}" \
  local-demo/app:1.0.0 >/dev/null

sleep 3
echo "    [Test curl] Réponse actuelle via Traefik :"
curl -s "$DEMO_URL/"
echo ""

# 5. Démonstration de la bascule vers v1.1.0 (Zéro Downtime MESURÉE)
echo "==> 5. Lancement de la mise à jour vers v1.1.0..."
echo "       Démarrage en tâche de fond de requêtes continues pour mesurer la disponibilité..."

PING_RESULT="${WORK_DIR}/ping_result.txt"
PING_STOP="${WORK_DIR}/ping_stop"
rm -f "$PING_STOP" "$PING_RESULT"

# Pinger en arrière-plan : tourne TOUTE la durée du swap (stop-file), écrit
# total/fails dans un fichier (le sous-shell ne partage pas les variables).
(
  fails=0; total=0; i=0
  while [[ ! -f "$PING_STOP" ]]; do
    i=$((i + 1))
    code=$(curl -s -o /dev/null -w "%{http_code}" "$DEMO_URL/" || echo "ERR")
    total=$((total + 1))
    [[ "$code" != "200" ]] && { fails=$((fails + 1)); echo "    [Pinger ALERTE] requête $i → $code"; }
    sleep 0.2
  done
  echo "$total $fails" > "$PING_RESULT"
) &
PINGER_PID=$!

# Exécution du cycle de déploiement manuel (identique à autodeploy.sh)
TARGET_IMAGE="local-demo/app:1.1.0"
NEXT_CONTAINER="demo-app-candidate"
CURRENT_CONTAINER="demo-app"

docker run -d --name "$NEXT_CONTAINER" \
  --network "$TRAEFIK_NET" \
  "${DEMO_LABELS[@]}" \
  "$TARGET_IMAGE" >/dev/null

echo "    En attente du Healthcheck sur le conteneur candidat (max 30s)..."
health_ok=false
for i in {1..30}; do
  status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NEXT_CONTAINER" 2>/dev/null || echo "")
  [[ "$status" == "healthy" ]] && { health_ok=true; break; }
  sleep 1
done
if [[ "$health_ok" != "true" ]]; then
  touch "$PING_STOP"; wait "$PINGER_PID" 2>/dev/null || true
  fail "le candidat 1.1.0 n'est pas devenu healthy en 30s (status=${status:-inconnu})"
fi

echo "    Bascule Traefik..."
sleep 2
docker stop -t 5 "$CURRENT_CONTAINER" >/dev/null
docker rm "$CURRENT_CONTAINER" >/dev/null
docker rename "$NEXT_CONTAINER" "$CURRENT_CONTAINER"

touch "$PING_STOP"
wait "$PINGER_PID" 2>/dev/null || true

if [[ -f "$PING_RESULT" ]]; then
  read -r total fails < "$PING_RESULT"
  echo "    Pinger: ${total} requêtes, ${fails} en erreur"
  if [[ "$fails" -eq 0 ]]; then
    pass "aucune erreur détectée sur ${total} requêtes (échantillonnage 200ms)"
    echo "    [NOTE] Ce chiffre ne PROUVE pas un downtime nul. L'échantillonnage à 200ms"
    echo "    est trop grossier pour voir la fenêtre résiduelle du swap : à 50ms, le même"
    echo "    swap échoue sur ~1 requête sur 40 avec un timeout de 2s (3 runs sur 5)."
    echo "    Cause : pas de drain de l'ancien conteneur avant docker stop."
    echo "    Voir README §2 règle 2."
  else
    fail "erreurs détectées : ${fails}/${total} requêtes en erreur pendant le swap"
  fi
else
  fail "fichier de résultat du pinger absent"
fi

BODY=$(curl -s "$DEMO_URL/" || echo "CURL_ERR")
echo "    [Test curl] Réponse après bascule : $BODY"
assert_contains "$BODY" "VERSION 1.1.0" "la v1.1.0 est servie après bascule"
echo ""

# 6. Démonstration du ROLLBACK sur image cassée (v1.2.0)
echo "==> 6. Test du ROLLBACK AUTOMATIQUE (tentative de déploiement de v1.2.0-broken)..."
TARGET_IMAGE_BROKEN="local-demo/app:1.2.0"

# Labels IDENTIQUES ici aussi : un candidat cassé dont les labels diffèrent de
# l'ancien ferait sauter le service Traefik (donc la prod) au lieu d'être
# simplement évincé du pool par son propre healthcheck.
docker run -d --name "$NEXT_CONTAINER" \
  --network "$TRAEFIK_NET" \
  "${DEMO_LABELS[@]}" \
  "$TARGET_IMAGE_BROKEN" >/dev/null

echo "    Attente du Healthcheck (devrait échouer)..."
broken_detected=false
for i in {1..12}; do
  status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NEXT_CONTAINER" 2>/dev/null || echo "")
  if [[ "$status" == "unhealthy" ]]; then
    broken_detected=true
    break
  fi
  sleep 1
done

if [[ "$broken_detected" == "true" ]]; then
  pass "version cassée détectée (healthcheck unhealthy)"
  echo "    Suppression immédiate du conteneur candidat en échec..."
  docker stop "$NEXT_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$NEXT_CONTAINER" >/dev/null 2>&1 || true
else
  fail "version cassée NON détectée en 12s (status=${status:-inconnu})"
  docker rm -f "$NEXT_CONTAINER" >/dev/null 2>&1 || true
fi

BODY=$(curl -s "$DEMO_URL/" || echo "CURL_ERR")
echo "    [Test curl] Vérification que la v1.1.0 répond toujours : $BODY"
assert_contains "$BODY" "VERSION 1.1.0" "la v1.1.0 stable sert toujours après rollback"

echo ""
echo "======================================================================"
if [ "$FAILED" -eq 0 ]; then
  echo "    DÉMONSTRATION TERMINÉE AVEC SUCCÈS !"
  echo "======================================================================"
  exit 0
else
  echo "    DÉMONSTRATION EN ÉCHEC — voir les [ÉCHEC] ci-dessus."
  echo "======================================================================"
  exit 1
fi
