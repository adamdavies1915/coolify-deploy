#!/bin/bash
set -e

# Coolify Deployment Script - GitHub App Method
# Deploys any public or private Git repository via GitHub App authentication
# Configure via COOLIFY_URL and BASE_DOMAIN environment variables

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() { echo -e "${BLUE}==>${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Defaults — override via environment variables or CLI flags
COOLIFY_URL="${COOLIFY_URL:-https://coolify.example.com}"
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
BUILD_PACK="dockerfile"
GIT_BRANCH="main"
PORT="3000"

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy a GitHub repository to Coolify via GitHub App authentication.
Configure via COOLIFY_URL and BASE_DOMAIN environment variables.

Required:
  --repo OWNER/REPO      GitHub repository (e.g., myorg/myapp)
  --subdomain NAME       Subdomain for the app (e.g., myapp -> myapp.example.com)

Authentication (one required):
  --token TOKEN          API token (or set COOLIFY_TOKEN env var)

Optional:
  --url URL              Coolify URL (default: \$COOLIFY_URL or https://coolify.example.com)
  --domain DOMAIN        Base domain (default: \$BASE_DOMAIN or example.com)
  --project NAME         Project name (default: derived from repo)
  --branch BRANCH        Git branch (default: main)
  --port PORT            Application port (default: 3000)
  --build-pack TYPE      dockerfile, nixpacks, static (default: dockerfile)
  --server UUID          Server UUID (auto-detected if only one)
  --github-app UUID      GitHub App UUID (auto-detected if only one)
  --env KEY=VALUE        Environment variable (repeatable)
  --dry-run              Show what would be done without executing
  -h, --help             Show this help

Examples:
  # Minimal (with COOLIFY_TOKEN env var set)
  $(basename "$0") --repo myorg/myapp --subdomain api

  # Full options
  $(basename "$0") --token xxx --repo myorg/myapp --subdomain api \\
    --branch develop --port 8080 --env NODE_ENV=production

  # Different domain
  $(basename "$0") --repo myorg/myapp --subdomain api --domain example.com
EOF
    exit 1
}

# Parse arguments
ENV_VARS=()
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --url) COOLIFY_URL="$2"; shift 2 ;;
        --token) COOLIFY_TOKEN="$2"; shift 2 ;;
        --repo) GITHUB_REPO="$2"; shift 2 ;;
        --subdomain) SUBDOMAIN="$2"; shift 2 ;;
        --domain) BASE_DOMAIN="$2"; shift 2 ;;
        --project) PROJECT_NAME="$2"; shift 2 ;;
        --branch) GIT_BRANCH="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --build-pack) BUILD_PACK="$2"; shift 2 ;;
        --server) SERVER_UUID="$2"; shift 2 ;;
        --github-app) GITHUB_APP_UUID="$2"; shift 2 ;;
        --env) ENV_VARS+=("$2"); shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

# Validate required
[[ -z "$COOLIFY_TOKEN" ]] && { print_error "Missing --token or COOLIFY_TOKEN env var"; usage; }
[[ -z "$GITHUB_REPO" ]] && { print_error "Missing --repo"; usage; }
[[ -z "$SUBDOMAIN" ]] && { print_error "Missing --subdomain"; usage; }

# Clean URL
COOLIFY_URL="${COOLIFY_URL%/}"

# Validate token format - Coolify v4 tokens use id|hash format
if [[ "$COOLIFY_TOKEN" != *"|"* ]]; then
    print_warning "Token doesn't contain '|' separator. Coolify v4 tokens use 'id|hash' format (e.g., '2|abc...'). Make sure the full token is provided."
fi

# Derive project name
if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)
fi

FULL_DOMAIN="https://${SUBDOMAIN}.${BASE_DOMAIN}"

echo ""
echo "=========================================="
echo "  Coolify Deployment (GitHub App)"
echo "=========================================="
echo "  Instance:    $COOLIFY_URL"
echo "  Repository:  $GITHUB_REPO"
echo "  Branch:      $GIT_BRANCH"
echo "  Project:     $PROJECT_NAME"
echo "  Domain:      $FULL_DOMAIN"
echo "  Build Pack:  $BUILD_PACK"
echo "  Port:        $PORT"
echo "=========================================="
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    print_warning "DRY RUN - No changes will be made"
    echo ""
fi

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] $method $endpoint"
        [[ -n "$data" ]] && echo "  Data: $data"
        return 0
    fi

    if [[ -n "$data" ]]; then
        curl -s -X "$method" "${COOLIFY_URL}${endpoint}" \
            -H "Authorization: Bearer $COOLIFY_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "${COOLIFY_URL}${endpoint}" \
            -H "Authorization: Bearer $COOLIFY_TOKEN"
    fi
}

# Step 1: Get Server UUID
print_step "Discovering server..."
if [[ -z "$SERVER_UUID" ]]; then
    SERVERS=$(api_call GET "/api/v1/servers")

    if [[ "$DRY_RUN" == "true" ]]; then
        SERVER_UUID="dry-run-server-uuid"
    else
        SERVER_COUNT=$(echo "$SERVERS" | jq 'length' 2>/dev/null || echo "0")

        if [[ "$SERVER_COUNT" -eq 0 ]]; then
            print_error "No servers found"
            exit 1
        elif [[ "$SERVER_COUNT" -eq 1 ]]; then
            SERVER_UUID=$(echo "$SERVERS" | jq -r '.[0].uuid')
        else
            echo "Multiple servers found. Please specify with --server:"
            echo "$SERVERS" | jq -r '.[] | "  \(.uuid): \(.name)"'
            exit 1
        fi
    fi
fi
print_success "Server: $SERVER_UUID"

# Step 2: Get GitHub App UUID (prefer private app for private repos)
print_step "Discovering GitHub App..."
if [[ -z "$GITHUB_APP_UUID" ]]; then
    GITHUB_APPS=$(api_call GET "/api/v1/github-apps")

    if [[ "$DRY_RUN" == "true" ]]; then
        GITHUB_APP_UUID="dry-run-github-app-uuid"
    else
        # Try to find a private GitHub App first (is_public: false)
        PRIVATE_APP=$(echo "$GITHUB_APPS" | jq -r '[.[] | select(.is_public == false)] | .[0].uuid // empty')

        if [[ -n "$PRIVATE_APP" ]]; then
            GITHUB_APP_UUID="$PRIVATE_APP"
            APP_NAME=$(echo "$GITHUB_APPS" | jq -r ".[] | select(.uuid == \"$GITHUB_APP_UUID\") | .name")
            print_success "Using private GitHub App: $APP_NAME"
        else
            # Fall back to any available app
            APP_COUNT=$(echo "$GITHUB_APPS" | jq 'length' 2>/dev/null || echo "0")
            if [[ "$APP_COUNT" -eq 0 ]]; then
                print_error "No GitHub Apps found. Configure one in Coolify first."
                exit 1
            elif [[ "$APP_COUNT" -eq 1 ]]; then
                GITHUB_APP_UUID=$(echo "$GITHUB_APPS" | jq -r '.[0].uuid')
            else
                echo "Multiple GitHub Apps found. Please specify with --github-app:"
                echo "$GITHUB_APPS" | jq -r '.[] | "  \(.uuid): \(.name)"'
                exit 1
            fi
        fi
    fi
fi
print_success "GitHub App: $GITHUB_APP_UUID"

# Step 3: Create or find Project
print_step "Setting up project: $PROJECT_NAME..."
if [[ "$DRY_RUN" == "true" ]]; then
    PROJECT_UUID="dry-run-project-uuid"
else
    PROJECT_RESPONSE=$(api_call POST "/api/v1/projects" "{\"name\": \"$PROJECT_NAME\"}")
    PROJECT_UUID=$(echo "$PROJECT_RESPONSE" | jq -r '.uuid // empty')

    if [[ -z "$PROJECT_UUID" ]]; then
        print_warning "Project may exist, searching..."
        PROJECTS=$(api_call GET "/api/v1/projects")
        PROJECT_UUID=$(echo "$PROJECTS" | jq -r ".[] | select(.name == \"$PROJECT_NAME\") | .uuid")

        if [[ -z "$PROJECT_UUID" ]]; then
            print_error "Failed to create or find project"
            echo "$PROJECT_RESPONSE"
            exit 1
        fi
        print_success "Found existing project: $PROJECT_UUID"
    else
        print_success "Created project: $PROJECT_UUID"
    fi
fi

# Step 4: Get Environment
print_step "Getting environment..."
if [[ "$DRY_RUN" == "true" ]]; then
    ENVIRONMENT_NAME="production"
else
    ENVIRONMENTS=$(api_call GET "/api/v1/projects/$PROJECT_UUID/environments")
    ENVIRONMENT_NAME=$(echo "$ENVIRONMENTS" | jq -r '.[0].name // "production"')
fi
print_success "Environment: $ENVIRONMENT_NAME"

# Step 5: Create Application via GitHub App
print_step "Creating application from $GITHUB_REPO..."
APP_PAYLOAD=$(cat << EOF
{
    "project_uuid": "$PROJECT_UUID",
    "environment_name": "$ENVIRONMENT_NAME",
    "server_uuid": "$SERVER_UUID",
    "github_app_uuid": "$GITHUB_APP_UUID",
    "git_repository": "$GITHUB_REPO",
    "git_branch": "$GIT_BRANCH",
    "build_pack": "$BUILD_PACK",
    "ports_exposes": "$PORT"
}
EOF
)

if [[ "$DRY_RUN" == "true" ]]; then
    APP_UUID="dry-run-app-uuid"
    echo "[DRY RUN] POST /api/v1/applications/private-github-app"
    echo "  Payload: $APP_PAYLOAD"
else
    APP_RESPONSE=$(api_call POST "/api/v1/applications/private-github-app" "$APP_PAYLOAD")
    APP_UUID=$(echo "$APP_RESPONSE" | jq -r '.uuid // empty')

    if [[ -z "$APP_UUID" ]]; then
        print_error "Failed to create application"
        echo "$APP_RESPONSE" | jq .
        exit 1
    fi
fi
print_success "Application: $APP_UUID"

# Step 6: Configure Domain
print_step "Configuring domain: $FULL_DOMAIN..."
api_call PATCH "/api/v1/applications/$APP_UUID" "{\"domains\": \"$FULL_DOMAIN\"}" > /dev/null
print_success "Domain configured"

# Step 7: Environment Variables
if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
    print_step "Adding environment variables..."
    for env_var in "${ENV_VARS[@]}"; do
        KEY="${env_var%%=*}"
        VALUE="${env_var#*=}"
        api_call POST "/api/v1/applications/$APP_UUID/envs" \
            "{\"key\": \"$KEY\", \"value\": \"$VALUE\", \"is_build_time\": false}" > /dev/null
        print_success "  $KEY"
    done
fi

# Step 8: Deploy
print_step "Starting deployment..."
api_call GET "/api/v1/applications/$APP_UUID/start" > /dev/null
print_success "Deployment triggered"

echo ""
echo "=========================================="
echo -e "${GREEN}  Deployment Complete!${NC}"
echo "=========================================="
echo "  Application UUID: $APP_UUID"
echo "  URL: $FULL_DOMAIN"
echo ""
echo "  View in Coolify:"
echo "    ${COOLIFY_URL}/project/${PROJECT_UUID}"
echo ""
echo "  Check deployment logs:"
echo "    curl -H \"Authorization: Bearer \$COOLIFY_TOKEN\" \\"
echo "      ${COOLIFY_URL}/api/v1/applications/${APP_UUID}/logs"
echo "=========================================="
