# MCP Datum Schema Reference

Ground truth for what an `<name>.mcp.toml` datum actually accepts, taken
directly from the real Rust types b00t-cli deserializes into — not
reverse-engineered from existing files. Written 2026-09-29 in response to
b00t task backlog issues #59-#64 (kr0ki repo), several of which reported
incorrect or missing schema information gathered by trial and error.

**Check your work**: `b00t datum validate <file>.mcp.toml` now attempts
the real deserialization (not just a hand-rolled field checklist) and
reports the exact line/column/field of any mismatch — run it before
`mcp install`, not after.

## `[b00t]` (required table)

Source: `BootDatum` in `src/boot_datum.rs`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | **yes** | |
| `type` | string | **yes** (functionally) | Must be `"mcp"` for this datum kind |
| `hint` | string | **yes** | One-line description |
| `lfmf_category` | string | no | Groups `b00t lfmf` lessons for this datum |
| `hook_detect` | string | no | e.g. `"gates"` — runs gate evaluation as the detect hook |
| `env` | table of **strings** | no | `KEY = "value"` pairs — see [`[b00t.env]`](#booteenv-flat-strings-only) below, this is NOT the `{default=, description=}` shape |
| `install` | table or string | no | See [`[b00t.install]`](#bootinstall) |
| `requires_sudo` | bool | no | |

Unknown top-level fields inside `[b00t]` are silently dropped by serde
(`BootDatum` does not use `deny_unknown_fields`) — they won't cause a
parse error, but they also aren't read by anything. `datum validate`'s
hand-rolled checker will WARN (not error) about fields it doesn't
recognize; that warning is about its own checklist being incomplete, not
a schema violation.

## `[b00t.env]` (flat strings only)

```toml
[b00t.env]
BROWSER_URL = "http://localhost:9222"
```

This deserializes into `Option<HashMap<String, String>>`. Values **must**
be plain strings.

```toml
# INVALID — this is the exact mistake in b00t task backlog issue #60:
[b00t.env]
BROWSER_URL = { default = "", description = "..." }
# error: invalid type: map, expected a string
```

There is no metadata shape (`default`/`description`/etc.) for env vars —
put that context in a comment above the key instead.

## `[[b00t.mcp.stdio]]` (array of tables)

Source: `McpStdioMethod` in `src/datum_mcp.rs`. A datum can declare
multiple stdio methods (e.g. a podman-backed one and an npx fallback);
`select_best_method()` picks the lowest-`priority` one whose `requires`
are all satisfied (`check_command_available` per entry — recognized
constraint strings: `node`, `python`, `docker`, `podman`, `internet`,
or `CMD:<name>` to check an arbitrary command; anything else is treated
as satisfied).

| Field | Type | Required | Notes |
|---|---|---|---|
| `command` | string | **yes** | |
| `args` | array of strings | no (defaults empty) | Supports `{{env.VAR_NAME}}` substitution as of the #61 fix — unresolved placeholders are left literal with a stderr warning |
| `transport` | string | no | Conventionally `"stdio"`; not read to change behavior |
| `priority` | integer | no (default 0) | Lower wins |
| `requires` | array of strings | no | See above |
| `env` | table of strings | no | Static env vars for this method specifically |

```toml
[[b00t.mcp.stdio]]
priority = 0
command = "podman"
args = ["run", "-i", "--rm", "some/image"]
requires = ["podman"]

[[b00t.mcp.stdio]]
priority = 10
command = "npx"
args = ["-y", "some-mcp-server@latest"]
requires = ["node"]
```

## `[b00t.mcp.httpstream]` (single table, not an array)

Source: `McpHttpStreamMethod`.

| Field | Type | Required |
|---|---|---|
| `url` | string | **yes** |
| `priority` | integer | no (default 0) |
| `requires` | array of strings | no |
| `requires_internet` | bool | no (default true) |
| `requires_auth` | bool | no (default false) |
| `transport` | string | no |

## `[[b00t.gate]]` (array of tables)

Source: `GateSpec` in `src/gates.rs`. All fields are optional; a gate
with none of them present trivially passes.

| Field | Type | Meaning |
|---|---|---|
| `command` | string | Must exist on PATH |
| `file` | string | Must exist (supports `~`) |
| `env` | string | Env var (or `.env` key) must be set and non-empty |
| `rhai` | string | Rhai expression, must evaluate `true`. Vars available: `name`, `datum_type`, `path` |

```toml
[[b00t.gate]]
rhai = "command_exists(\"podman\") || command_exists(\"docker\")"
hint = "install podman or docker"
```

## `[b00t.install]`

Source: `InstallSpec` in `src/config_types.rs` — an untagged enum, so any
one of these shapes is accepted:

```toml
# Plain command (or CommandTable — `command`/`cmd` are aliases)
[b00t.install]
command = "npx playwright install --with-deps"
```

```toml
# Package manager shorthand
[b00t.install]
package = "ripgrep"
apt = "ripgrep"
brew = "ripgrep"
```

```toml
# Language-tool shorthand
[b00t.install]
cargo = "some-crate --locked"
```

`command`/`cmd` is what almost every real MCP datum uses in practice —
it's just a shell command string, run via `bash -c`.

## `[[b00t.usage]]` (array of tables)

Source: `UsageExample` in `src/config_types.rs`. Purely documentary —
shown to humans/agents, not executed automatically.

| Field | Type | Required |
|---|---|---|
| `description` | string | **yes** |
| `command` | string | **yes** |
| `output` | string | no |

```toml
[[b00t.usage]]
description = "Run the stdio transport directly (what an MCP client spawns)"
command = "npx -y some-mcp-server@latest"
```

## `[[b00t.references]]` — NOT part of the schema

This block appears throughout real, working datums (`ssh-mcp.mcp.toml`,
`sysml-v2-lsp.mcp.toml`, `gh-runner.hive.toml`, and others) and does
**not** cause a parse error — but that's only because `BootDatum` ignores
unknown fields, not because `references` is a real field anywhere in the
struct. It's tolerated convention (a human-readable link list), not
consumed by any code path. Treat it the same way as a TOML comment: fine
to include, nothing reads it programmatically today.

## Minimal working example

```toml
[b00t]
name = "example-server"
type = "mcp"
hint = "One-line description of what this MCP server does"

[[b00t.mcp.stdio]]
priority = 0
command = "npx"
args = ["-y", "example-mcp-server@latest"]
requires = ["node"]

[[b00t.gate]]
command = "npx"
```

That's the whole schema surface that's actually load-bearing. Everything
else in this doc is enrichment (`install`, `usage`, `gate` detail) that
real datums use but that a minimal one can skip.
