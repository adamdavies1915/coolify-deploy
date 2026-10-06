#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
ln -s "$(command -v jq)" "$TMP/bin/jq"

cat > "$TMP/bin/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
METHOD=GET
URL=
FAIL=false
ACCEPT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fail) FAIL=true; shift ;;
        -X|--request) METHOD="$2"; shift 2 ;;
        -H|--header)
            [[ "$2" != "Accept: application/json" ]] || ACCEPT=true
            shift 2 ;;
        -d|--data) shift 2 ;;
        --silent|--show-error) shift ;;
        https://*) URL="$1"; shift ;;
        *) echo "Unexpected curl argument" >&2; exit 90 ;;
    esac
done
[[ "$FAIL" == true && "$ACCEPT" == true ]] || exit 91
ENDPOINT=$(printf '%s' "$URL" | sed 's|^https://coolify.invalid||')
CALL="$METHOD $ENDPOINT"
printf '%s\n' "$CALL" >> "$REQUEST_LOG"

if [[ "$CALL" == "$FAIL_CALL" ]]; then
    echo 'curl: (22) The requested URL returned error: 403' >&2
    exit 22
fi

case "$CALL" in
    "GET /api/v1/servers") echo '[{"uuid":"server-uuid","name":"test"}]' ;;
    "GET /api/v1/github-apps") echo '[{"uuid":"github-app-uuid","name":"test","is_public":false}]' ;;
    "GET /api/v1/projects")
        if [[ "$SCENARIO" == existing ]]; then
            echo '[{"uuid":"project-uuid","name":"test-project"}]'
        else
            echo '[]'
        fi ;;
    "POST /api/v1/projects") echo '{"uuid":"project-uuid"}' ;;
    "GET /api/v1/projects/project-uuid/environments") echo '[{"name":"production"}]' ;;
    "POST /api/v1/applications/private-github-app") echo '{"uuid":"app-uuid"}' ;;
    "PATCH /api/v1/applications/app-uuid") echo '{"uuid":"app-uuid"}' ;;
    "POST /api/v1/applications/app-uuid/envs") echo '{"uuid":"env-uuid"}' ;;
    "POST /api/v1/applications/app-uuid/start") echo '{"message":"Deployment request queued.","deployment_uuid":"deployment-uuid"}' ;;
    *) echo "Unexpected request: $CALL" >&2; exit 92 ;;
esac
STUB
chmod +x "$TMP/bin/curl"

run_case() {
    local name="$1" scenario="$2" fail_call="$3"
    shift 3
    LOG="$TMP/$name.requests"
    OUTPUT="$TMP/$name.output"
    : > "$LOG"
    STATUS=0
    env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
        COOLIFY_URL=https://coolify.invalid \
        COOLIFY_TOKEN='test|not-a-real-token' BASE_DOMAIN=example.com \
        SCENARIO="$scenario" FAIL_CALL="$fail_call" REQUEST_LOG="$LOG" \
        bash "$ROOT/scripts/deploy.sh" \
        --repo example/app --subdomain test --project test-project \
        --env NODE_ENV=production "$@" > "$OUTPUT" 2>&1 || STATUS=$?
}

run_case create new ''
[[ "$STATUS" -eq 0 ]]
grep -Fxq 'POST /api/v1/projects' "$LOG"
grep -Fxq 'POST /api/v1/applications/app-uuid/start' "$LOG"
grep -Fq 'Deployment request accepted' "$OUTPUT"
! grep -Fq 'Deployment Complete' "$OUTPUT"
echo 'PASS: create project and request deployment with POST'

run_case reuse existing ''
[[ "$STATUS" -eq 0 ]]
! grep -Fxq 'POST /api/v1/projects' "$LOG"
grep -Fq 'Found existing project' "$OUTPUT"
echo 'PASS: reuse project without attempting duplicate creation'

for fail_call in \
    'GET /api/v1/servers' \
    'GET /api/v1/projects' \
    'POST /api/v1/projects' \
    'POST /api/v1/applications/private-github-app' \
    'PATCH /api/v1/applications/app-uuid' \
    'POST /api/v1/applications/app-uuid/envs' \
    'POST /api/v1/applications/app-uuid/start'; do
    run_case failure new "$fail_call"
    [[ "$STATUS" -eq 22 ]]
    [[ "$(tail -n 1 "$LOG")" == "$fail_call" ]]
    ! grep -Fq 'Deployment request accepted' "$OUTPUT"
    ! grep -Fq 'Deployment Requested' "$OUTPUT"
    echo "PASS: stop after HTTP error at $fail_call"
done

run_case dry_run new '' --dry-run
[[ "$STATUS" -eq 0 ]]
[[ ! -s "$LOG" ]]
grep -Fq 'No deployment started' "$OUTPUT"
! grep -Fq 'Deployment request accepted' "$OUTPUT"
echo 'PASS: dry run makes no HTTP requests and claims no deployment'
