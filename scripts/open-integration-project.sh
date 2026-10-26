#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/Apple Notes Exporter/Apple Notes Exporter.xcodeproj"

if [[ ! -d "${PROJECT_PATH}" ]]; then
    echo "Xcode project not found: ${PROJECT_PATH}" >&2
    exit 1
fi

BRANCH="$(git -C "${REPO_ROOT}" branch --show-current)"
COMMIT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
printf 'Opening this checkout in Xcode:\n  project: %s\n  branch:  %s\n  commit:  %s\n' \
    "${PROJECT_PATH}" "${BRANCH:-detached}" "${COMMIT}"
open -a Xcode "${PROJECT_PATH}"
