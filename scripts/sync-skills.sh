#!/usr/bin/env bash
# sync-skills.sh — Download latest skills from GitHub releases & repo
# Target: /home/bala/.openclaw/workspace/skills/

set -euo pipefail

RELEASE_TAG="v1.0.0"
REPO="baladengale/claude-skills"
RELEASE_BASE="https://github.com/${REPO}/releases/download/${RELEASE_TAG}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main/skills"
SKILLS_DIR="/home/bala/.openclaw/workspace/skills"

SKILLS=(
  "market-overview"
  "tech-intel"
)

echo "==> Syncing skills [${RELEASE_TAG}] -> ${SKILLS_DIR}"

for SKILL in "${SKILLS[@]}"; do
  TARGET="${SKILLS_DIR}/${SKILL}"
  BINARY="${SKILL}-linux-amd64"

  echo ""
  echo "--- ${SKILL} ---"
  mkdir -p "${TARGET}"

  echo "  Downloading binary..."
  curl -fSL -o "${TARGET}/${BINARY}" "${RELEASE_BASE}/${BINARY}"
  chmod +x "${TARGET}/${BINARY}"

  echo "  Downloading SKILL.md..."
  curl -fsSL -o "${TARGET}/SKILL.md" "${RAW_BASE}/${SKILL}/SKILL.md"

  echo "  Downloading template.html..."
  curl -fsSL -o "${TARGET}/template.html" "${RAW_BASE}/${SKILL}/template.html"

  echo "  Done: $(ls -lah ${TARGET} | tail -n +2 | awk '{print $NF, $5}' | xargs)"
done

echo ""
echo "==> Sync complete. Skills installed:"
find "${SKILLS_DIR}" -type f | sort
