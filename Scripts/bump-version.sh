#!/bin/bash
# bump-version.sh <semver>  — sets MARKETING_VERSION, increments CURRENT_PROJECT_VERSION, tags v<semver>.
set -euo pipefail
NEW="${1:?semver}"
cd "$(dirname "$0")/.."
BUILD=$(grep -E 'CURRENT_PROJECT_VERSION: "' project.yml | head -1 | grep -oE '[0-9]+')
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$NEW\"/; s/CURRENT_PROJECT_VERSION: \"[0-9]+\"/CURRENT_PROJECT_VERSION: \"$((BUILD+1))\"/" project.yml
echo "$NEW" > VERSION
git add project.yml VERSION && git commit -q -m "Version $NEW (build $((BUILD+1)))" && git tag "v$NEW"
echo "tagged v$NEW build $((BUILD+1))"
