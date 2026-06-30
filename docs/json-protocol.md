# server-manager — JSON event protocol (`--json`)

This is the machine-readable output contract for `server --json`. It lets any
client run server-manager non-interactively and render live progress without
parsing the human TTY output.

- **Contract version:** `1` (see `SRVMGR_JSON_CONTRACT` in `lib/core/json.sh`).
  Bumped on any breaking change; a client checks it at the `version` handshake
  and can refuse a mismatched backend.
- **Transport:** run `server --json <command> [args]` directly, or over an SSH
  session to a Linux *control node* where server-manager is installed. The
  control node SSHes out to the managed servers exactly as the CLI does today.

## Invocation

```
server --json version
server --json list
server --json update <site>
server --json add --plan
server --json add --apply --answers /path/to/answers.json
```

`--json` implies non-interactive (`-y`): prompts resolve from the `--answers`
bundle instead of stdin.

## Stream shape

Every line of **stdout** is exactly one JSON object (NDJSON). The discriminator
is the field `t`. Internally events are written to fd 3 (wired to the real
stdout) so that command-substitution capture inside the bash code never
corrupts the stream.

| `t`          | Fields                                              | Meaning |
|--------------|-----------------------------------------------------|---------|
| `version`    | `contract`, `version`                               | Handshake reply |
| `banner`     | `label`                                             | Command started |
| `section`    | `label`                                             | Phase header |
| `step_start` | `id`, `label`                                       | A step began |
| `step_end`   | `id`, `ok` (bool), `dur` (sec), `err?`              | A step finished |
| `log`        | `level` (`info\|ok\|warn\|err`), `msg`              | Free-form message |
| `progress`   | `cur`, `total`, `label`                             | Multi-item progress |
| `need`       | `id`                                                | Apply phase needs more answers (re-run with them) |
| `report`     | `title`, `fields` (object)                          | Final summary card |
| `data`       | `kind`, `items` (array) **or** `value` (object)     | Query result payload |
| `done`       | `ok` (bool)                                         | Terminal event (always last) |

`step_start`/`step_end` share an `id` so a client can correlate them and animate
each node's spinner → check/cross.

## Example: `server --json update clicketta.site`

```json
{"t":"banner","label":"update — clicketta.site @ prod"}
{"t":"section","label":"Preflight"}
{"t":"step_start","id":"s1","label":"Validating git repository"}
{"t":"step_end","id":"s1","ok":true,"dur":0.6}
{"t":"section","label":"Deploy"}
{"t":"step_start","id":"s2","label":"Pulling main from origin"}
{"t":"step_end","id":"s2","ok":true,"dur":1.4}
{"t":"report","title":"Deployed clicketta.site","fields":{"Commit":"a1b2c3d","Duration":"12.3s"}}
{"t":"done","ok":true}
```

## The two-phase `add` wizard

A client can't answer interactive prompts mid-flow, so `add` is split:

1. **Plan** — `server --json add --plan` runs only the read-only part (connect +
   discovery) and emits a form spec:

   ```json
   {"t":"data","kind":"plan","value":{"command":"add","fields":[
     {"id":"domain","type":"domain","label":"Domain","value":null,"required":true},
     {"id":"root","type":"abspath","label":"Web root","value":"/var/www/app/public"},
     {"id":"framework","type":"enum","value":"laravel","options":["laravel","symfony","..."]},
     {"id":"php_version","type":"string","value":"8.3","when":{"framework":"php"}},
     {"id":"https.enable","type":"bool","value":true}
   ]}}
   ```

   Field `type`s: `domain`, `abspath`, `string`, `bool`, `enum` (+ `options`),
   `secret`. Optional `when` makes a field conditional on earlier answers so the
   client can branch dynamically.

2. **Apply** — a client uploads the collected answers as JSON (via SFTP) and runs
   `server --json add --apply --answers <remote-file>`, which streams the normal
   event sequence above. If a required answer is missing the backend emits
   `{"t":"need","id":"..."}` and a client re-runs with it filled in.

## Implementation notes

- `lib/core/json.sh` — the dependency-free JSON encoder (no `jq`/python needed on
  the server). `json_escape`, `json_str`, `json_object`, `json_event`, `json_mode`.
- `lib/core/ui.sh` — the single output choke point. When `SRVMGR_JSON=1`,
  `section`/`step`/`step_capture`/`ok`/`warn`/`err`/`report_box`/`progress_bar`
  emit events instead of TTY text. **No command logic changed** — only the
  presentation layer — so the human CLI and the client share one code path.
- `bin/server` — `--json` sets up fd 3 + the terminal `done` event (via an EXIT
  trap reflecting the exit status).

Covered by `tests/run.sh` (the "JSON event protocol" section).
