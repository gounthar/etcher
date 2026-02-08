#!/bin/bash
# setup-riscv-runner.sh — Register the etcher repo with the existing github-act-runner
#
# The BananaPi F3 (poddingue@192.168.1.185) already has github-act-runner installed
# at ~/github-act-runner with instances for docker-for-riscv64 and unofficial-builds.
# This script adds a new instance for the etcher fork.
#
# Usage (from any machine with gh CLI and SSH access):
#   ./setup-riscv-runner.sh [owner/repo]
#
# Prerequisites:
#   - gh CLI authenticated with admin access to the repo
#   - SSH access to poddingue@192.168.1.185

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

REPO_SLUG="${1:-gounthar/etcher}"
if [[ ! "$REPO_SLUG" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
    error "Invalid repo slug: '$REPO_SLUG' (expected 'owner/repo')"
fi
RUNNER_HOST="poddingue@192.168.1.185"
RUNNER_DIR="/home/poddingue/github-act-runner"
RUNNER_NAME="bananapi-f3-etcher"
SERVICE_NAME="github-runner"

# --- Check local prerequisites ---
for cmd in gh ssh; do
    command -v "$cmd" &>/dev/null || error "$cmd is required but not installed"
done
gh auth status &>/dev/null || error "gh CLI is not authenticated. Run: gh auth login"

# --- Check if already registered ---
info "Checking if $REPO_SLUG is already registered..."
ALREADY_REGISTERED=$(ssh "$RUNNER_HOST" "
    node -e '
        const s = JSON.parse(require(\"fs\").readFileSync(\"$RUNNER_DIR/settings.json\", \"utf8\"));
        const found = (s.Instances || []).some(i => i.RegistrationURL.includes(\"$REPO_SLUG\"));
        console.log(found ? \"yes\" : \"no\");
    '
" 2>/dev/null) || ALREADY_REGISTERED="unknown"

if [ "$ALREADY_REGISTERED" = "yes" ]; then
    warn "$REPO_SLUG is already registered in the runner. Nothing to do."
    echo ""
    echo "Current instances:"
    ssh "$RUNNER_HOST" "
        node -e '
            const s = JSON.parse(require(\"fs\").readFileSync(\"$RUNNER_DIR/settings.json\", \"utf8\"));
            (s.Instances || []).forEach(i => {
                const a = i.Agent || {};
                console.log(\"  \" + a.Name + \" → \" + i.RegistrationURL);
            });
        '
    "
    exit 0
fi

# --- Generate registration token via gh api ---
info "Generating registration token for $REPO_SLUG..."
REG_TOKEN=$(gh api "repos/${REPO_SLUG}/actions/runners/registration-token" \
    --method POST --jq '.token') || \
    error "Failed to get registration token. Check admin access to $REPO_SLUG"

info "Token obtained (expires in 1 hour)"

# --- Register on the remote machine ---
info "Registering $REPO_SLUG on $RUNNER_HOST..."
ssh "$RUNNER_HOST" "
    cd $RUNNER_DIR && \
    ./github-act-runner configure \
        --url 'https://github.com/${REPO_SLUG}' \
        --token '${REG_TOKEN}' \
        --name '${RUNNER_NAME}' \
        --labels 'self-hosted,linux,riscv64' \
        --work '_work'
"

# --- Restart the runner service to pick up the new instance ---
info "Restarting $SERVICE_NAME service..."
ssh "$RUNNER_HOST" "sudo systemctl restart $SERVICE_NAME"

# --- Verify ---
echo ""
info "Registration complete. Current instances:"
ssh "$RUNNER_HOST" "
    node -e '
        const s = JSON.parse(require(\"fs\").readFileSync(\"$RUNNER_DIR/settings.json\", \"utf8\"));
        (s.Instances || []).forEach(i => {
            const a = i.Agent || {};
            const labels = (a.Labels || []).map(l => l.Name).join(\", \");
            console.log(\"  \" + a.Name + \" → \" + i.RegistrationURL + \" [\" + labels + \"]\");
        });
    '
"

echo ""
info "Verify at: https://github.com/${REPO_SLUG}/settings/actions/runners"
info "Trigger build: Actions > 'Build RISC-V64' > Run workflow"
echo ""
warn "Note: MaxParallelism=1 — the ~30min etcher build will queue other jobs."
warn "This is fine for infrequent builds."
