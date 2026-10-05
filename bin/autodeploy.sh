#!/usr/bin/env bash
# ==============================================================================
# Docker Autodeploy Engine with Traefik Zero-Downtime Rolling Update
# ==============================================================================
set -euo pipefail

# Chemins par défaut (peuvent être surchargés via variables d'environnement)
CONFIG_DIR="${AUTODEPLOY_CONFIG_DIR:-/etc/autodeploy}"
ENV_FILE="${CONFIG_DIR}/autodeploy.env"
APPS_DIR="${CONFIG_DIR}/apps.d"
LOCK_FILE="${AUTODEPLOY_LOCK_FILE:-/tmp/autodeploy.lock}"

# Codes couleur ANSI pour les logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() {
  local level="$1"
  shift
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$level" in
    INFO)    echo -e "${CYAN}[${timestamp}] [INFO]${NC} $*" ;;
    SUCCESS) echo -e "${GREEN}[${timestamp}] [SUCCESS]${NC} $*" ;;
    WARN)    echo -e "${YELLOW}[${timestamp}] [WARN]${NC} $*" ;;
    ERROR)   echo -e "${RED}[${timestamp}] [ERROR]${NC} $*" >&2 ;;
    STEP)    echo -e "${PURPLE}[${timestamp}] === $* ===${NC}" ;;
    *)       echo -e "[${timestamp}] $*" ;;
  esac
}

# Notification Webhook optionnelle (Slack, Discord, Teams, Mattermost, etc.)
send_webhook_notification() {
  local status="$1"
  local app_name="$2"
  local message="$3"

  if [[ -z "${WEBHOOK_URL:-}" ]]; then
    return 0
  fi

  local color=3066993 # Vert par défaut
  if [[ "$status" == "ERROR" ]]; then
    color=15158332 # Rouge
  elif [[ "$status" == "WARN" ]]; then
    color=16776960 # Jaune
  fi

  # Payload JSON compatible Discord/Slack
  local payload
  payload=$(cat <<EOF
{
  "content": null,
  "embeds": [
    {
      "title": "Autodeploy: ${app_name} [${status}]",
      "description": "${message}",
      "color": ${color},
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  ]
}
EOF
)

  curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

# Verrou d'exécution pour éviter les collisions si un run précédent est encore en cours
acquire_lock() {
  if command -v flock &>/dev/null; then
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
      log WARN "Une autre instance d'autodeploy est déjà en cours d'exécution. Abandon."
      exit 0
    fi
  else
    # Fallback portable (ex: macOS) basé sur mkdir atomique
    local lock_dir="${LOCK_FILE}.lockdir"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      log WARN "Une autre instance d'autodeploy est déjà en cours d'exécution (verrou: $lock_dir). Abandon."
      exit 0
    fi
    trap 'rm -rf "${LOCK_FILE}.lockdir"' EXIT
  fi
}

check_dependencies() {
  local missing=()
  for cmd in jq curl docker sort grep tail; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log ERROR "Dépendances manquantes sur le système : ${missing[*]}"
    exit 1
  fi
}

# Récupère le dernier tag sémantique (via API GitLab ou directement via l'API Docker Registry v2)
get_latest_semver_tag() {
  local project_id="$1"
  local gitlab_url="$2"
  local token="$3"
  local image_repo="$4"

  local latest=""

  # Mode 1 : API GitLab si un Project ID est spécifié
  if [[ -n "$project_id" && -n "$gitlab_url" ]]; then
    local response
    response=$(curl -s -f --header "PRIVATE-TOKEN: ${token}" \
      "${gitlab_url}/api/v4/projects/${project_id}/repository/tags" 2>/dev/null || echo "[]")
    latest=$(echo "$response" | jq -r '.[].name' 2>/dev/null | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' || true; } | sort -V | tail -n 1)
  fi

  # Mode 2 : API Docker Registry v2 (pour registre local ou standard sans GitLab)
  if [[ -z "$latest" && -n "$image_repo" ]]; then
    local host="${image_repo%%/*}"
    local path="${image_repo#*/}"
    local proto="https"
    if [[ "$host" =~ ^localhost(:[0-9]+)?$ || "$host" =~ ^127\.0\.0\.1(:[0-9]+)?$ ]]; then
      proto="http"
    fi

    local reg_user="${REGISTRY_USER:-${GITLAB_USER:-}}"
    local reg_pass="${REGISTRY_TOKEN:-${token:-}}"
    local reg_response
    if [[ -n "$reg_user" && -n "$reg_pass" ]]; then
      reg_response=$(curl -s -f -u "${reg_user}:${reg_pass}" "${proto}://${host}/v2/${path}/tags/list" 2>/dev/null || echo "{}")
    else
      reg_response=$(curl -s -f "${proto}://${host}/v2/${path}/tags/list" 2>/dev/null || echo "{}")
    fi
    latest=$(echo "$reg_response" | jq -r '.tags[]?' 2>/dev/null | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' || true; } | sort -V | tail -n 1)
  fi

  echo "$latest"
}

# Fonction principale de déploiement d'une application
deploy_application() {
  local conf_file="$1"

  # Valeurs par défaut
  local APP_NAME=""
  local IMAGE_REPO=""
  local GITLAB_PROJECT_ID=""
  local HEALTHCHECK_TIMEOUT=60
  local HEALTHCHECK_INTERVAL=2
  local DOCKER_RUN_ARGS=()
  local PRE_DEPLOY_CMD=""
  local POST_DEPLOY_CMD=""

  # Chargement de la conf applicative
  # shellcheck source=/dev/null
  source "$conf_file"

  if [[ -z "$APP_NAME" || -z "$IMAGE_REPO" ]]; then
    log ERROR "Configuration incomplète dans $conf_file (APP_NAME et IMAGE_REPO sont obligatoires)"
    return 1
  fi

  log STEP "Application : ${APP_NAME}"

  # 1. Recherche du dernier tag publié
  local latest_tag
  latest_tag=$(get_latest_semver_tag "${GITLAB_PROJECT_ID:-}" "${GITLAB_URL:-}" "${GITLAB_TOKEN:-}" "$IMAGE_REPO")

  if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
    log WARN "Aucun tag sémantique valide (ex: v1.0.0 ou 1.0.0) trouvé pour ${APP_NAME}."
    return 0
  fi

  local target_image="${IMAGE_REPO}:${latest_tag}"
  local current_container="${APP_NAME}"
  local next_container="${APP_NAME}-candidate"

  # 2. Détection de l'image actuelle en production
  local current_image=""
  if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
    current_image=$(docker inspect --format '{{.Config.Image}}' "$current_container" 2>/dev/null || echo "")
  fi

  if [[ "$current_image" == "$target_image" ]]; then
    log INFO "L'application ${APP_NAME} est déjà à jour avec l'image : ${target_image}"
    return 0
  fi

  log INFO "Mise à jour requise pour ${APP_NAME} :"
  log INFO "  Version actuelle : ${current_image:-[aucun conteneur en cours]}"
  log INFO "  Version cible    : ${target_image}"

  # 3. Pull de la nouvelle image
  log INFO "Pulling image ${target_image}..."
  if ! docker pull "$target_image"; then
    log ERROR "Échec du docker pull pour ${target_image}."
    send_webhook_notification "ERROR" "$APP_NAME" "Échec du pull docker pour la version ${latest_tag}"
    return 1
  fi

  # Hook pre-deploy si défini
  if [[ -n "$PRE_DEPLOY_CMD" ]]; then
    log INFO "Exécution du hook pre-deploy..."
    eval "$PRE_DEPLOY_CMD"
  fi

  # Nettoyage préventif d'un ancien conteneur candidat résiduel
  docker rm -f "$next_container" >/dev/null 2>&1 || true

  # 4. Lancement du conteneur candidat en parallèle
  log INFO "Démarrage du conteneur candidat '${next_container}'..."
  if ! docker run -d --name "$next_container" "${DOCKER_RUN_ARGS[@]}" "$target_image" >/dev/null; then
    log ERROR "Impossible de démarrer le conteneur candidat ${next_container}."
    send_webhook_notification "ERROR" "$APP_NAME" "Échec du docker run pour la version ${latest_tag}"
    return 1
  fi

  # 5. Surveillance du Healthcheck
  log INFO "Attente de la validation du Healthcheck (Timeout: ${HEALTHCHECK_TIMEOUT}s)..."
  local healthy=false
  local elapsed=0

  while [[ $elapsed -lt $HEALTHCHECK_TIMEOUT ]]; do
    local state_status
    local health_status

    state_status=$(docker inspect --format '{{.State.Status}}' "$next_container" 2>/dev/null || echo "dead")
    health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$next_container" 2>/dev/null || echo "dead")

    # Si le conteneur a craché ou est sorti
    if [[ "$state_status" == "exited" || "$state_status" == "dead" ]]; then
      log ERROR "Le conteneur s'est arrêté inopinément (Status: ${state_status})."
      break
    fi

    # Si un HEALTHCHECK Docker est configuré et passe à healthy
    if [[ "$health_status" == "healthy" ]]; then
      healthy=true
      break
    fi

    # Si AUCUN HEALTHCHECK Docker n'est défini, on attend qu'il soit 'running' pendant au moins 6s
    if [[ "$health_status" == "none" && "$state_status" == "running" && $elapsed -ge 6 ]]; then
      healthy=true
      break
    fi

    # Si le conteneur est explicitement unhealthy
    if [[ "$health_status" == "unhealthy" ]]; then
      log ERROR "Le healthcheck a retourné : unhealthy"
      break
    fi

    sleep "$HEALTHCHECK_INTERVAL"
    elapsed=$((elapsed + HEALTHCHECK_INTERVAL))
  done

  # 6. Décision : Bascule ou Rollback
  if [[ "$healthy" == "true" ]]; then
    log SUCCESS "Le conteneur candidat est opérationnel ! Démarrage de la bascule Traefik..."

    # Pause tampon (2 secondes) pour laisser le temps à Traefik de découvrir et répercuter le nouveau backend
    sleep 2

    # Arrêt propre de l'ancien conteneur
    if docker ps -a --format '{{.Names}}' | grep -q "^${current_container}$"; then
      log INFO "Arrêt de l'ancien conteneur (${current_container})..."
      docker stop -t 15 "$current_container" >/dev/null 2>&1 || docker kill "$current_container" >/dev/null 2>&1
      docker rm "$current_container" >/dev/null 2>&1
    fi

    # Renommage du candidat pour prendre le nom définitif
    docker rename "$next_container" "$current_container"
    sleep 2

    # Hook post-deploy si défini
    if [[ -n "$POST_DEPLOY_CMD" ]]; then
      log INFO "Exécution du hook post-deploy..."
      eval "$POST_DEPLOY_CMD"
    fi

    log SUCCESS "Déploiement réussi avec succès : ${APP_NAME} tourne sur ${latest_tag}"
    send_webhook_notification "SUCCESS" "$APP_NAME" "Mise à jour réussie vers ${latest_tag}"
    return 0

  else
    log ERROR "ÉCHEC DU DÉPLOIEMENT : Le conteneur candidat n'a pas validé sa santé !"
    log WARN "Démarrage de la procédure de Rollback / Nettoyage..."

    # On extrait les 30 dernières lignes de logs pour faciliter le diagnostic
    log WARN "Dernières logs du conteneur en échec (${next_container}) :"
    docker logs --tail 30 "$next_container" 2>&1 | sed 's/^/    [CONTAINER LOG] /' >&2 || true

    # Destruction du candidat
    docker stop -t 5 "$next_container" >/dev/null 2>&1 || true
    docker rm -f "$next_container" >/dev/null 2>&1 || true

    if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
      log SUCCESS "L'ancien conteneur ${current_container} est toujours actif. Zéro impact utilisateur."
    else
      log WARN "Attention : Aucun ancien conteneur n'était actif avant ce déploiement."
    fi

    send_webhook_notification "ERROR" "$APP_NAME" "Échec du déploiement vers ${latest_tag}. Rollback automatique effectué."
    return 1
  fi
}

# ==============================================================================
# Point d'entrée
# ==============================================================================
main() {
  acquire_lock
  check_dependencies

  if [[ ! -f "$ENV_FILE" ]]; then
    log ERROR "Fichier d'environnement introuvable: ${ENV_FILE}"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$ENV_FILE"

  # Authentification Docker Registry (JFrog Artifactory, GitLab Registry, etc.)
  local reg_host="${REGISTRY_HOST:-${GITLAB_REGISTRY:-}}"
  local reg_user="${REGISTRY_USER:-${GITLAB_USER:-}}"
  local reg_pass="${REGISTRY_TOKEN:-${GITLAB_TOKEN:-}}"

  if [[ -n "$reg_host" && -n "$reg_pass" ]]; then
    log INFO "Authentification au registre Docker ${reg_host}..."
    echo "$reg_pass" | docker login "$reg_host" \
      -u "${reg_user:-deploy-token}" \
      --password-stdin >/dev/null 2>&1 || {
        log ERROR "Échec de l'authentification Docker au registre ${reg_host}"
        exit 1
      }
  fi

  # Parcours des configurations d'applications
  local conf_count=0
  local success_count=0
  local error_count=0

  shopt -s nullglob
  local config_files=("${APPS_DIR}"/*.conf)
  shopt -u nullglob

  if [[ ${#config_files[@]} -eq 0 ]]; then
    log WARN "Aucun fichier de configuration .conf trouvé dans ${APPS_DIR}."
    exit 0
  fi

  for conf in "${config_files[@]}"; do
    ((conf_count++))
    if deploy_application "$conf"; then
      ((success_count++))
    else
      ((error_count++))
    fi
  done

  # Nettoyage automatique des images orphelines (dangling)
  if [[ "${AUTO_PRUNE_IMAGES:-true}" == "true" ]]; then
    log INFO "Nettoyage des images Docker non référencées..."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  log INFO "Fin du cycle de vérification : ${conf_count} apps inspectées, ${error_count} erreurs."
}

main "$@"
