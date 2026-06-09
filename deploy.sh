#!/bin/bash

# Deploy everything: infrastructure + both environments
# For individual deployments, use:
#   ./deploy-infra.sh      - Infrastructure only
#   ./deploy-basic.sh      - Basic monitoring environment
#   ./deploy-enhanced.sh   - Enhanced monitoring environment

set -e

echo "=== Full Deployment ==="
echo ""

./deploy-infra.sh
echo ""
./deploy-basic.sh
echo ""
./deploy-enhanced.sh
