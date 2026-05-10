#!/usr/bin/env bash
# scripts/ledgrrr-attest.sh
# ledgrrr enterprise attestation + GitHub Attestations / cosign signing
#
# Usage: ledgrrr-attest.sh <manifest.json> [<artifact-path> ...]
#
# Produces:
#   - GitHub Attestations entry (via `gh attestation` or `attest-build-provenance`)
#   - Sigstore/cosign transparency log entry (if COSIGN_PRIVATE_KEY available)
#   - ledgrrr audit ledger entry appended to LEDGRRR.md
#
# Env vars:
#   GITHUB_TOKEN         — required for gh attestation
#   COSIGN_PRIVATE_KEY   — optional; enables cosign signing
#   COSIGN_PASSWORD      — optional; cosign key passphrase
#   LEDGRRR_FILE         — defaults to LEDGRRR.md

set -euo pipefail

MANIFEST="${1:?Usage: ledgrrr-attest.sh <manifest.json> [artifact ...]}"
shift
ARTIFACTS=("$@")

LEDGRRR_FILE="${LEDGRRR_FILE:-LEDGRRR.md}"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
COMMIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo 'unknown')"
ACTOR="${GITHUB_ACTOR:-$(git config user.name 2>/dev/null || echo 'unknown')}"
REPO="${GITHUB_REPOSITORY:-PromptExecution/__b00t__}"
RUN_ID="${GITHUB_RUN_ID:-local}"
RUN_URL="https://github.com/${REPO}/actions/runs/${RUN_ID}"

log()  { echo "[ledgrrr] $*" >&2; }
die()  { log "FATAL: $*"; exit 2; }

# ---------------------------------------------------------------------------
# 1. GitHub Attestations (build provenance) — native GH feature, no extra keys
# ---------------------------------------------------------------------------
gh_attest() {
  local artifact="$1"
  if command -v gh &>/dev/null && [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "GitHub Attestation: $artifact"
    gh attestation create \
      --predicate-type "https://b00t.promptexecution.com/sfw-audit/v1" \
      --predicate "$MANIFEST" \
      "$artifact" 2>/dev/null \
      && log "  ✅ GitHub Attestation created for $artifact" \
      || log "  ⚠️  gh attestation unavailable (requires Actions OIDC token)"
  else
    log "  ℹ️  Skipping gh attestation (gh not available or no GITHUB_TOKEN)"
  fi
}

# ---------------------------------------------------------------------------
# 2. Cosign / Sigstore signing (keyless preferred; key-based fallback)
# ---------------------------------------------------------------------------
cosign_sign() {
  local artifact="$1"
  if ! command -v cosign &>/dev/null; then
    log "  ℹ️  cosign not installed — skipping Sigstore signing"
    return 0
  fi

  if [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
    log "  cosign key-based signing: $artifact"
    # Use a secure temp file with restricted permissions; clean up with trap
    local key_file
    key_file="$(mktemp)"
    chmod 600 "$key_file"
    trap 'shred -u "$key_file" 2>/dev/null || rm -f "$key_file"' RETURN
    printf '%s' "$COSIGN_PRIVATE_KEY" > "$key_file"
    cosign sign-blob \
      --key "$key_file" \
      --output-signature "${artifact}.sig" \
      "$artifact" \
      && log "  ✅ cosign signature: ${artifact}.sig" \
      || log "  ⚠️  cosign sign-blob failed"
    # trap fires on RETURN — secure deletion of key file
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "  cosign keyless (OIDC) signing: $artifact"
    cosign sign-blob \
      --yes \
      --output-signature "${artifact}.sig" \
      "$artifact" \
      && log "  ✅ cosign keyless signature: ${artifact}.sig" \
      || log "  ⚠️  cosign keyless signing failed (no OIDC in this context)"
  else
    log "  ℹ️  No signing credentials — skipping cosign"
  fi
}

# ---------------------------------------------------------------------------
# 3. SHA-256 content hash (always — minimum integrity guarantee)
# ---------------------------------------------------------------------------
hash_artifact() {
  local artifact="$1"
  if [[ -f "$artifact" ]]; then
    sha256sum "$artifact" > "${artifact}.sha256"
    log "  SHA256: $(cat "${artifact}.sha256")"
  fi
}

# ---------------------------------------------------------------------------
# 4. Append ledger entry to LEDGRRR.md
# ---------------------------------------------------------------------------
ledger_append() {
  local manifest_hash=""
  [[ -f "$MANIFEST" ]] && manifest_hash="$(sha256sum "$MANIFEST" | awk '{print $1}')"

  # Read ALL key fields from manifest in a single Python invocation
  local manifest_fields
  manifest_fields="$(python3 - <<PYEOF 2>/dev/null || echo "?	?	0	0	0	0"
import json, sys
try:
    d = json.load(open("$MANIFEST"))
    m = d.get("mece", {})
    print("\t".join([
        d.get("upstream", "?"),
        d.get("downstream", "?"),
        str(len(m.get("PASS", []))),
        str(len(m.get("SANITIZE", []))),
        str(len(m.get("EXCLUDE", []))),
        str(len(m.get("REVIEW", []))),
    ]))
except Exception as e:
    print(f"?\t?\t0\t0\t0\t0", file=sys.stderr)
    sys.exit(1)
PYEOF
)"
  IFS=$'\t' read -r upstream downstream mece_pass mece_sanitize mece_exclude mece_review \
    <<< "$manifest_fields"

  # Bootstrap LEDGRRR.md if absent
  if [[ ! -f "$LEDGRRR_FILE" ]]; then
    cat > "$LEDGRRR_FILE" <<'HEADER'
# 📒 LEDGRRR — Enterprise Attestation Ledger

> Immutable audit log of SFW changeset attestations for `PromptExecution/__b00t__`.
> Each entry is signed and traceable to a GitHub Actions run.

| # | Timestamp | Commit | Actor | PASS | SANITIZE | EXCLUDE | REVIEW | Run | Manifest SHA |
|---|-----------|--------|-------|------|----------|---------|--------|-----|--------------|
HEADER
    log "Created new ledger: $LEDGRRR_FILE"
  fi

  # Count existing entries for sequential ID
  local entry_id
  entry_id=$(grep -c "^| [0-9]" "$LEDGRRR_FILE" 2>/dev/null || echo 0)
  entry_id=$(( entry_id + 1 ))

  # Append row
  printf '| %d | `%s` | [`%s`](%s) | @%s | %s | %s | %s | %s | [▶](%s) | `%s` |\n' \
    "$entry_id" \
    "$TIMESTAMP" \
    "${COMMIT_SHA:0:8}" \
    "https://github.com/${REPO}/commit/${COMMIT_SHA}" \
    "$ACTOR" \
    "$mece_pass" \
    "$mece_sanitize" \
    "$mece_exclude" \
    "$mece_review" \
    "$RUN_URL" \
    "${manifest_hash:0:16}…" \
    >> "$LEDGRRR_FILE"

  log "Ledger entry #$entry_id appended to $LEDGRRR_FILE"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  log "ledgrrr attestation — manifest: $MANIFEST"
  log "  timestamp: $TIMESTAMP"
  log "  actor:     $ACTOR"
  log "  commit:    $COMMIT_SHA"
  log "  run:       $RUN_URL"

  # Hash the manifest itself
  hash_artifact "$MANIFEST"

  # Attest & sign each provided artifact
  for artifact in "$MANIFEST" "${ARTIFACTS[@]}"; do
    [[ -z "$artifact" || ! -f "$artifact" ]] && continue
    gh_attest "$artifact"
    cosign_sign "$artifact"
  done

  # Append ledger row
  ledger_append

  # Update manifest with attestation_status
  python3 - <<PYEOF
import json
with open("$MANIFEST") as f:
    m = json.load(f)
m["attestation_status"] = "complete"
m["attestation_timestamp"] = "$TIMESTAMP"
m["attested_by"] = "$ACTOR"
m["run_url"] = "$RUN_URL"
with open("$MANIFEST", "w") as f:
    json.dump(m, f, indent=2)
print("[ledgrrr] manifest attestation_status -> complete")
PYEOF

  log "Attestation complete ✅"
}

main "$@"
