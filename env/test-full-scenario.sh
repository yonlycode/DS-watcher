#!/usr/bin/env bash
# ==============================================================================
# Scénario de Test Complet End-to-End avec OpenTofu/Terraform & Sample App
#
# Ce test DOIT pouvoir ROUGIR : chaque étape est suivie d'une assertion qui fait
# exit 1 si le comportement attendu n'est pas observé. Un "SUCCÈS" inconditionnel
# ne prouve rien.
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
SANDBOX_DIR="${SCRIPT_DIR}/sandbox"
APP_DIR="${SCRIPT_DIR}/sample-app"

# État persistant isolé dans le sandbox (Phase 2) pour tester skip/reset sans toucher /var/lib.
export AUTODEPLOY_STATE_DIR="${SANDBOX_DIR}/state"
# Verrou isolé aussi : en prod le défaut est /run/autodeploy/lock (root-only). Ici
# on pousse le lock dans le sandbox pour que deux runs de test concurrents ne se
# marchent pas dessus et pour ne rien écrire dans un /tmp partagé.
export AUTODEPLOY_LOCK_FILE="${SANDBOX_DIR}/autodeploy.lock"
PING_RESULT_FILE="${SANDBOX_DIR}/ping_result.txt"
PING_STOP="${SANDBOX_DIR}/ping_stop"

# Buildkit legacy : évite les soucis de permissions buildx dans certains environnements.
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"

FAILED=0
fail() { echo "    [ÉCHEC] $*"; FAILED=1; }
pass() { echo "    [OK] $*"; }

# assert_contains <fichier> <motif> <label>
assert_contains() {
  if grep -q "$2" "$1"; then pass "$3"; else fail "$3 (attendu motif: '$2')"; fi
}
# assert_not_contains <fichier> <motif> <label>
assert_not_contains() {
  if grep -q "$2" "$1"; then fail "$3 (motif non désiré présent: '$2')"; else pass "$3"; fi
}

# Détection de l'outil IaC (OpenTofu ou Terraform)
IAC_BIN=""
if command -v tofu &>/dev/null; then
  IAC_BIN="tofu"
elif command -v terraform &>/dev/null; then
  IAC_BIN="terraform"
else
  echo "[ERROR] Ni 'tofu' ni 'terraform' n'ont été trouvés sur votre système." >&2
  exit 1
fi

echo "======================================================================"
echo "    TEST COMPLET DU FLUX AUTODEPLOY (IAC + REGISTRY + TRAEFIK + APP)  "
echo "    Moteur IaC utilisé : $IAC_BIN"
echo "======================================================================"

# Détection du socket Docker (rootless vs rootful) — même logique que la démo.
# Injecté dans Terraform via TF_VAR_docker_socket, qui alimente à la fois le
# provider docker ET le montage du socket dans le conteneur Traefik : une seule
# source de vérité, aucun décalage provider/volume. Sur un démon rootless,
# /var/run/docker.sock est inaccessible au conteneur ("permission denied") ; le
# socket réel vit dans $XDG_RUNTIME_DIR.
detect_docker_socket() {
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    case "$DOCKER_HOST" in
      unix://*) printf '%s' "${DOCKER_HOST#unix://}"; return 0 ;;
      *) return 1 ;;   # tcp/ssh : non montable comme volume conteneur
    esac
  fi
  local xrd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [[ -S "$xrd/docker.sock" ]] && { printf '%s' "$xrd/docker.sock"; return 0; }
  [[ -S /var/run/docker.sock ]] && { printf '/var/run/docker.sock'; return 0; }
  return 1
}
if ! DOCKER_SOCK="$(detect_docker_socket)"; then
  echo "[ERREUR] Aucun socket Docker détecté (DOCKER_HOST unix://, \$XDG_RUNTIME_DIR/docker.sock, /var/run/docker.sock)." >&2
  exit 1
fi
export TF_VAR_docker_socket="$DOCKER_SOCK"
echo "    [socket Docker] $DOCKER_SOCK"

cleanup_sandbox() {
  echo ""
  touch "$PING_STOP" 2>/dev/null || true
  if [[ "${KEEP_SANDBOX:-false}" == "true" ]]; then
    echo "==> KEEP_SANDBOX=true : logs préservés dans ${SANDBOX_DIR}"
    return
  fi
  echo "==> Nettoyage de l'espace temporaire..."
  rm -rf "$SANDBOX_DIR"
}
trap cleanup_sandbox EXIT

# ------------------------------------------------------------------------------
# 1. Déploiement de l'infrastructure locale avec OpenTofu / Terraform
# ------------------------------------------------------------------------------
echo "==> 1. Déploiement de l'environnement de test (Registry + Traefik)..."
docker rm -f sample-app sample-app-candidate test-registry test-traefik 2>/dev/null || true
(
  cd "$TF_DIR"
  "$IAC_BIN" init -input=false >/dev/null
  "$IAC_BIN" apply -auto-approve -input=false
) || { echo "ECHEC: provisioning IaC"; exit 1; }

echo "    [OK] Infrastructure prête (Registry :5001, Traefik :9080, Dash :9081)."

# ------------------------------------------------------------------------------
# 2. Préparation de la configuration Autodeploy pour le test
# ------------------------------------------------------------------------------
echo "==> 2. Configuration d'Autodeploy pour pointer sur le Registry local..."
mkdir -p "${SANDBOX_DIR}/config/apps.d"

cat <<EOF > "${SANDBOX_DIR}/config/autodeploy.env"
GITLAB_URL=""
GITLAB_REGISTRY=""
GITLAB_USER=""
GITLAB_TOKEN=""
WEBHOOK_URL=""
AUTO_PRUNE_IMAGES="false"
# API Traefik (dashboard insecure) pour l'attente active de découverte du candidat.
TRAEFIK_API_URL="http://localhost:9081"
EOF

# sample-app.conf — inclut le healthcheck TRAEFIK (le vrai garde-fou, Phase 3)
cat <<'EOF' > "${SANDBOX_DIR}/config/apps.d/sample-app.conf"
APP_NAME="sample-app"
IMAGE_REPO="localhost:5001/sample-app"
GITLAB_PROJECT_ID=""
HEALTHCHECK_TIMEOUT=30
HEALTHCHECK_INTERVAL=2

DOCKER_RUN_ARGS=(
  --restart unless-stopped
  --network "autodeploy-test-net"
  -e "PORT=3000"
  --label "traefik.enable=true"
  --label "traefik.http.routers.sample-app.rule=PathPrefix(\`/\`)"
  --label "traefik.http.routers.sample-app.entrypoints=web"
  --label "traefik.http.services.sample-app.loadbalancer.server.port=3000"
  --label "traefik.http.services.sample-app.loadbalancer.healthcheck.path=/health"
  --label "traefik.http.services.sample-app.loadbalancer.healthcheck.interval=3s"
  --label "traefik.http.services.sample-app.loadbalancer.healthcheck.timeout=2s"
  # Middleware retry (règle 2 du README) : absorbe la fenetre stop/rename du swap.
  --label "traefik.http.middlewares.sample_app_retry.retry.attempts=2"
  --label "traefik.http.routers.sample-app.middlewares=sample_app_retry"
)
EOF

run_autodeploy() {
  AUTODEPLOY_CONFIG_DIR="${SANDBOX_DIR}/config" "${ROOT_DIR}/bin/autodeploy.sh"
}

# ------------------------------------------------------------------------------
# 3. Étape A : Release 1.0.0
# ------------------------------------------------------------------------------
echo "==> 3. [RELEASE 1.0.0] Construction et publication..."
"${APP_DIR}/build-and-push.sh" "1.0.0" || { echo "ECHEC: build 1.0.0"; exit 1; }

echo "==> Déploiement v1.0.0..."
run_autodeploy > "${SANDBOX_DIR}/deploy_100.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && pass "deploy 1.0.0 exit 0" || fail "deploy 1.0.0 exit $RC"
sleep 1
BODY=$(curl -s http://localhost:9080/ || echo "CURL_ERR")
echo "    Réponse: $BODY"
assert_contains <(echo "$BODY") "Version: 1.0.0" "Traefik sert la v1.0.0"

# ------------------------------------------------------------------------------
# 4. Étape B : Release 1.1.0 + Rolling Update Zéro Downtime (mesuré)
# ------------------------------------------------------------------------------
echo "==> 4. [RELEASE 1.1.0] Rolling update avec trafic continu mesuré..."
"${APP_DIR}/build-and-push.sh" "1.1.0" || { echo "ECHEC: build 1.1.0"; exit 1; }

rm -f "$PING_STOP" "$PING_RESULT_FILE"
# Pinger en arrière-plan : tourne TOUTE la durée de l'update (stop-file), écrit
# total/fails dans un fichier (le sous-shell ne partage pas les variables).
(
  fails=0; total=0; i=0
  while [[ ! -f "$PING_STOP" ]]; do
    i=$((i + 1))
    code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/ || echo "ERR")
    total=$((total + 1))
    [[ "$code" != "200" ]] && { fails=$((fails + 1)); echo "    [ALERTE] requête $i → $code"; }
    sleep 0.2
  done
  echo "$total $fails" > "$PING_RESULT_FILE"
) &
PINGER_PID=$!

run_autodeploy > "${SANDBOX_DIR}/deploy_110.log" 2>&1; RC=$?
touch "$PING_STOP"
wait "$PINGER_PID" 2>/dev/null || true

[ "$RC" -eq 0 ] && pass "rolling update 1.1.0 exit 0" || fail "rolling update 1.1.0 exit $RC"

if [[ -f "$PING_RESULT_FILE" ]]; then
  read -r total fails < "$PING_RESULT_FILE"
  echo "    Pinger: ${total} requêtes, ${fails} en erreur"
  if [[ "$fails" -eq 0 ]]; then
    pass "zéro downtime : 0/${total} requêtes en erreur"
  else
    fail "downtime détecté : ${fails}/${total} requêtes en erreur pendant l'update"
  fi
else
  fail "fichier de résultat du pinger absent"
fi

BODY=$(curl -s http://localhost:9080/ || echo "CURL_ERR")
echo "    Réponse après update: $BODY"
assert_contains <(echo "$BODY") "Version: 1.1.0" "Traefik sert la v1.1.0 après update"

# ------------------------------------------------------------------------------
# 5. Étape C : Re-push du MÊME tag 1.1.0 avec contenu changé → redéploie (Phase 4)
# ------------------------------------------------------------------------------
echo "==> 5. [RE-PUSH 1.1.0 contenu changé] Détection 'tag repoussé'..."
NEW_MARKER="repush-$$"
BUILD_MARKER="$NEW_MARKER" "${APP_DIR}/build-and-push.sh" "1.1.0" || { echo "ECHEC: re-push 1.1.0"; exit 1; }

run_autodeploy > "${SANDBOX_DIR}/deploy_repush.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && pass "re-push deploy exit 0" || fail "re-push deploy exit $RC"
assert_contains "${SANDBOX_DIR}/deploy_repush.log" "DIGEST différent" "digest différent détecté (tag repoussé)"
sleep 1
BODY=$(curl -s http://localhost:9080/ || echo "CURL_ERR")
echo "    Réponse après re-push: $BODY"
assert_contains <(echo "$BODY") "Marker: ${NEW_MARKER}" "le NOUVEAU contenu est servi (re-déploiement effectif)"

# ------------------------------------------------------------------------------
# 6. Étape D : Release 1.2.0 CASSÉE + Rollback
# ------------------------------------------------------------------------------
echo "==> 6. [RELEASE 1.2.0-BROKEN] /health en erreur 500 → rollback attendu..."
"${APP_DIR}/build-and-push.sh" "1.2.0" --broken || { echo "ECHEC: build 1.2.0"; exit 1; }

run_autodeploy > "${SANDBOX_DIR}/deploy_broken.log" 2>&1; RC=$?
if [ "$RC" -ne 0 ]; then
  pass "version cassée : le déploiement a échoué (exit $RC)"
else
  fail "version cassée NON détectée : le déploiement a 'réussi' (exit 0)"
fi
sleep 1
BODY=$(curl -s http://localhost:9080/ || echo "CURL_ERR")
echo "    Réponse (doit rester la v1.1.0): $BODY"
assert_contains <(echo "$BODY") "Version: 1.1.0" "la v1.1.0 stable sert toujours après rollback"
assert_not_contains <(echo "$BODY") "Version: 1.2.0" "la v1.2.0 cassée ne sert PAS"

# ------------------------------------------------------------------------------
# 7. Étape E : run 2 → SKIP du tag cassé (Phase 2, anti-récidive)
# ------------------------------------------------------------------------------
echo "==> 7. [RUN 2] Le tag cassé 1.2.0 doit être SKIPÉ sans pull/run..."
run_autodeploy > "${SANDBOX_DIR}/deploy_run2.log" 2>&1; RC=$?
[ "$RC" -eq 0 ] && pass "run 2 exit 0 (skip n'est pas une erreur)" || fail "run 2 exit $RC"
assert_contains "${SANDBOX_DIR}/deploy_run2.log" "déjà en échec" "run 2 : skip du tag en échec"
# Aucun conteneur candidat ne doit subsister
if docker ps -a --format '{{.Names}}' | grep -q "^sample-app-candidate$"; then
  fail "run 2 : un conteneur candidat subsiste"
else
  pass "run 2 : aucun candidat résiduel"
fi

# ------------------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------------------
echo ""
echo "======================================================================"
if [ "$FAILED" -eq 0 ]; then
  echo "    FLUX COMPLET TESTÉ AVEC SUCCÈS !"
  echo "======================================================================"
  echo "Pour détruire l'infrastructure de test (Registry & Traefik) :"
  echo "  (cd env/terraform && $IAC_BIN destroy -auto-approve)"
  echo "======================================================================"
  exit 0
else
  echo "    TEST EN ÉCHEC — voir les [ÉCHEC] ci-dessus."
  echo "======================================================================"
  exit 1
fi
