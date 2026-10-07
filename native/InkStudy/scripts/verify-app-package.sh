#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app=${1:?Provide the built InkStudy.app path}
bundle="$app/InkStudyCore_InkStudyCore.bundle"
for resource in state-model.json pigment-spectral-v2.rgb SPECTRAL_LICENSE.txt; do
    if ! /usr/bin/cmp -s "$root/Core/Sources/InkStudyCore/Resources/$resource" "$bundle/$resource"; then
        printf 'error: Missing or stale packaged resource: %s\n' "$resource" >&2
        exit 1
    fi
done
printf 'Verified packaged model, pigment table and license: %s\n' "$app"
