#!/usr/bin/env bash
# ==============================================================================
# Docker Autodeploy Engine with Traefik Zero-Downtime Rolling Update
# ==============================================================================
set -euo pipefail

# Chemins par défaut (peuvent être surchargés via variables d'environnement)
CONFIG_DIR="${AUTODEPLOY_CONFIG_DIR:-/etc/autodeploy}"
ENV_FILE="${CONFIG_DIR}/autodeploy.env"
APPS_DIR="${CONFIG_DIR}/apps.d"
# Verrou d'exécution : /run/autodeploy/lock, root-only (0700 sur le répertoire).
# JAMAIS /tmp : systemd-tmpfiles y supprime les fichiers anciens/inactifs, y compris
# un lock encore tenu par un run en cours. Le lock disparu, un second cycle part en
# pleine bascule (stop de l'ancien + rename du candidat) = outage garanti.
# /run est un tmpfs systemd non soumis à ce nettoyage, et vierge à chaque boot
# (aucun lock fantôme hérité d'un crash précédent).
LOCK_FILE="${AUTODEPLOY_LOCK_FILE:-/run/autodeploy/lock}"
# État persistant par app (évite la boucle de récidive sur un tag cassé).
STATE_DIR="${AUTODEPLOY_STATE_DIR:-/var/lib/autodeploy}"

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

  # Payload JSON construit avec jq (échappement correct du message ; un guillemet
  # dans le message ne doit pas casser le JSON ni injecter des champs).
  local payload
  payload=$(jq -n \
    --arg title "Autodeploy: ${app_name} [${status}]" \
    --arg description "$message" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson color "$color" \
    '{content: null, embeds: [{title: $title, description: $description, color: $color, timestamp: $ts}]}')

  curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

# S'assure que le répertoire du verrou existe en 0700 (root-only).
# En dev non-root, /run n'est pas créible : on replie sur $TMPDIR avec un WARN.
# Le repli a exactement les faiblesses de /tmp qu'on dénonce, donc il doit se VOIR.
ensure_lock_dir() {
  local dir fallback
  dir="$(dirname "$LOCK_FILE")"
  if [[ -d "$dir" && -w "$dir" ]]; then
    chmod 700 "$dir" 2>/dev/null || true
    return 0
  fi
  if mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    return 0
  fi
  fallback="${TMPDIR:-/tmp}/autodeploy.lock"
  log WARN "Répertoire de verrou '${dir}' non créible (besoin de root). Repli sur '${fallback}' : acceptable en dev, PAS en prod (systemd-tmpfiles peut y supprimer un lock actif)."
  LOCK_FILE="$fallback"
}

# Verrou d'exécution pour éviter les collisions si un run précédent est encore en cours
acquire_lock() {
  ensure_lock_dir
  if command -v flock &>/dev/null; then
    exec 200>"$LOCK_FILE"
    chmod 600 "$LOCK_FILE" 2>/dev/null || true
    if ! flock -n 200; then
      log WARN "Une autre instance d'autodeploy est déjà en cours d'exécution. Abandon."
      exit 0
    fi
  else
    # Fallback portable (ex: macOS, pas de flock) basé sur mkdir atomique.
    # mkdir est atomique et survit au shell : pas de race sur un fichier commun.
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

# Exécute une commande sous limite de temps wall-clock.
# timeout(1) est utilisé s'il existe (coreutils: "timeout" sous Linux, "gtimeout"
# sous macOS). Sinon, watchdog bash maison : sans lui, un `docker pull` suspendu sur
# un registre qui ne répond pas (TCP ouvert, aucune donnée) bloquerait le cycle
# indéfiniment — et un cycle sans plafond + TimeoutStartSec=infinity = gel total.
# Retour : code de la commande, 124 si la limite est atteinte (convention timeout).
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    local rc=0 pid watcher
    "$@" &
    pid=$!
    (
      local waited=0
      while [[ $waited -lt $secs ]]; do
        kill -0 "$pid" 2>/dev/null || exit 0
        sleep 1
        waited=$((waited + 1))
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    ) &
    watcher=$!
    wait "$pid" || rc=$?
    # Le fils est sorti : on récupère le watcher (il n'a plus de raison de vivre).
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    # 137 = 128+9 : tué par notre watchdog. On normalise en 124 comme timeout(1).
    [[ $rc -eq 137 ]] && rc=124
    return $rc
  fi
}

# ==============================================================================
# État persistant par application (Phase 2)
# Fichier clé=valeur : $STATE_DIR/<app>.state
#   last_deployed_tag / last_deployed_digest / last_failed_tag / failed_count / last_failed_at
# ==============================================================================
ensure_state_dir() {
  # Créé à la volée (700) pour que le script tourne aussi hors install.sh (tests).
  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null || \
      log WARN "Impossible de créer STATE_DIR ${STATE_DIR} (persistance désactivée)."
  fi
}

state_file() { printf '%s/%s.state' "$STATE_DIR" "$1"; }

# state_get <app> <key> -> valeur (vide si absente)
state_get() {
  local file
  file="$(state_file "$1")"
  [[ -f "$file" ]] || return 0
  grep -E "^$2=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

# state_set <app> key=value key=value ... — fusionne sans écraser les autres clés,
# écriture atomique (tmp + mv).
state_set() {
  local app="$1"; shift
  local file tmp
  file="$(state_file "$app")"
  tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX" 2>/dev/null || mktemp)"
  # On repart de l'existant, puis on applique les overrides.
  if [[ -f "$file" ]]; then
    cat "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  local kv key
  for kv in "$@"; do
    key="${kv%%=*}"
    grep -v "^${key}=" "$tmp" > "${tmp}.2" 2>/dev/null || cp "$tmp" "${tmp}.2"
    printf '%s\n' "$kv" >> "${tmp}.2"
    mv "${tmp}.2" "$tmp"
  done
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

# Efface les clés d'échec (après un déploiement réussi de ce tag).
state_clear_failed() {
  local app="$1" file tmp
  file="$(state_file "$app")"
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${STATE_DIR}/.state.XXXXXX" 2>/dev/null || mktemp)"
  grep -vE '^(last_failed_tag|failed_count|last_failed_at)=' "$file" > "$tmp" || true
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

# ==============================================================================
# Récupère le dernier tag sémantique (via API GitLab ou directement via l'API Docker Registry v2).
#
# Codes de retour :
#   0 + sortie non vide = tag trouvé
#   0 + sortie vide     = registre joignable mais aucun tag sémantique (WARN légitime)
#   2                   = ERREUR (auth 401/403, repo 404, réseau, HTTP inattendu).
#                       L'appelant doit alerter et SKIPER l'app — surtout pas traiter
#                       ça comme "aucune nouvelle version, tout va bien".
get_latest_semver_tag() {
  local project_id="$1"
  local gitlab_url="$2"
  local token="$3"
  local image_repo="$4"

  local latest=""
  local tmp_body tmp_hdr http_code netrc_file=""
  tmp_body=$(mktemp)
  tmp_hdr=$(mktemp)
  trap 'rm -f "$tmp_body" "$tmp_hdr" ${netrc_file:+"$netrc_file"}' RETURN

  # Mode 1 (LEGACY) : API GitLab si un Project ID est spécifié.
  # Dans ce contexte (registre = JFrog Artifactory), ce mode est un fallback mort :
  # le chemin de prod est le Mode 2 (API Registry v2). Gardé pour compatibilité.
  if [[ -n "$project_id" && -n "$gitlab_url" ]]; then
    http_code=$(curl -s -o "$tmp_body" -w '%{http_code}' \
      --header "PRIVATE-TOKEN: ${token}" \
      "${gitlab_url}/api/v4/projects/${project_id}/repository/tags" 2>/dev/null) || http_code="000"
    case "$http_code" in
      200)
        latest=$(jq -r '.[].name' "$tmp_body" 2>/dev/null | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' || true; } | sort -V | tail -n 1)
        ;;
      401|403) log ERROR "Auth refusée sur GitLab ${gitlab_url} (token expiré ?)"; return 2 ;;
      404)     log ERROR "Projet GitLab '${project_id}' introuvable sur ${gitlab_url}"; return 2 ;;
      000)     log ERROR "Erreur réseau en interrogeant GitLab ${gitlab_url}"; return 2 ;;
      *)       log ERROR "HTTP ${http_code} sur GitLab ${gitlab_url}"; return 2 ;;
    esac
  fi

  # Mode 2 : API Docker Registry v2 (JFrog Artifactory, registry local, etc.) — chemin de prod.
  # Artifactory accepte le Basic auth direct sur /v2/ (pas de dance OAuth bearer).
  if [[ -z "$latest" && -n "$image_repo" ]]; then
    local host="${image_repo%%/*}"
    local path="${image_repo#*/}"
    local proto="https"
    if [[ "$host" =~ ^localhost(:[0-9]+)?$ || "$host" =~ ^127\.0\.0\.1(:[0-9]+)?$ ]]; then
      proto="http"
    fi

    local reg_user="${REGISTRY_USER:-${GITLAB_USER:-}}"
    local reg_pass="${REGISTRY_TOKEN:-${token:-}}"
    local all_tags=""
    local next_url="${proto}://${host}/v2/${path}/tags/list"
    local page=0

    # Auth via netrc : découple user/password sans fusion "user:pass" ambiguë,
    # et reste portable (certains builds curl minimal, ex: Alpine, n'ont pas
    # l'option --password). Fichier 600 hors boucle, nettoyé au RETURN.
    local netrc_opt=()
    if [[ -n "$reg_user" && -n "$reg_pass" ]]; then
      local machine_name
      netrc_file=$(mktemp)
      chmod 600 "$netrc_file"
      machine_name="${host%%:*}"
      printf 'machine %s login %s password %s\n' "$machine_name" "$reg_user" "$reg_pass" > "$netrc_file"
      netrc_opt=(--netrc-file "$netrc_file")
    fi

    # Artifactory peut paginer tags/list sur les gros repos : suivre Link: rel="next"
    # (cap défensif à 10 pages) pour que sort -V voie bien TOUS les tags.
    while [[ -n "$next_url" && $page -lt 10 ]]; do
      page=$((page + 1))
      http_code=$(curl -s -o "$tmp_body" -D "$tmp_hdr" -w '%{http_code}' \
        ${netrc_opt[@]+"${netrc_opt[@]}"} "$next_url" 2>/dev/null) || http_code="000"

      case "$http_code" in
        200)
          all_tags+=$(jq -r '.tags[]?' "$tmp_body" 2>/dev/null || true)
          all_tags+=$'\n'
          next_url=$(grep -i '^link:' "$tmp_hdr" 2>/dev/null \
            | tr ',' '\n' | grep 'rel="next"' \
            | sed -E 's/.*<([^>]*)>.*/\1/' | head -n 1 || true)
          ;;
        401|403) log ERROR "Auth refusée sur le registre ${host} (API key expirée ?)"; return 2 ;;
        404)     log ERROR "Repo '${path}' introuvable sur ${host} (mauvais chemin Artifactory ?)"; return 2 ;;
        000)     log ERROR "Erreur réseau en interrogeant le registre ${host}"; return 2 ;;
        *)       log ERROR "HTTP ${http_code} sur le registre ${host}"; return 2 ;;
      esac
    done

    latest=$(echo "$all_tags" | { grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+' || true; } | sort -V | tail -n 1)
  fi

  echo "$latest"
}

# Digest distant via HEAD sur le manifest (Phase 4). Retourne le Docker-Content-Digest
# vide si indisponible (le comparateur traitera alors "non comparable" sans boucle).
# Accept large (list + schema2 + OCI) pour que le digest renvoyé corresponde à celui
# que `docker pull` a stocké dans RepoDigests (sinus multi-arch = faux changement).
get_remote_digest() {
  local image_repo="$1" tag="$2"
  local host="${image_repo%%/*}"
  local path="${image_repo#*/}"
  local proto="https"
  if [[ "$host" =~ ^localhost(:[0-9]+)?$ || "$host" =~ ^127\.0\.0\.1(:[0-9]+)?$ ]]; then
    proto="http"
  fi
  local reg_user="${REGISTRY_USER:-${GITLAB_USER:-}}"
  local reg_pass="${REGISTRY_TOKEN:-${GITLAB_TOKEN:-}}"

  local hdr netrc_file=""
  hdr=$(mktemp)
  trap 'rm -f "$hdr" ${netrc_file:+"$netrc_file"}' RETURN

  local netrc_opt=()
  if [[ -n "$reg_user" && -n "$reg_pass" ]]; then
    netrc_file=$(mktemp)
    chmod 600 "$netrc_file"
    printf 'machine %s login %s password %s\n' "${host%%:*}" "$reg_user" "$reg_pass" > "$netrc_file"
    netrc_opt=(--netrc-file "$netrc_file")
  fi

  curl -s -I -D "$hdr" ${netrc_opt[@]+"${netrc_opt[@]}"} \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json" \
    "${proto}://${host}/v2/${path}/manifests/${tag}" >/dev/null 2>&1 || return 0

  grep -i '^docker-content-digest:' "$hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' | head -n 1 || true
}

# Attente active de la découverte du candidat par Traefik (Phase 3, optionnel).
# Le provider Docker de Traefik NE lit PAS .State.Health de Docker : il route dès la
# découverte des labels. Si l'API Traefik est exposée (TRAEFIK_API_URL), on vérifie
# réellement que le candidat est dans les serveurs du service avant de tuer l'ancien.
# Sinon, on retombe sur le sleep tampon classique.
wait_traefik_discovery() {
  local app="$1" candidate="$2"
  if [[ -z "${TRAEFIK_API_URL:-}" ]]; then
    sleep 2
    return 0
  fi
  local cand_ip
  cand_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$candidate" 2>/dev/null | awk '{print $1; exit}')
  if [[ -z "$cand_ip" ]]; then
    log WARN "IP du candidat introuvable pour la vérification Traefik, fallback sleep 2."
    sleep 2
    return 0
  fi
  local svc="${app}@docker"
  local url="${TRAEFIK_API_URL%/}/api/http/services/${svc}"
  local waited=0 timeout=10
  log INFO "Attente active : découverte du candidat (${cand_ip}) par Traefik (${svc})..."
  while [[ $waited -lt $timeout ]]; do
    if curl -s --max-time 2 "$url" 2>/dev/null | grep -q "$cand_ip"; then
      log SUCCESS "Traefik a découvert le candidat (${cand_ip})."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log WARN "Traefik n'a pas confirmé le candidat en ${timeout}s (fallback sleep 2)."
  sleep 2
}

# ==============================================================================
# Hooks de déploiement (Phase 6)
# Un hook est du shell arbitraire fourni par la conf applicative. Lançé nu dans un
# `eval`, il est : invisible (aucune trace de QUEL hook a cassé), non borné, et
# son échec tue le script entier sous `set -e` AVANT tout webhook ni nettoyage.
# Le wrapper impose :
#   - log d'entrée : le NOM du hook + la commande exacte exécutée
#   - capture du code de sortie (aucune propagation brute dans `set -e`)
#   - webhook d'alerte qui identifie le hook fautif et son exit code
#   - code de retour non nul = l'appelant avorte ce déploiement
# Contrat de sécurité : le hook vient d'un fichier de conf root-only (0600) écrit
# par l'admin, pas d'une source non fiable. C'est du code de confiance, documenté.
#
# Variables EXPOSÉES au hook (exportées, donc visibles aussi par ses sous-processus) :
#   HOOK_PHASE         "pre-deploy" | "post-deploy"
#   APP_NAME           nom logique de l'app (ex: mon-api)
#   IMAGE_REPO         dépôt d'image sans tag
#   LATEST_TAG         tag sémantique résolu (ex: 1.4.2)
#   TARGET_IMAGE       image complète déployée (repo:tag)
#   CURRENT_CONTAINER  nom du conteneur en prod (ex: mon-api)
#   NEXT_CONTAINER     nom du conteneur candidat (ex: mon-api-candidate)
#   CONF_FILE          chemin du fichier .conf source
# ==============================================================================
run_hook() {
  local phase="$1" cmd="$2" app="$3" tag="$4"
  [[ -z "$cmd" ]] && return 0

  # Variables exposées (lecture via portée dynamique dans le caller).
  export HOOK_PHASE="$phase"
  export APP_NAME="$app"
  export LATEST_TAG="$tag"
  export TARGET_IMAGE="${target_image:-}"
  export CURRENT_CONTAINER="${current_container:-}"
  export NEXT_CONTAINER="${next_container:-}"
  export IMAGE_REPO="${IMAGE_REPO:-}"
  export CONF_FILE="${conf_file:-}"

  log INFO "Hook ${phase} de ${app} : ${cmd}"
  local rc=0
  # Le hook s'exécute dans un SOUS-SHELL, et ce n'est pas cosmétique : dans un
  # `eval` à plat, un `exit N` du hook (réflexe normal d'un script appelé, et ce
  # que fait tout script shell qui rencontre une erreur) remonte et TUÉ le moteur
  # entier. Le cycle mourait donc avant la persistance de l'état, avant le webhook
  # et avant le nettoyage — soit exactement ce que ce wrapper doit éviter.
  # En sous-shell, `exit N` veut dire "ce hook échoue de N" et rien d'autre.
  # Corollaire assumé : un hook ne peut pas modifier l'état interne du moteur ;
  # il reçoit les variables exposées, il ne les renvoie pas.
  # shellcheck disable=SC2091
  ( eval "$cmd" ) || rc=$?

  if [[ $rc -ne 0 ]]; then
    log ERROR "Hook ${phase} de ${app} en ÉCHEC (exit ${rc}) — commande : ${cmd}"
    send_webhook_notification "ERROR" "$app" "Hook ${phase} en échec (exit ${rc}) sur ${app} / tag ${tag}. Commande : ${cmd}"
    return "$rc"
  fi

  log SUCCESS "Hook ${phase} de ${app} terminé (exit 0)."
  return 0
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
  # Budget max du `docker pull` par app. Un registre qui garde le socket ouvert
  # sans envoyer de données gèlerait le cycle sans cette borne.
  local PULL_TIMEOUT=300
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
  # NB: `|| rc=$?` indispensable sous set -e : une substitution de commande qui
  # échoue tuerait le script sans distinction erreur/vide.
  local latest_tag rc=0
  latest_tag=$(get_latest_semver_tag "${GITLAB_PROJECT_ID:-}" "${GITLAB_URL:-}" "${GITLAB_TOKEN:-}" "$IMAGE_REPO") || rc=$?

  if [[ $rc -eq 2 ]]; then
    log ERROR "Impossible d'interroger les tags pour ${APP_NAME} (voir erreurs ci-dessus). App skippée, le cycle continue."
    send_webhook_notification "ERROR" "$APP_NAME" "Erreur de registre/API en interrogeant ${IMAGE_REPO} (auth, 404 ou réseau) — app skippée."
    return 1
  fi

  if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
    log WARN "Aucun tag sémantique valide (ex: v1.0.0 ou 1.0.0) trouvé pour ${APP_NAME}."
    return 0
  fi

  local target_image="${IMAGE_REPO}:${latest_tag}"
  local current_container="${APP_NAME}"
  local next_container="${APP_NAME}-candidate"

  # 1b. Garde anti-récidive (Phase 2) : si ce tag a déjà échoué, on ne le
  # redéploie pas en boucle (sinon : pull+run+unhealthy+webhook toutes les 2 min
  # jusqu'à ce qu'un humain intervienne). --force <app> passe outre.
  local last_failed failed_count_prev
  last_failed="$(state_get "$APP_NAME" last_failed_tag)"
  failed_count_prev="$(state_get "$APP_NAME" failed_count)"
  if [[ -n "$last_failed" && "$latest_tag" == "$last_failed" && "$APP_NAME" != "${FORCE_APP:-}" ]]; then
    log WARN "Tag ${latest_tag} déjà en échec (${failed_count_prev:-?}x). Skip. Forcer avec : autodeploy.sh --force ${APP_NAME}"
    return 0
  fi

  # 2. Détection de l'image actuelle + comparaison par DIGEST (Phase 4)
  # RepoDigests est une propriété de l'IMAGE, pas du conteneur : on passe par
  # .Image (id) puis `docker image inspect`. Une image buildée localement (jamais
  # pullée) n'a pas de digest → "non comparable".
  local current_image="" current_digest=""
  if docker ps --format '{{.Names}}' | grep -q "^${current_container}$"; then
    current_image=$(docker inspect --format '{{.Config.Image}}' "$current_container" 2>/dev/null || echo "")
    local cur_img_id
    cur_img_id=$(docker inspect --format '{{.Image}}' "$current_container" 2>/dev/null || echo "")
    if [[ -n "$cur_img_id" ]]; then
      current_digest=$(docker image inspect --format '{{range .RepoDigests}}{{.}}\n{{end}}' "$cur_img_id" 2>/dev/null | head -n 1 || echo "")
    fi
  fi

  # Digest distant (HEAD manifest). Vide si indisponible.
  local target_digest
  target_digest=$(get_remote_digest "$IMAGE_REPO" "$latest_tag")

  # Digest de référence : celui enregistré dans l'état au dernier déploiement réussi.
  # C'est un VRAI digest registre, contrairement à RepoDigests du conteneur courant
  # qui est vide quand l'image a été buildée localement (cas du test / dev).
  local ref_digest
  ref_digest="$(state_get "$APP_NAME" last_deployed_digest)"
  [[ -z "$ref_digest" ]] && ref_digest="$current_digest"

  if [[ "$current_image" == "$target_image" ]]; then
    if [[ -n "$ref_digest" && -n "$target_digest" ]]; then
      if [[ "$ref_digest" == "$target_digest" ]]; then
        log INFO "L'application ${APP_NAME} est déjà à jour (tag + digest identiques) : ${target_image}"
        return 0
      else
        log WARN "Tag identique mais DIGEST différent (tag repoussé, contenu changé) → redéploiement."
        log WARN "  digest déployé : ${ref_digest}"
        log WARN "  digest distant : ${target_digest}"
        # On ne return PAS : on tombe dans le déploiement ci-dessous.
      fi
    else
      # Digest non comparable d'un côté au moins : on ne peut pas prouver un
      # changement. Comportement non boucle : tag identique = à jour (sinon un
      # HEAD qui échoue ferait redéployer à chaque cycle).
      log INFO "L'application ${APP_NAME} est à jour (tag identique, digest non comparable) : ${target_image}"
      return 0
    fi
  fi

  log INFO "Mise à jour requise pour ${APP_NAME} :"
  log INFO "  Version actuelle : ${current_image:-[aucun conteneur en cours]}"
  log INFO "  Version cible    : ${target_image}"

  # 3. Pull de la nouvelle image (borné dans le temps — voir PULL_TIMEOUT)
  log INFO "Pulling image ${target_image} (max ${PULL_TIMEOUT}s)..."
  local pull_rc=0
  run_with_timeout "$PULL_TIMEOUT" docker pull "$target_image" || pull_rc=$?
  if [[ $pull_rc -ne 0 ]]; then
    if [[ $pull_rc -eq 124 ]]; then
      log ERROR "Pull de ${target_image} interrompu : limite de ${PULL_TIMEOUT}s dépassée (registre lent ou suspendu)."
      send_webhook_notification "ERROR" "$APP_NAME" "Pull interrompu après ${PULL_TIMEOUT}s pour ${latest_tag} (registre lent/suspendu) — app skippée."
    else
      log ERROR "Échec du docker pull pour ${target_image} (exit ${pull_rc})."
      send_webhook_notification "ERROR" "$APP_NAME" "Échec du pull docker pour la version ${latest_tag}"
    fi
    return 1
  fi

  # 3b. Garde d'intégrité : le HEALTHCHECK Docker est la SEULE source de vérité du
  # script sur la préparation du candidat. Sans lui, "le conteneur tourne" ne veut
  # pas dire "l'app sert du contenu" : une app qui crash-loop lentement, qui ne
  # bind pas son port ou qui démarre en mode dégradé passerait quand même la bascule.
  # Par défaut : pas de HEALTHCHECK = REFUS de déployer (pas de validation implicite).
  # Opt-in explicite et assumé, par app : ALLOW_NO_HEALTHCHECK=true
  # (valeurs vues sur le terrain : "ABSENT" = pas de HEALTHCHECK, "NONE" = HEALTHCHECK NONE).
  local hc_test has_healthcheck=true
  hc_test=$(docker image inspect --format '{{if .Config.Healthcheck}}{{join .Config.Healthcheck.Test " "}}{{else}}ABSENT{{end}}' "$target_image" 2>/dev/null || echo "ABSENT")
  if [[ -z "$hc_test" || "$hc_test" == "ABSENT" || "$hc_test" == "NONE" ]]; then
    has_healthcheck=false
  fi

  if [[ "$has_healthcheck" != "true" && "${ALLOW_NO_HEALTHCHECK:-false}" != "true" ]]; then
    log ERROR "${APP_NAME} : l'image ${target_image} n'a AUCUN HEALTHCHECK Docker. Déploiement REFUSÉ."
    log ERROR "  Sans healthcheck, rien ne distingue 'l'app sert du contenu' de 'le process tourne dans le vide'."
    log ERROR "  Corriger le Dockerfile (HEALTHCHECK ...), ou assumer le risque : ALLOW_NO_HEALTHCHECK=true dans ${conf_file}"
    send_webhook_notification "ERROR" "$APP_NAME" "Déploiement refusé : image sans HEALTHCHECK Docker (tag ${latest_tag}). Ajouter HEALTHCHECK au Dockerfile, ou ALLOW_NO_HEALTHCHECK=true pour assumer."
    return 1
  fi
  if [[ "$has_healthcheck" != "true" ]]; then
    log WARN "${APP_NAME} : pas de HEALTHCHECK Docker mais ALLOW_NO_HEALTHCHECK=true. Validation par stabilité du process (${NO_HEALTHCHECK_STABLE_SECONDS:-6}s) uniquement — ce n'est PAS une validation applicative."
  fi

  # Hook pre-deploy si défini
  run_hook "pre-deploy" "$PRE_DEPLOY_CMD" "$APP_NAME" "$latest_tag" || {
    log ERROR "${APP_NAME} : hook pre-deploy en échec, déploiement interrompu AVANT tout changement d'état."
    return 1
  }

  # Nettoyage préventif d'un ancien conteneur candidat résiduel
  docker rm -f "$next_container" >/dev/null 2>&1 || true

  # 4. Lancement du conteneur candidat en parallèle
  log INFO "Démarrage du conteneur candidat '${next_container}'..."
  if ! docker run -d --name "$next_container" ${DOCKER_RUN_ARGS[@]+"${DOCKER_RUN_ARGS[@]}"} "$target_image" >/dev/null; then
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

    # Sans HEALTHCHECK Docker : uniquement atteignable si ALLOW_NO_HEALTHCHECK=true
    # (sinon la garde 3b a déjà refusé le déploiement plus haut). On ne valide que
    # la stabilité du process, JAMAIS l'applicatif. Fenêtre : NO_HEALTHCHECK_STABLE_SECONDS.
    if [[ "$has_healthcheck" != "true" && "$state_status" == "running" && $elapsed -ge "${NO_HEALTHCHECK_STABLE_SECONDS:-6}" ]]; then
      log WARN "${APP_NAME} : pas de HEALTHCHECK, validation par stabilité du process (${NO_HEALTHCHECK_STABLE_SECONDS:-6}s) uniquement."
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

    # Phase 3 : attente active de la découverte du candidat par Traefik si l'API
    # est exposée (sinon fallback sleep tampon). Transforme la prière en vérification.
    wait_traefik_discovery "$APP_NAME" "$next_container"

    # Arrêt propre de l'ancien conteneur
    if docker ps -a --format '{{.Names}}' | grep -q "^${current_container}$"; then
      log INFO "Arrêt de l'ancien conteneur (${current_container})..."
      docker stop -t 15 "$current_container" >/dev/null 2>&1 || docker kill "$current_container" >/dev/null 2>&1
      docker rm "$current_container" >/dev/null 2>&1
    fi

    # Renommage du candidat pour prendre le nom définitif
    docker rename "$next_container" "$current_container"
    sleep 2

    # Hook post-deploy : la bascule est DÉJÀ faite à ce stade. Un hook qui échoue
    # ne re-rollback pas un switch réussi (on ne défait pas une prod saine à cause
    # d'un script annexe) mais le cycle sort en erreur et l'alerte nomme le hook.
    if ! run_hook "post-deploy" "$POST_DEPLOY_CMD" "$APP_NAME" "$latest_tag"; then
      log ERROR "${APP_NAME} : déployé sur ${latest_tag}, MAIS hook post-deploy en échec. Bascule conservée, cycle marqué en erreur."
      return 1
    fi

    # Persistance (Phase 2/4) : on mémorise tag + digest déployés et on purge l'échec.
    state_set "$APP_NAME" \
      "last_deployed_tag=${latest_tag}" \
      "last_deployed_digest=${target_digest:-}"
    state_clear_failed "$APP_NAME"

    log SUCCESS "Déploiement réussi avec succès : ${APP_NAME} tourne sur ${latest_tag}"
    send_webhook_notification "SUCCESS" "$APP_NAME" "Mise à jour réussie vers ${latest_tag}"
    return 0

  else
    log ERROR "ÉCHEC DU DÉPLOIEMENT : Le conteneur candidat n'a pas validé sa santé !"
    log WARN "Démarrage de la procédure de Rollback / Nettoyage..."

    # Persistance (Phase 2) : on mémorise l'échec pour ne pas retenter ce tag
    # en boucle (skip automatique au prochain cycle, contournable via --force).
    local new_fail_count
    new_fail_count=$(( ${failed_count_prev:-0} + 1 ))
    state_set "$APP_NAME" \
      "last_failed_tag=${latest_tag}" \
      "failed_count=${new_fail_count}" \
      "last_failed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
# CLI (Phase 2)
# ==============================================================================
usage() {
  cat <<'EOF'
Usage: autodeploy.sh [options]

Options:
  (aucune)               Cycle de vérification / déploiement (défaut)
  --force <app>          Redéploie <app> même si son tag courant est marqué en échec
  --reset-failed <app>   Purge l'état d'échec de <app> (nouvelle chance)
  --status               Table d'état : apps, version locale, version distante, échecs
  -h, --help             Cette aide
EOF
}

# Table d'état en lecture seule (n'envoie aucune requête de déploiement).
cmd_status() {
  shopt -s nullglob
  local config_files=("${APPS_DIR}"/*.conf)
  shopt -u nullglob
  if [[ ${#config_files[@]} -eq 0 ]]; then
    log WARN "Aucune app configurée dans ${APPS_DIR}."
    return 0
  fi
  printf '%-22s %-16s %-16s %-16s %s\n' "APP" "LOCAL" "DISTANT" "DERNIER_ECHEC" "ETAT"
  local conf
  for conf in "${config_files[@]}"; do
    (
      local APP_NAME="" IMAGE_REPO="" GITLAB_PROJECT_ID=""
      # shellcheck source=/dev/null
      source "$conf" 2>/dev/null || true
      [[ -z "${APP_NAME:-}" || -z "${IMAGE_REPO:-}" ]] && exit 0
      local local_tag="-" remote_tag="-" failed state rc=0
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${APP_NAME}$"; then
        local img
        img=$(docker inspect --format '{{.Config.Image}}' "$APP_NAME" 2>/dev/null || echo "")
        local_tag="${img##*:}"
      fi
      remote_tag=$(get_latest_semver_tag "${GITLAB_PROJECT_ID:-}" "${GITLAB_URL:-}" "${GITLAB_TOKEN:-}" "$IMAGE_REPO" 2>/dev/null) || rc=$?
      [[ $rc -ne 0 ]] && remote_tag="ERR"
      [[ -z "$remote_tag" ]] && remote_tag="-"
      failed="$(state_get "$APP_NAME" last_failed_tag)"
      if [[ -n "$failed" ]]; then
        state="ECHEC x$(state_get "$APP_NAME" failed_count)"
      else
        state="OK"
      fi
      printf '%-22s %-16s %-16s %-16s %s\n' "$APP_NAME" "$local_tag" "$remote_tag" "${failed:--}" "$state"
    )
  done
}

cmd_reset_failed() {
  local app="$1"
  local file
  file="$(state_file "$app")"
  if [[ -f "$file" ]]; then
    state_clear_failed "$app"
    log SUCCESS "État d'échec de ${app} purgé (${file})."
  else
    log WARN "Aucun état trouvé pour ${app} (${file} absent)."
  fi
}

# ==============================================================================
# Point d'entrée
# ==============================================================================
main() {
  # FORCE_APP est global (lu par deploy_application).
  FORCE_APP=""
  local do_status=false reset_app=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE_APP="${2:-}"
        [[ -z "$FORCE_APP" ]] && { log ERROR "--force nécessite un nom d'app"; exit 2; }
        shift 2 ;;
      --reset-failed)
        reset_app="${2:-}"
        [[ -z "$reset_app" ]] && { log ERROR "--reset-failed nécessite un nom d'app"; exit 2; }
        shift 2 ;;
      --status) do_status=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log ERROR "Argument inconnu: $1"; usage; exit 2 ;;
    esac
  done

  check_dependencies
  ensure_state_dir

  if [[ "$do_status" == "true" ]]; then
    # --status a besoin de l'env (GITLAB_URL, tokens) si présent, mais tolère son absence.
    [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
    cmd_status
    exit 0
  fi

  if [[ -n "$reset_app" ]]; then
    cmd_reset_failed "$reset_app"
    exit 0
  fi

  acquire_lock

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

  # Validation du charset du token : un espace, un `$` ou un backtick dans le
  # token provoque une expansion shell / un 401 trompeur difficile à diagnostiquer.
  # Les API Keys JFrog (AKCp...), Identity Tokens (JWT) et tokens GitLab sont
  # dans ce charset. Un WARN explicite vaut mieux qu'un 401 silencieux.
  if [[ -n "$reg_pass" && ! "$reg_pass" =~ ^[A-Za-z0-9._~+/=,-]+$ ]]; then
    log WARN "REGISTRY_TOKEN contient des caractères hors charset attendu (espace, \$, backtick ?) — l'authentification peut échouer avec un 401 trompeur."
  fi

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
    # NOTE: ne jamais utiliser ((x++)) avec set -e : le post-increment d'une valeur 0
    # retourne le statut 1 et tue le script (piège confirmé sous bash >= 4).
    conf_count=$((conf_count + 1))
    if deploy_application "$conf"; then
      success_count=$((success_count + 1))
    else
      error_count=$((error_count + 1))
    fi
  done

  # Nettoyage automatique des images orphelines (dangling)
  if [[ "${AUTO_PRUNE_IMAGES:-true}" == "true" ]]; then
    log INFO "Nettoyage des images Docker non référencées..."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  log INFO "Fin du cycle de vérification : ${conf_count} apps inspectées, ${success_count} succès, ${error_count} erreurs."

  # Propager le code de sortie : un cycle avec des échecs doit être visible
  # de systemd (systemctl show -p ExecMainStatus autodeploy.service).
  if [[ "$error_count" -gt 0 ]]; then
    exit 1
  fi
}

# Exécuter main uniquement si le script est lancé directement (pas s'il est
# "sourcé" pour le test unitaire des fonctions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
