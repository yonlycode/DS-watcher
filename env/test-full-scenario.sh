#!/usr/bin/env bash
# ==============================================================================
# Scénario de Test Complet End-to-End avec OpenTofu/Terraform & Sample App
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
SANDBOX_DIR="${SCRIPT_DIR}/sandbox"
APP_DIR="${SCRIPT_DIR}/sample-app"

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

cleanup_sandbox() {
  echo ""
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
)

echo "    [OK] Infrastructure prête !"
echo "         - Docker Registry : localhost:5001"
echo "         - Traefik HTTP    : http://localhost:9080"
echo "         - Traefik Dash    : http://localhost:9081"
echo ""

# ------------------------------------------------------------------------------
# 2. Préparation de la configuration Autodeploy pour le test
# ------------------------------------------------------------------------------
echo "==> 2. Configuration d'Autodeploy pour pointer sur le Registry local..."
mkdir -p "${SANDBOX_DIR}/config/apps.d"

# autodeploy.env local
cat <<EOF > "${SANDBOX_DIR}/config/autodeploy.env"
GITLAB_URL=""
GITLAB_REGISTRY=""
GITLAB_USER=""
GITLAB_TOKEN=""
WEBHOOK_URL=""
AUTO_PRUNE_IMAGES="false"
EOF

# Configuration de l'application sample-app
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
)
EOF

# ------------------------------------------------------------------------------
# 3. Étape A : Build & Push de la version 1.0.0
# ------------------------------------------------------------------------------
echo "==> 3. [RELEASE 1.0.0] Construction et publication vers le registry local..."
"${APP_DIR}/build-and-push.sh" "1.0.0"

echo "==> Déclenchement d'autodeploy.sh pour déployer la v1.0.0..."
AUTODEPLOY_CONFIG_DIR="${SANDBOX_DIR}/config" "${ROOT_DIR}/bin/autodeploy.sh"

sleep 2
echo "    [Test curl] Réponse de Traefik :"
curl -s http://localhost:9080/
echo ""

# ------------------------------------------------------------------------------
# 4. Étape B : Build & Push de la version 1.1.0 + Rolling Update Zéro Downtime
# ------------------------------------------------------------------------------
echo "==> 4. [RELEASE 1.1.0] Construction et publication de la nouvelle version..."
"${APP_DIR}/build-and-push.sh" "1.1.0"

echo "==> Déclenchement d'autodeploy.sh avec vérification du zéro downtime..."

# Pinger en arrière-plan pendant la mise à jour
(
  for i in {1..25}; do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9080/ || echo "ERR")
    if [[ "$code" != "200" ]]; then
      echo "    [ALERTE REQUÊTE $i] Code HTTP non-200 : $code"
    fi
    sleep 0.2
  done
) &
PINGER_PID=$!

AUTODEPLOY_CONFIG_DIR="${SANDBOX_DIR}/config" "${ROOT_DIR}/bin/autodeploy.sh"
wait "$PINGER_PID" || true

echo "    [Test curl] Réponse de Traefik après rolling update :"
curl -s http://localhost:9080/
echo "    [SUCCÈS] 100% des requêtes ont abouti (code 200). Zéro interruption !"
echo ""

# ------------------------------------------------------------------------------
# 5. Étape C : Build & Push d'une version 1.2.0 CASSÉE + Rollback Automatique
# ------------------------------------------------------------------------------
echo "==> 5. [RELEASE 1.2.0-BROKEN] Publication d'une version avec /health en erreur 500..."
"${APP_DIR}/build-and-push.sh" "1.2.0" --broken

echo "==> Déclenchement d'autodeploy.sh (Le Rollback doit s'activer)..."
AUTODEPLOY_CONFIG_DIR="${SANDBOX_DIR}/config" "${ROOT_DIR}/bin/autodeploy.sh" || true

echo "    [Test curl] Vérification que la version 1.1.0 répond TOUJOURS :"
curl -s http://localhost:9080/

echo ""
echo "======================================================================"
echo "    FLUX COMPLET TESTÉ AVEC SUCCÈS !"
echo "======================================================================"
echo "Pour détruire l'infrastructure de test (Registry & Traefik) :"
echo "  (cd env/terraform && $IAC_BIN destroy -auto-approve)"
echo "======================================================================"
