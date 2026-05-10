#!/usr/bin/env bash
# scripts/sfw-audit.sh
# SFW (Safe-For-Work) audit script: elasticdotventures/_b00t_ => PromptExecution/__b00t__
#
# Purpose: MECE audit of upstream changes — strip NSFW/ITAR/darkweb datums,
#          emit structured diff + attestation manifest.
#
# Usage: sfw-audit.sh [--diff-base REF] [--output-dir DIR]
#
# Outputs:
#   $OUTPUT_DIR/sfw-audit-report.md   — MECE audit report
#   $OUTPUT_DIR/sfw-diff.patch        — sanitized unified diff
#   $OUTPUT_DIR/sfw-manifest.json     — machine-readable MECE manifest
#   $OUTPUT_DIR/blocked-files.txt     — files excluded from SFW variant
#
# Exit codes: 0=clean, 1=blocked content found (PR still raised, just flagged)

set -euo pipefail

# --- config -------------------------------------------------------------------
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
DIFF_BASE="${1:-HEAD~1}"
OUTPUT_DIR="${2:-/tmp/sfw-audit}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# MECE categories — Mutually Exclusive, Collectively Exhaustive
# Each file MUST land in exactly ONE category.
declare -A CATEGORY_LABEL=(
  [PASS]="✅ SFW — included as-is"
  [SANITIZE]="🔧 SFW — content sanitized"
  [EXCLUDE]="🚫 SFW — excluded (NSFW/ITAR/darkweb)"
  [REVIEW]="⚠️  SFW — manual review required"
)

# Patterns triggering EXCLUDE
EXCLUDE_PATTERNS=(
  # ITAR / export-controlled
  "itar\|export.control\|munitions\|ear.99\|EAR99"
  # Darkweb / onion / tor
  "\.onion\|darkweb\|dark.web\|tor2web\|torsocks"
  # NSFW content markers used in upstream _b00t_
  "nsfw\|NSFW\|adult.only\|18\+.only"
  # Datums explicitly flagged Eastern-restricted or personal-only in upstream README
  "Eastern models\|darkweb\|ITAR restricted"
)

# Paths always excluded from SFW variant
EXCLUDE_PATHS=(
  "_b00t_/darkweb*"
  "_b00t_/itar*"
  "_b00t_/*.nsfw.*"
  "*.nsfw.*"
  "jarrgon.🏴‍☠️*"  # pirate/NSFW jargon variant
)

# Paths requiring sanitization (replace bad patterns, keep file)
SANITIZE_PATTERNS=(
  "fuck\|shit\|damn\|ass\|bitch\|crap"  # profanity → redacted
)

# --- helpers ------------------------------------------------------------------
log()  { echo "[sfw-audit] $*" >&2; }
die()  { log "FATAL: $*"; exit 2; }

contains_exclude() {
  local file="$1"
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    if grep -qiP "$pat" "$file" 2>/dev/null; then
      echo "$pat"
      return 0
    fi
  done
  return 1
}

path_excluded() {
  local file="$1"
  for pat in "${EXCLUDE_PATHS[@]}"; do
    # shellcheck disable=SC2254
    case "$file" in $pat) return 0 ;; esac
  done
  return 1
}

contains_sanitize() {
  local file="$1"
  for pat in "${SANITIZE_PATTERNS[@]}"; do
    if grep -qiP "$pat" "$file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

sanitize_file() {
  local file="$1"
  for pat in "${SANITIZE_PATTERNS[@]}"; do
    # Replace matched words with [REDACTED] — case insensitive
    sed -i -E "s/($pat)/[REDACTED]/gI" "$file" 2>/dev/null || true
  done
}

# --- main ---------------------------------------------------------------------
main() {
  mkdir -p "$OUTPUT_DIR"
  cd "$REPO_ROOT"

  log "SFW audit starting — base: $DIFF_BASE, output: $OUTPUT_DIR"

  # 1. Collect changed files relative to diff base
  mapfile -t CHANGED_FILES < <(git diff --name-only "$DIFF_BASE" HEAD 2>/dev/null || git diff --name-only HEAD 2>/dev/null || find . -name '*.md' -not -path './.git/*' | head -100)

  log "Changed files: ${#CHANGED_FILES[@]}"

  # 2. MECE classification
  declare -A FILE_CATEGORY
  declare -a PASS_LIST SANITIZE_LIST EXCLUDE_LIST REVIEW_LIST

  for file in "${CHANGED_FILES[@]}"; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$file" ]] && { FILE_CATEGORY["$file"]="REVIEW"; REVIEW_LIST+=("$file (deleted/renamed)"); continue; }

    if path_excluded "$file"; then
      FILE_CATEGORY["$file"]="EXCLUDE"
      EXCLUDE_LIST+=("$file")
    elif reason=$(contains_exclude "$file"); then
      FILE_CATEGORY["$file"]="EXCLUDE"
      EXCLUDE_LIST+=("$file  # matched: $reason")
    elif contains_sanitize "$file"; then
      FILE_CATEGORY["$file"]="SANITIZE"
      SANITIZE_LIST+=("$file")
    else
      FILE_CATEGORY["$file"]="PASS"
      PASS_LIST+=("$file")
    fi
  done

  # 3. Apply sanitization to SANITIZE files (in-place on working copy)
  for file in "${SANITIZE_LIST[@]}"; do
    sanitize_file "$file"
    log "Sanitized: $file"
  done

  # 4. Generate sanitized diff (exclude blocked files)
  {
    git diff "$DIFF_BASE" HEAD -- "${PASS_LIST[@]:-/dev/null}" 2>/dev/null || true
    for f in "${SANITIZE_LIST[@]}"; do
      git diff "$DIFF_BASE" HEAD -- "$f" 2>/dev/null || true
    done
  } > "$OUTPUT_DIR/sfw-diff.patch" || true

  # 5. Write blocked files list
  printf '%s\n' "${EXCLUDE_LIST[@]:-}" > "$OUTPUT_DIR/blocked-files.txt"

  # 6. Generate MECE audit report (Markdown)
  TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  COMMIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
  UPSTREAM_SHA="$(git ls-remote https://github.com/elasticdotventures/_b00t_.git HEAD 2>/dev/null | awk '{print $1}' || echo 'unknown')"

  cat > "$OUTPUT_DIR/sfw-audit-report.md" <<REPORT
# 🔍 SFW Audit Report — PromptExecution/__b00t__

**Audit timestamp**: \`$TIMESTAMP\`
**Downstream commit**: \`$COMMIT_SHA\`
**Upstream ref**: elasticdotventures/_b00t_ @ \`$UPSTREAM_SHA\`
**Diff base**: \`$DIFF_BASE\`

---

## MECE Classification Summary

| Category | Count | Description |
|----------|------:|-------------|
| ✅ PASS | ${#PASS_LIST[@]} | ${CATEGORY_LABEL[PASS]} |
| 🔧 SANITIZE | ${#SANITIZE_LIST[@]} | ${CATEGORY_LABEL[SANITIZE]} |
| 🚫 EXCLUDE | ${#EXCLUDE_LIST[@]} | ${CATEGORY_LABEL[EXCLUDE]} |
| ⚠️ REVIEW | ${#REVIEW_LIST[@]} | ${CATEGORY_LABEL[REVIEW]} |
| **TOTAL** | **${#CHANGED_FILES[@]}** | **Files audited** |

---

## ✅ PASS — SFW, included verbatim

$(printf -- '- %s\n' "${PASS_LIST[@]:-_none_}")

## 🔧 SANITIZE — Content redacted, file retained

$(printf -- '- %s\n' "${SANITIZE_LIST[@]:-_none_}")

## 🚫 EXCLUDE — Removed from SFW variant

$(printf -- '- %s\n' "${EXCLUDE_LIST[@]:-_none_}")

## ⚠️ REVIEW — Manual review required

$(printf -- '- %s\n' "${REVIEW_LIST[@]:-_none_}")

---

## SFW Policy

The SFW variant (\`PromptExecution/__b00t__\`) includes only:
- Business-appropriate datums & tooling
- Western model integrations
- No ITAR/export-controlled content
- No darkweb/onion service references
- No NSFW-flagged content

Source: [elasticdotventures/_b00t_](https://github.com/elasticdotventures/_b00t_) (personal/everything edition)

---

_Generated by \`scripts/sfw-audit.sh\` | ledgrrr attestation pending_
REPORT

  # 7. Generate machine-readable MECE manifest (JSON)
  python3 - <<PYEOF > "$OUTPUT_DIR/sfw-manifest.json"
import json, datetime

manifest = {
    "schema": "sfw-manifest/v1",
    "timestamp": "$TIMESTAMP",
    "upstream": "elasticdotventures/_b00t_",
    "downstream": "PromptExecution/__b00t__",
    "commit_sha": "$COMMIT_SHA",
    "upstream_sha": "$UPSTREAM_SHA",
    "diff_base": "$DIFF_BASE",
    "mece": {
        "PASS":     [f.strip() for f in """${PASS_LIST[*]:-}""".strip().splitlines() if f.strip()],
        "SANITIZE": [f.strip() for f in """${SANITIZE_LIST[*]:-}""".strip().splitlines() if f.strip()],
        "EXCLUDE":  [f.strip() for f in """${EXCLUDE_LIST[*]:-}""".strip().splitlines() if f.strip()],
        "REVIEW":   [f.strip() for f in """${REVIEW_LIST[*]:-}""".strip().splitlines() if f.strip()],
    },
    "policy": {
        "exclude_patterns": [
            "ITAR/export-controlled",
            "darkweb/onion/tor",
            "NSFW markers",
            "Eastern-restricted datums"
        ],
        "sanitize_patterns": ["profanity"],
    },
    "attestation_status": "pending"
}

print(json.dumps(manifest, indent=2))
PYEOF

  log "Audit complete."
  log "  PASS:     ${#PASS_LIST[@]}"
  log "  SANITIZE: ${#SANITIZE_LIST[@]}"
  log "  EXCLUDE:  ${#EXCLUDE_LIST[@]}"
  log "  REVIEW:   ${#REVIEW_LIST[@]}"
  log "  Report:   $OUTPUT_DIR/sfw-audit-report.md"
  log "  Manifest: $OUTPUT_DIR/sfw-manifest.json"
  log "  Patch:    $OUTPUT_DIR/sfw-diff.patch"
  log "  Blocked:  $OUTPUT_DIR/blocked-files.txt"

  # Exit 1 if any files were excluded (caller can decide whether to block)
  [[ ${#EXCLUDE_LIST[@]} -gt 0 ]] && exit 1 || exit 0
}

main "$@"
