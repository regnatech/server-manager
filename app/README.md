# Server Manager UI

A polished Flutter **desktop** client (Windows-first; also macOS & Linux) for
the [`server-manager`](../) bash CLI. It drives the CLI's JSON/headless mode
over SSH and renders deploys as a live, animated timeline.

There is also a **demo mode** that runs entirely on canned data (no SSH), which
additionally lets the app be built and screenshotted on **Flutter web**.

---

## What it does

- Connect to a Linux *control node* over SSH (pure-Dart, [`dartssh2`]).
- List sites and servers, manage a site's deploys, cron, workers, logs and SSL.
- Run `update` / `add` operations and stream every step into an animated
  vertical timeline (spinner → check/cross, growing connectors, expandable
  per-step logs, live progress bar, final report card).
- A guided `add` wizard: Discover → Configure (a dynamic form generated from the
  backend plan, honoring `when` conditions) → Provision → Done.

---

## Architecture

```
                       Flutter UI (screens / widgets)
                                  │
                       Riverpod providers (state/)
        connection_provider · sites_provider · deploy_provider
                                  │
                         CliService  (services/)
              ┌───────────────────┴───────────────────┐
        LiveCliService                           DemoCliService
        (real SSH)                               (canned data, web-safe)
              │                                        │
        SshSession (transport/)                  DemoData (services/)
   ssh_session_io.dart  ── dartssh2 ── dart:io
   ssh_session_stub.dart (web fallback, throws)
              │
   `server --json <cmd>`  ──stdout NDJSON──▶  NdjsonTransformer
                                                   │
                                              CliEvent (sealed union)
```

Key decisions:

- **`CliService` is an interface.** `LiveCliService` talks SSH; `DemoCliService`
  replays recorded events with artificial pacing. Screens depend only on the
  interface, so demo mode is a drop-in substitution.
- **Web safety via conditional imports.** `transport/ssh_session.dart` is an
  abstract facade; the dartssh2 (`dart:io`) implementation in
  `ssh_session_io.dart` is only imported when `dart.library.io` is available.
  On web, `ssh_session_stub.dart` is used and throws if a live session is
  attempted. `transport/platform.dart` does the same for desktop detection so
  `dart:io`'s `Platform` is never referenced on web.
- **Sealed `CliEvent` union** parsed from NDJSON, tolerant of partial lines and
  non-JSON output.
- **Secrets never hit plain storage.** `ConnectionProfile` (non-secret) is
  persisted as JSON in `flutter_secure_storage`; passwords / key passphrases are
  stored under a per-profile key in the OS vault. Private-key *contents* are
  never persisted — only the file path, read at connect time.

### Directory layout

```
lib/
  main.dart                     window_manager init (guarded), ProviderScope, MaterialApp.router
  theme/app_theme.dart          Palette, AppMotion, Insets, dark + light Material 3 themes
  router/app_router.dart        go_router + fade-through transitions, auth redirect
  transport/
    cli_event.dart              sealed CliEvent hierarchy + fromJson
    ndjson.dart                 StreamTransformer<String, CliEvent> (buffers partial lines)
    ssh_session.dart            abstract SshSession facade (conditional impl)
    ssh_session_io.dart         dartssh2 implementation (native)
    ssh_session_stub.dart       web fallback (throws)
    platform.dart / _io / _stub web-safe desktop detection
  models/                       server, site, plan_field, connection_profile (+ .g.dart)
  services/
    cli_service.dart            CliService interface + LiveCliService (shell quoting, NDJSON)
    connection_store.dart       secure profile + secret persistence
    demo_data.dart              canned sites/servers + recorded deploy stream + DemoCliService
  state/                        connection_provider, sites_provider, deploy_provider
  screens/                      connect, dashboard, site_detail, add_wizard
  widgets/                      status_dot, framework_chip, glass_card, app_button,
                                section_header, animated_step_node, deploy_timeline
```

---

## The JSON contract (summary)

Commands are invoked as `server --json <args>` over SSH. Discovery commands:

- `server --json version` → one object `{"t":"version","contract":"1","version":"0.1.0"}`
- `server --json list` → NDJSON ending with `{"t":"data","kind":"sites","items":[…]}`;
  each site `{"domain","server","framework","tls":bool,"last_deploy","health"}`
- `server --json servers` → `{"t":"data","kind":"servers","items":[{"name","host","user","become"}]}`

Long operations (`update`, `add --apply`) stream one JSON object per line. The
sealed union on field `t`:

| `t`          | shape                                                            |
|--------------|------------------------------------------------------------------|
| `banner`     | `{label}`                                                        |
| `section`    | `{label}`                                                        |
| `step_start` | `{id,label}`                                                     |
| `step_end`   | `{id,ok,dur,err?}`                                               |
| `log`        | `{level:"info\|ok\|warn\|err",msg}`                              |
| `progress`   | `{cur,total,label}`                                              |
| `need`       | `{id}` — collect more answers and re-run                         |
| `report`     | `{title,fields:{…}}`                                             |
| `data`       | `{kind,items[]}` or `{kind,value{}}`                             |
| `done`       | `{ok}` — terminal                                                |

The `add` wizard is two-phase: `add --plan` returns
`{"t":"data","kind":"plan","value":{"command":"add","fields":[…]}}` where each
field is `{id,type:"domain|abspath|string|bool|enum|secret",label,value,required,options?,when?}`.
The app then writes the answers JSON to the control node via SFTP and runs
`add --apply --answers <remote-file>`.

---

## Building

This project requires the Flutter SDK (3.27 or newer) and Dart 3.6+.

### Codegen

JSON models are annotated with `json_serializable`. Equivalent `*.g.dart` files
are **committed** so the project compiles out of the box. After editing any
model, regenerate them with:

```bash
dart run build_runner build --delete-conflicting-outputs
```

### Windows (primary target)

```bash
flutter config --enable-windows-desktop
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # if you changed models
flutter run -d windows          # dev
flutter build windows           # release → build\windows\x64\runner\Release\
```

**MSIX packaging:** add the [`msix`] dev dependency and run
`dart run msix:create` to produce an installable `.msix`. Configure the package
identity, publisher and icons under a `msix_config:` section in `pubspec.yaml`.

### macOS / Linux

```bash
flutter config --enable-macos-desktop   # or --enable-linux-desktop
flutter pub get
flutter run -d macos                     # or -d linux
```

### Web (demo only — for screenshots)

Live SSH is not available in the browser, but **demo mode** runs fully on canned
data, so the web build is useful for capturing screenshots of the dashboard,
site detail, deploy timeline and add wizard.

```bash
flutter config --enable-web
flutter pub get
flutter build web        # output in build/web
flutter run -d chrome    # then click "Explore demo"
```

---

## Requirements at runtime (live mode)

`server-manager` must be installed on a Linux control node reachable over SSH,
with the `server` binary on `PATH` and JSON mode (`server --json …`) available.
Authenticate with an SSH key (recommended) or password from the connect screen.

[`dartssh2`]: https://pub.dev/packages/dartssh2
[`msix`]: https://pub.dev/packages/msix
