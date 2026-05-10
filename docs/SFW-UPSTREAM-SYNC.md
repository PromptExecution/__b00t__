# docs/SFW-UPSTREAM-SYNC.md
# SFW Upstream Sync — Architecture & Setup Guide

## Overview

```
elasticdotventures/_b00t_  (personal/everything edition)
        │
        │  push → main
        ▼
  [dispatch-sfw-downstream.yml]  ← add this to upstream _b00t_
        │
        │  POST /repos/PromptExecution/__b00t__/dispatches
        │  event_type: upstream_sync
        │  client_payload: { sha, ref }
        ▼
PromptExecution/__b00t__  (SFW/business edition)
  [sfw-upstream-sync.yml]
        │
        ├─ Job 1: sfw-audit    → MECE classify, strip EXCLUDE, sanitize SANITIZE
        ├─ Job 2: attest-sign  → ledgrrr attestation + cosign/gh-attestation
        └─ Job 3: open-pr      → PR to main with full MECE audit report
```

---

## Required Secrets

### In `PromptExecution/__b00t__`
| Secret | Purpose |
|--------|---------|
| `WORKFLOW_PAT` | GitHub PAT with `repo` + `workflow` scopes; used to push branches and open PRs |
| `COSIGN_PRIVATE_KEY` | _(optional)_ Cosign key for artifact signing |
| `COSIGN_PASSWORD` | _(optional)_ Cosign key passphrase |

### In `elasticdotventures/_b00t_` (upstream)
| Secret | Purpose |
|--------|---------|
| `PROMPTEXECUTION_PAT` | GitHub PAT with `repo` scope on `PromptExecution/__b00t__`; fires `repository_dispatch` |

---

## Upstream Trigger Workflow

Add this file to `elasticdotventures/_b00t_` as a PR contribution:

**`.github/workflows/dispatch-sfw-downstream.yml`**

```yaml
name: Dispatch SFW Downstream Sync

on:
  push:
    branches:
      - main

jobs:
  dispatch-sfw:
    runs-on: ubuntu-latest
    steps:
      - name: Dispatch sfw-upstream-sync to PromptExecution/__b00t__
        env:
          PROMPTEXECUTION_PAT: ${{ secrets.PROMPTEXECUTION_PAT }}
        run: |
          curl -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $PROMPTEXECUTION_PAT" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/PromptExecution/__b00t__/dispatches \
            -d "{\"event_type\":\"upstream_sync\",\"client_payload\":{\"sha\":\"${{ github.sha }}\",\"ref\":\"${{ github.ref }}\"}}"
```

---

## SFW Policy

The SFW variant (`PromptExecution/__b00t__`) includes only:
- ✅ Business-appropriate datums & tooling
- ✅ Western frontier model integrations (OpenAI, Anthropic, GitHub Copilot, etc.)
- 🚫 No ITAR / export-controlled content
- 🚫 No darkweb / onion service references
- 🚫 No NSFW-flagged datums
- 🚫 No Eastern-restricted or personal-only datums

### MECE Categories

Every changed file is classified into exactly ONE of:

| Category | Action | Description |
|----------|--------|-------------|
| **PASS** | Include verbatim | No SFW concerns detected |
| **SANITIZE** | Redact & include | Profanity or minor violations; content redacted in-place |
| **EXCLUDE** | Remove from SFW | ITAR, darkweb, NSFW markers, restricted datums |
| **REVIEW** | Flag for human | Automated classification inconclusive |

---

## ledgrrr Enterprise Attestation

Every sync produces an immutable ledger entry in `LEDGRRR.md`:

```
| # | Timestamp | Commit | Actor | PASS | SANITIZE | EXCLUDE | REVIEW | Run | Manifest SHA |
```

The `sfw-manifest.json` artifact is:
1. SHA-256 hashed (always)
2. Signed via GitHub Attestations (`actions/attest-build-provenance`) when OIDC available
3. Signed via cosign keyless or key-based when `COSIGN_PRIVATE_KEY` configured

---

## Local Development

```bash
# Run SFW audit locally
just sfw

# Audit against specific base
just sfw-audit HEAD~3 /tmp/my-audit

# Attest locally (requires gh auth + cosign)
just sfw-attest /tmp/my-audit

# Show recent ledger entries
just sfw-state

# Manually trigger workflow
just sfw-sync-dispatch
```

---

## Continuous Improvement

The `sfw-auditor` GitHub Copilot agent (`.github/agents/sfw-auditor.agent.md`) handles:
- Adding new SFW lint patterns discovered during audits
- Opening upstream PRs to `elasticdotventures/_b00t_` for SFW lint contributions
- Maintaining `.sfw-audit/STATE.md` state visualization
- Enriching PR descriptions with MECE audit summaries

Assign the agent to any PR or issue for on-demand SFW audit.
