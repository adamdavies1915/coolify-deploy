---
name: coolify-deploy
description: Deploy applications to Coolify via GitHub App. Creates projects, adds public/private GitHub repos, configures subdomains, and triggers deployments. Use when deploying to Coolify, setting up Coolify projects, or automating Coolify infrastructure.
---

# Coolify Deployment Automation

Deploy any public or private Git repository to Coolify using GitHub App authentication.

## Default Configuration

Set these environment variables for your Coolify instance:

```bash
export COOLIFY_URL="https://coolify.example.com"   # Your Coolify instance URL
export COOLIFY_TOKEN='2|your-token-here'            # Your Coolify API token
export BASE_DOMAIN="example.com"                    # Base domain for subdomains
```

## Prerequisites

1. **Coolify API Token**: Get from `<your-coolify-url>/security/api-tokens`
2. **GitHub App**: Must be configured in Coolify
3. **Environment variable**: Set `COOLIFY_TOKEN` with your API token

### Token Format (Important)

Coolify v4 API tokens use a `id|hash` format, e.g. `2|G0gaUiI5lG3ryJc3...`. You **must** include the full token including the `id|` prefix in the `Authorization: Bearer` header. The pipe character (`|`) is part of the token and must not be stripped.

When storing in shell config:
```bash
# Use single quotes to prevent shell interpretation of the pipe
export COOLIFY_TOKEN='2|G0gaUiI5lG3ryJc3nCoWFrj...'
```

When passing directly in curl, always quote the token to prevent the shell from treating `|` as a pipe operator.

## Quick Deploy Workflow

### Step 1: Gather Information

Ask the user for:
- GitHub repository (format: `owner/repo`)
- Branch to deploy (default: `main`)
- Subdomain for the app (e.g., `myapp` for `myapp.example.com`)
- Port the app listens on (default: `3000`)
- Build pack: `dockerfile`, `nixpacks`, or `static`

### Step 2: Discover Resources

```bash
COOLIFY_URL="${COOLIFY_URL:-https://coolify.example.com}"

# Get API token from user or environment
# COOLIFY_TOKEN should be set

# List GitHub Apps to get the uuid
curl -s -X GET "$COOLIFY_URL/api/v1/github-apps" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" | jq '.[] | {uuid, name}'

# List servers
curl -s -X GET "$COOLIFY_URL/api/v1/servers" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" | jq '.[] | {uuid, name}'

# List existing projects
curl -s -X GET "$COOLIFY_URL/api/v1/projects" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" | jq '.[] | {uuid, name}'
```

### Step 3: Create Project (or use existing)

```bash
# Create new project
PROJECT_RESPONSE=$(curl -s -X POST "$COOLIFY_URL/api/v1/projects" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-project"}')

PROJECT_UUID=$(echo $PROJECT_RESPONSE | jq -r '.uuid')
```

### Step 4: Create Application via GitHub App

This is the main endpoint - deploys any public or private repo via GitHub App:

```bash
# Required variables
PROJECT_UUID="your-project-uuid"
SERVER_UUID="your-server-uuid"
GITHUB_APP_UUID="your-github-app-uuid"
GITHUB_REPO="owner/repo-name"
GIT_BRANCH="main"
PORT="3000"

# Create application using private-github-app endpoint
# This works for BOTH public and private repos when using GitHub App auth
APP_RESPONSE=$(curl -s -X POST "$COOLIFY_URL/api/v1/applications/private-github-app" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"project_uuid\": \"$PROJECT_UUID\",
    \"server_uuid\": \"$SERVER_UUID\",
    \"github_app_uuid\": \"$GITHUB_APP_UUID\",
    \"git_repository\": \"$GITHUB_REPO\",
    \"git_branch\": \"$GIT_BRANCH\",
    \"build_pack\": \"dockerfile\",
    \"ports_exposes\": \"$PORT\",
    \"environment_name\": \"production\"
  }")

APP_UUID=$(echo $APP_RESPONSE | jq -r '.uuid')
echo "Created application: $APP_UUID"
```

### Step 5: Configure Subdomain

```bash
SUBDOMAIN="myapp"
DOMAIN="${BASE_DOMAIN:-example.com}"

curl -s -X PATCH "$COOLIFY_URL/api/v1/applications/$APP_UUID" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"domains\": \"https://${SUBDOMAIN}.${DOMAIN}\"}"
```

### Step 6: Add Environment Variables

```bash
# Add each env var
curl -s -X POST "$COOLIFY_URL/api/v1/applications/$APP_UUID/envs" \
  -H "Authorization: Bearer $COOLIFY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "NODE_ENV",
    "value": "production",
    "is_build_time": false
  }'
```

### Step 7: Deploy

```bash
# Trigger deployment
curl -s -X GET "$COOLIFY_URL/api/v1/applications/$APP_UUID/start" \
  -H "Authorization: Bearer $COOLIFY_TOKEN"
```

## Complete Script Usage

```bash
~/.claude/skills/coolify-deploy/scripts/deploy.sh \
  --token "your-api-token" \
  --repo "owner/repo" \
  --subdomain "myapp" \
  --branch "main" \
  --port 3000
```

With environment variable:
```bash
export COOLIFY_TOKEN="your-token"

~/.claude/skills/coolify-deploy/scripts/deploy.sh \
  --repo "owner/repo" \
  --subdomain "myapp"
```

## API Endpoints Reference

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v1/projects` | POST | Create project |
| `/api/v1/projects/{uuid}/environments` | GET | List environments |
| `/api/v1/servers` | GET | List servers |
| `/api/v1/github-apps` | GET | List GitHub Apps |
| `/api/v1/applications/private-github-app` | POST | **Create app via GitHub App** |
| `/api/v1/applications/{uuid}` | PATCH | Update app (domains, settings) |
| `/api/v1/applications/{uuid}/envs` | POST | Add environment variable |
| `/api/v1/applications/{uuid}/start` | GET | Deploy/start application |

## Static Site Deployment (Astro, Vite, etc.)

For static site generators, use the `dockerfile` build pack with a multi-stage Dockerfile:

```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
```

Set `ports_exposes` to `80` (nginx default) and `build_pack` to `dockerfile`.

Do NOT use the `static` build pack -- it has reliability issues with Traefik routing. Do NOT use `nixpacks` with `npx serve` as serve may not be available in the runtime.

**Important**: Always set the `domains` field when creating/updating an app. If `domains` is `null`, Traefik won't route traffic and you'll get 502 Bad Gateway.

## Troubleshooting

- **401 Unauthorized**: Get a new token from `<your-coolify-url>/security/api-tokens`. Make sure the full `id|hash` token is being used (see Token Format above).
- **502 Bad Gateway**: Check that `domains` is set (not null), `ports_exposes` matches the port your app actually listens on, and the container is healthy. For static sites, use nginx on port 80 via Dockerfile.
- **422 Validation Error**: Check required fields (project_uuid, server_uuid, github_app_uuid). Some fields like `dockerfile_location` are not accepted by the PATCH endpoint.
- **GitHub App not found**: Verify GitHub App is configured in Coolify
- **Build fails**: Check Dockerfile exists in repo root, or use `nixpacks` build_pack
- **running:unknown status**: Usually means Traefik can't reach the container. Verify the port mapping and domain configuration.
