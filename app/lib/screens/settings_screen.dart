import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../transport/cli_event.dart';
import '../widgets/app_button.dart';
import '../widgets/glass_card.dart';
import '../widgets/section_header.dart';

/// The Settings screen, reached from the dashboard.
///
/// A schema-driven, multi-section form over the generic settings backend
/// (`server --json config list` / `config set`). On load it lists every config
/// field, groups them into General / Git / Notifications, and renders one card
/// per section with a row per field: plain strings get a text box, secrets get
/// an obscured box that never displays the stored value and a set/not-set pill.
/// The Notifications card additionally keeps the legacy "Send test" / "Disable
/// all" actions. Secrets are passed straight through to the CLI and are never
/// persisted in the app.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Ordered sections to render and their pretty titles/subtitles.
  static const List<_SectionSpec> _sections = <_SectionSpec>[
    _SectionSpec(
      id: 'general',
      title: 'General',
      subtitle: 'Defaults for new sites and certificates',
    ),
    _SectionSpec(
      id: 'git',
      title: 'Git',
      subtitle: 'Author identity and GitHub access',
    ),
    _SectionSpec(
      id: 'notifications',
      title: 'Notifications',
      subtitle: 'Get a message on deploy success/failure',
    ),
  ];

  /// Loaded fields grouped by section id; null until the first list resolves.
  Map<String, List<_Field>>? _bySection;
  bool _loading = true;
  bool _failed = false;

  CliService get _cli => ref.read(cliServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final Map<String, List<_Field>> grouped = <String, List<_Field>>{};
    bool gotData = false;
    try {
      await for (final CliEvent e in _cli.configList()) {
        if (e case DataEvent(kind: 'config', items: final List<dynamic>? items)
            when items != null) {
          gotData = true;
          for (final dynamic raw in items) {
            if (raw is! Map) continue;
            final Map<String, dynamic> m = raw.cast<String, dynamic>();
            final _Field f = _Field.fromJson(m);
            (grouped[f.section] ??= <_Field>[]).add(f);
          }
        }
      }
    } catch (_) {
      gotData = false;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = !gotData;
      _bySection = gotData ? grouped : null;
    });
  }

  /// Refreshes a single field's `set` flag after a (secret) save, without
  /// re-fetching the whole form, by marking it configured.
  void _markSet(String key) {
    final Map<String, List<_Field>>? groups = _bySection;
    if (groups == null) return;
    for (final List<_Field> fields in groups.values) {
      for (int i = 0; i < fields.length; i++) {
        if (fields[i].key == key) {
          setState(() => fields[i] = fields[i].copyWith(set: true));
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        title: const Text('Settings'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed || _bySection == null) {
      return _ErrorState(onRetry: _load);
    }
    final Map<String, List<_Field>> groups = _bySection!;

    // Build a card per known section, in order, skipping any with no fields.
    final List<Widget> cards = <Widget>[];
    int index = 0;
    for (final _SectionSpec spec in _sections) {
      final List<_Field> fields = groups[spec.id] ?? const <_Field>[];
      if (fields.isEmpty) continue;
      final bool isNotifications = spec.id == 'notifications';
      cards.add(
        _SettingsSection(
          spec: spec,
          fields: fields,
          cli: _cli,
          onSecretSaved: _markSet,
          showNotifyActions: isNotifications,
        )
            .animate()
            .fadeIn(duration: AppMotion.base, delay: (60 * index).ms)
            .slideY(begin: 0.08, curve: AppMotion.emphasized),
      );
      cards.add(const SizedBox(height: Insets.lg));
      index++;
    }
    if (cards.isNotEmpty) cards.removeLast(); // trailing spacer

    return ListView(
      padding: const EdgeInsets.all(Insets.lg),
      children: cards,
    );
  }
}

/// A pretty section to render and the backend section id it maps to.
class _SectionSpec {
  const _SectionSpec({
    required this.id,
    required this.title,
    required this.subtitle,
  });
  final String id;
  final String title;
  final String subtitle;
}

/// One config field parsed from a `config list` item.
class _Field {
  const _Field({
    required this.key,
    required this.label,
    required this.section,
    required this.secret,
    required this.set,
    required this.value,
  });

  factory _Field.fromJson(Map<String, dynamic> m) => _Field(
        key: m['key']?.toString() ?? '',
        label: m['label']?.toString() ?? (m['key']?.toString() ?? ''),
        section: m['section']?.toString() ?? 'general',
        secret: m['type']?.toString() == 'secret',
        set: m['set'] == true,
        value: m['value']?.toString() ?? '',
      );

  final String key;
  final String label;
  final String section;
  final bool secret;
  final bool set;

  /// Present only for non-secret fields; always '' for secrets.
  final String value;

  _Field copyWith({bool? set}) => _Field(
        key: key,
        label: label,
        section: section,
        secret: secret,
        set: set ?? this.set,
        value: value,
      );
}

/// A GlassCard for one settings section: a [SectionHeader] then a row per
/// field, plus the notify actions when [showNotifyActions] is set.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.spec,
    required this.fields,
    required this.cli,
    required this.onSecretSaved,
    required this.showNotifyActions,
  });

  final _SectionSpec spec;
  final List<_Field> fields;
  final CliService cli;
  final ValueChanged<String> onSecretSaved;
  final bool showNotifyActions;

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[
      SectionHeader(title: spec.title, subtitle: spec.subtitle),
      const SizedBox(height: Insets.sm),
    ];
    for (int i = 0; i < fields.length; i++) {
      if (i > 0) children.add(const SizedBox(height: Insets.lg));
      children.add(
        _FieldRow(
          // Key by config key so each row keeps its own controller/state even
          // as the parent rebuilds after a save.
          key: ValueKey<String>(fields[i].key),
          field: fields[i],
          cli: cli,
          onSecretSaved: onSecretSaved,
        ),
      );
    }
    if (showNotifyActions) {
      children
        ..add(const SizedBox(height: Insets.lg))
        ..add(_NotifyActions(cli: cli));
    }
    return GlassCard(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// A single editable field: label, a text/secret input, an optional set pill,
/// and a Save button that streams `config set` and snackbars the result.
class _FieldRow extends StatefulWidget {
  const _FieldRow({
    super.key,
    required this.field,
    required this.cli,
    required this.onSecretSaved,
  });

  final _Field field;
  final CliService cli;
  final ValueChanged<String> onSecretSaved;

  @override
  State<_FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<_FieldRow> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Non-secret fields pre-fill with their current value; secrets stay empty
    // and only show a "configured" hint when already set.
    _controller = TextEditingController(
      text: widget.field.secret ? '' : widget.field.value,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_saving) return;
    final _Field f = widget.field;
    final String text = _controller.text;
    // Guard empty input where it makes sense: never push an empty secret, and
    // don't bother sending an unchanged non-secret value.
    if (f.secret && text.trim().isEmpty) {
      _snack('Enter a value for ${f.label} first');
      return;
    }
    setState(() => _saving = true);
    bool ok = false;
    try {
      await for (final CliEvent e in widget.cli.configSet(f.key, text)) {
        if (e case DoneEvent(ok: final bool done)) ok = done;
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      _snack('Saved ${f.label}');
      if (f.secret) {
        _controller.clear();
        widget.onSecretSaved(f.key);
      }
    } else {
      _snack('Could not save ${f.label}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final _Field f = widget.field;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              f.label,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (f.secret) ...<Widget>[
              const SizedBox(width: Insets.sm),
              _SetPill(set: f.set),
            ],
          ],
        ),
        const SizedBox(height: Insets.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _controller,
                obscureText: f.secret,
                enableSuggestions: !f.secret,
                autocorrect: !f.secret,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: f.secret
                      ? (f.set ? 'configured' : 'not set')
                      : null,
                  prefixIcon: Icon(
                    f.secret ? Icons.vpn_key_outlined : Icons.tune,
                    size: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            AppButton(
              label: 'Save',
              icon: Icons.save_outlined,
              loading: _saving,
              onPressed: _save,
            ),
          ],
        ),
      ],
    );
  }
}

/// The legacy notify actions (test / disable all), kept in the Notifications
/// section. These drive the `notify` family, independent of `config set`.
class _NotifyActions extends StatefulWidget {
  const _NotifyActions({required this.cli});
  final CliService cli;

  @override
  State<_NotifyActions> createState() => _NotifyActionsState();
}

class _NotifyActionsState extends State<_NotifyActions> {
  /// Which action is streaming, so its control shows a spinner and the other
  /// is disabled meanwhile.
  _NotifyAction? _busy;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _run(_NotifyAction action, Stream<CliEvent> stream) async {
    if (_busy != null) return false;
    setState(() => _busy = action);
    bool ok = false;
    try {
      await for (final CliEvent e in stream) {
        if (e case DoneEvent(ok: final bool done)) ok = done;
      }
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _busy = null);
    return ok;
  }

  Future<void> _sendTest() async {
    final bool ok = await _run(_NotifyAction.test, widget.cli.notifyTest());
    _snack(ok ? 'Test sent' : 'Could not send test');
  }

  Future<void> _disableAll() async {
    final bool ok = await _run(_NotifyAction.off, widget.cli.notifyOff());
    _snack(ok ? 'Notifications disabled' : 'Could not disable notifications');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool anyBusy = _busy != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Divider(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
        const SizedBox(height: Insets.sm),
        Row(
          children: <Widget>[
            AppButton(
              label: 'Send test',
              icon: Icons.notifications_active_outlined,
              tonal: true,
              loading: _busy == _NotifyAction.test,
              onPressed: anyBusy ? null : _sendTest,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: anyBusy ? null : _disableAll,
              icon: const Icon(Icons.notifications_off_outlined, size: 18),
              label: const Text('Disable all'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The notify action currently streaming, used to scope the busy spinner.
enum _NotifyAction { test, off }

/// A small pill summarizing whether a secret is configured.
class _SetPill extends StatelessWidget {
  const _SetPill({required this.set});
  final bool set;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = set ? Palette.ok : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            set ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            set ? 'set' : 'not set',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the initial `config list` fails, with a retry affordance.
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.settings_suggest_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.md),
            Text(
              'Could not load settings',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Insets.lg),
            AppButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
