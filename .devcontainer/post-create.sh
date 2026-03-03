#!/usr/bin/env bash
set -euo pipefail

echo "==> Installing additional Helm tools..."

# helm-diff plugin (useful for upgrade previews)
helm plugin install https://github.com/databus23/helm-diff 2>/dev/null || true

# helm-unittest plugin (for chart unit tests)
helm plugin install https://github.com/helm-unittest/helm-unittest 2>/dev/null || true

# ct (chart-testing) — linting and testing in CI
if ! command -v ct &>/dev/null; then
  CT_VERSION="3.11.0"
  curl -sSL "https://github.com/helm/chart-testing/releases/download/v${CT_VERSION}/chart-testing_${CT_VERSION}_linux_amd64.tar.gz" \
    | sudo tar -xz -C /usr/local/bin ct
fi

# yamllint for YAML linting
sudo apt-get update -qq && sudo apt-get install -y -qq yamllint >/dev/null 2>&1

# Quick validation
echo "==> Verifying tools..."
helm version --short
kubectl version --client --short 2>/dev/null || kubectl version --client
ct version 2>/dev/null || true
yamllint --version

echo ""
echo "==> Running initial chart lint..."
cd /workspaces/*/  2>/dev/null || cd "$(dirname "$0")/.."
helm lint . --set serverHostname=test.example.com || true

echo ""
echo "==> Dev environment ready!"
echo "    helm template test . --set serverHostname=test.example.com"
echo "    helm lint . --set serverHostname=test.example.com"
echo "    helm template test . -f ci/uw-osdf-cache-values.yaml"
