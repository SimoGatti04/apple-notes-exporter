#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/Apple Notes Exporter/Apple Notes Exporter.xcodeproj"
DERIVED_DATA_PATH="${APPLE_NOTES_EXPORTER_DERIVED_DATA:-${TMPDIR:-/private/tmp}/apple-notes-exporter-integration-derived}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/Apple Notes Exporter.app"

if [[ ! -d "${PROJECT_PATH}" ]]; then
    echo "Xcode project not found: ${PROJECT_PATH}" >&2
    exit 1
fi

xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "Apple Notes Exporter" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Expected app product was not created: ${APP_PATH}" >&2
    exit 1
fi

printf 'Launching integration build from:\n  project: %s\n  app:     %s\n' "${PROJECT_PATH}" "${APP_PATH}"
open -n "${APP_PATH}"
