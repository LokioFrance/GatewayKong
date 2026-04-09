#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Déploiement de la Kong API Gateway (Lokio)
# Usage : ./deploy.sh
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
TEMPLATE="$SCRIPT_DIR/kong.yml.template"
KONG_YML="$SCRIPT_DIR/kong.yml"

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# ── Prérequis ─────────────────────────────────────────────────────────────────
info "Vérification des prérequis..."

if ! command -v docker &>/dev/null; then
    error "Docker n'est pas installé."
    exit 1
fi

if ! docker compose version &>/dev/null; then
    error "Docker Compose (plugin) n'est pas disponible."
    exit 1
fi

success "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# ── Gestion du fichier .env ───────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    if [ ! -f "$ENV_EXAMPLE" ]; then
        error ".env.example introuvable."
        exit 1
    fi

    info "Création du fichier .env depuis .env.example..."
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    success ".env créé."

    info "Ouverture de l'éditeur — remplissez les valeurs puis sauvegardez et quittez."
    EDITOR="${EDITOR:-nano}"
    "$EDITOR" "$ENV_FILE"

    echo ""
    read -rp "$(echo -e "${BLUE}[INFO]${NC} Continuer le déploiement ? [O/n] ")" CONFIRM
    if [[ "${CONFIRM,,}" == "n" ]]; then
        warn "Déploiement annulé. Le fichier .env a été conservé."
        exit 0
    fi
else
    info "Fichier .env trouvé — déploiement automatique."
fi

# ── Chargement des variables ──────────────────────────────────────────────────
set -o allexport
source "$ENV_FILE"
set +o allexport

# ── Validation des variables critiques ───────────────────────────────────────
info "Validation de la configuration..."

ERRORS=0

# AREA_JWT_SECRET : doit correspondre au DJANGO_SECRET_KEY du service area
if [[ -z "${AREA_JWT_SECRET:-}" ]] || [[ "$AREA_JWT_SECRET" == "changeme-"* ]]; then
    error "AREA_JWT_SECRET non défini ou non modifié dans .env"
    error "→ Récupérez la valeur dans : area/.env (DJANGO_SECRET_KEY)"
    ERRORS=$((ERRORS + 1))
fi

AREA_UPSTREAM="${AREA_UPSTREAM:-http://host.docker.internal:8001}"
BOXIFY_UPSTREAM="${BOXIFY_UPSTREAM:-http://host.docker.internal:8002}"
MARKO_UPSTREAM="${MARKO_UPSTREAM:-http://host.docker.internal:8003}"

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi

success "Configuration valide."

# ── Vérification de l'accessibilité des microservices ────────────────────────
info "Vérification de l'accessibilité des microservices..."

check_service() {
    local name="$1"
    local port="$2"
    if curl -sf --max-time 3 "http://localhost:${port}/api/" &>/dev/null \
    || curl -sf --max-time 3 "http://localhost:${port}/" &>/dev/null; then
        success "  $name accessible sur :${port}"
    else
        warn "  $name non accessible sur :${port} — le token manager réessaiera au démarrage."
    fi
}

AREA_PORT=$(echo "$AREA_UPSTREAM" | grep -oE '[0-9]+$' || echo "8001")
BOXIFY_PORT=$(echo "$BOXIFY_UPSTREAM" | grep -oE '[0-9]+$' || echo "8002")
MARKO_PORT=$(echo "$MARKO_UPSTREAM" | grep -oE '[0-9]+$' || echo "8003")

# Détection de l'IP IPv4 du bridge Docker
# Nécessaire car host.docker.internal peut résoudre en IPv6 sur Linux
DOCKER_GATEWAY_IP=$(docker network inspect bridge \
    --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "172.17.0.1")

# URLs internes utilisées par le token-manager (depuis l'intérieur des containers)
export AREA_INTERNAL_URL="http://${DOCKER_GATEWAY_IP}:${AREA_PORT}"
export BOXIFY_INTERNAL_URL="http://${DOCKER_GATEWAY_IP}:${BOXIFY_PORT}"
export MARKO_INTERNAL_URL="http://${DOCKER_GATEWAY_IP}:${MARKO_PORT}"
export DOCKER_GATEWAY_IP

info "IP bridge Docker : ${DOCKER_GATEWAY_IP}"
info "URLs internes token-manager :"
info "  area   → ${AREA_INTERNAL_URL}"
info "  boxify → ${BOXIFY_INTERNAL_URL}"
info "  marko  → ${MARKO_INTERNAL_URL}"

check_service "area"   "$AREA_PORT"
check_service "boxify" "$BOXIFY_PORT"
check_service "marko"  "$MARKO_PORT"

# ── Vérification des comptes de service ──────────────────────────────────────
info "Vérification des comptes de service (authentification)..."

check_service_auth() {
    local name="$1"
    local url="$2"
    local user="$3"
    local pass="$4"
    local container_name="$5"

    if [[ -z "$user" ]] || [[ "$pass" == "changeme-"* ]]; then
        warn "  $name: credentials non configurés — token manager ne pourra pas s'authentifier."
        warn "    → Définissez ${name^^}_SERVICE_USERNAME et ${name^^}_SERVICE_PASSWORD dans .env"
        return
    fi

    local response
    response=$(curl -sf --max-time 5 \
        -X POST "${url}/api/token/" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" \
        2>/dev/null || echo "")

    if echo "$response" | grep -q '"access"'; then
        success "  $name: compte '${user}' authentifié."
    else
        warn "  $name: authentification échouée pour '${user}'."
        warn "    → Créez le compte avec :"
        warn "      docker exec ${container_name} python manage.py shell -c \\"
        warn "      \"from django.contrib.auth.models import User; User.objects.create_user('${user}', password='<mot_de_passe>')\""
    fi
}

check_service_auth "area"   "$AREA_UPSTREAM"   "${AREA_SERVICE_USERNAME:-gateway}"   "${AREA_SERVICE_PASSWORD:-}"   "area"
check_service_auth "boxify" "$BOXIFY_UPSTREAM" "${BOXIFY_SERVICE_USERNAME:-gateway}" "${BOXIFY_SERVICE_PASSWORD:-}" "boxify"
check_service_auth "marko"  "$MARKO_UPSTREAM"  "${MARKO_SERVICE_USERNAME:-gateway}"  "${MARKO_SERVICE_PASSWORD:-}"  "marko"

# ── Génération de kong.yml depuis le template ─────────────────────────────────
info "Génération de kong.yml depuis le template..."

if [ ! -f "$TEMPLATE" ]; then
    error "Fichier kong.yml.template introuvable."
    exit 1
fi

sed \
    -e "s@__AREA_UPSTREAM__@${AREA_INTERNAL_URL}@g" \
    -e "s@__BOXIFY_UPSTREAM__@${BOXIFY_INTERNAL_URL}@g" \
    -e "s@__MARKO_UPSTREAM__@${MARKO_INTERNAL_URL}@g" \
    "$TEMPLATE" > "$KONG_YML"

success "kong.yml généré."

# ── Build & déploiement ───────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

info "Construction de l'image token-manager..."
docker compose build --no-cache token-manager

info "Arrêt des services existants (si présents)..."
docker compose down --remove-orphans || true

info "Démarrage du token-manager..."
docker compose up -d token-manager

info "Attente que le token-manager obtienne les tokens (jusqu'à 3 min)..."
MAX_WAIT=180
WAITED=0

until docker compose ps token-manager | grep -q "healthy"; do
    sleep 5
    WAITED=$((WAITED + 5))
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        warn "Le token-manager prend du temps. Vérifiez les comptes de service :"
        docker compose logs --tail=20 token-manager
        echo ""
        read -rp "$(echo -e "${YELLOW}[WARN]${NC} Continuer quand même ? [O/n] ")" CONT
        if [[ "${CONT,,}" == "n" ]]; then
            docker compose down
            exit 1
        fi
        break
    fi
    echo -e "  ${BLUE}...${NC} ${WAITED}s / ${MAX_WAIT}s"
done

info "Démarrage de Kong..."
docker compose up -d kong

# ── Attente du démarrage de Kong ──────────────────────────────────────────────
info "Attente du démarrage de Kong..."
ADMIN_PORT="${KONG_ADMIN_PORT:-8900}"
MAX_WAIT=60
WAITED=0

until curl -sf "http://localhost:${ADMIN_PORT}/status" &>/dev/null; do
    sleep 2
    WAITED=$((WAITED + 2))
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        error "Kong n'a pas démarré dans les temps. Vérifiez les logs :"
        docker compose logs --tail=30 kong
        exit 1
    fi
done

success "Kong est opérationnel."

# ── Vérification de la configuration chargée ─────────────────────────────────
info "Vérification de la configuration Kong..."
ROUTE_COUNT=$(curl -s "http://localhost:${ADMIN_PORT}/routes" | grep -o '"id"' | wc -l | tr -d ' ')
success "$ROUTE_COUNT routes chargées."

# ── Résumé ────────────────────────────────────────────────────────────────────
PROXY_PORT="${KONG_PROXY_PORT:-8000}"
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
success "Kong Gateway déployé !"
echo ""
echo -e "  Proxy    : ${BLUE}http://localhost:${PROXY_PORT}${NC}"
echo -e "  Admin    : ${BLUE}http://localhost:${ADMIN_PORT}${NC}"
echo ""
echo -e "${YELLOW}  ── Auth (endpoints publics) ──────────────────────────────${NC}"
echo -e "  Login    : POST http://localhost:${PROXY_PORT}/auth/token"
echo -e "             Body: {\"username\": \"...\", \"password\": \"...\"}"
echo -e "  Refresh  : POST http://localhost:${PROXY_PORT}/auth/token/refresh"
echo -e "             Body: {\"refresh\": \"<refresh_token>\"}"
echo ""
echo -e "${YELLOW}  ── Microservices (nécessitent un JWT) ────────────────────${NC}"
echo -e "  Area     : http://localhost:${PROXY_PORT}/api/areas/"
echo -e "             http://localhost:${PROXY_PORT}/api/sub-areas/"
echo -e "  Boxify   : http://localhost:${PROXY_PORT}/api/items/"
echo -e "             http://localhost:${PROXY_PORT}/api/item-infos/"
echo -e "             http://localhost:${PROXY_PORT}/api/objects/"
echo -e "  Marko    : http://localhost:${PROXY_PORT}/api/identifiers/"
echo -e "             http://localhost:${PROXY_PORT}/api/typeids/"
echo ""
echo -e "${YELLOW}  ── Utilisation ────────────────────────────────────────────${NC}"
echo -e "  # 1. Se connecter"
echo -e "  TOKEN=\$(curl -s -X POST http://localhost:${PROXY_PORT}/auth/token \\"
echo -e "    -H 'Content-Type: application/json' \\"
echo -e "    -d '{\"username\":\"admin\",\"password\":\"<pass>\"}' | python3 -c \"import sys,json; print(json.load(sys.stdin)['access'])\")"
echo ""
echo -e "  # 2. Appeler un microservice"
echo -e "  curl -H \"Authorization: Bearer \$TOKEN\" http://localhost:${PROXY_PORT}/api/areas/"
echo ""
echo -e "  Logs token-manager : docker compose logs -f token-manager"
echo -e "  Logs Kong          : docker compose logs -f kong"
echo -e "  Arrêter            : docker compose down"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}[RAPPEL]${NC} Configurez l'UI avec :"
echo -e "  KONG_URL=http://localhost:${PROXY_PORT}"
