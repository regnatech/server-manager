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
/// Currently hosts a single Notifications section that drives the
/// `server --json notify …` family: configure a Slack incoming-webhook or a
/// Telegram bot, send a test message, or disable everything. Destination
/// secrets are passed straight through to the CLI and are never persisted in
/// the app. A status row of pills, refreshed after every action, shows which
/// channels are wired up.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: <Widget>[
          const _NotificationsSection()
              .animate()
              .fadeIn(duration: AppMotion.base)
              .slideY(begin: 0.08, curve: AppMotion.emphasized),
        ],
      ),
    );
  }
}

/// The Notifications card: Slack + Telegram sub-forms, a configured-status
/// row, and test / disable actions.
class _NotificationsSection extends ConsumerStatefulWidget {
  const _NotificationsSection();

  @override
  ConsumerState<_NotificationsSection> createState() =>
      _NotificationsSectionState();
}

class _NotificationsSectionState
    extends ConsumerState<_NotificationsSection> {
  final TextEditingController _slackUrl = TextEditingController();
  final TextEditingController _tgToken = TextEditingController();
  final TextEditingController _tgChat = TextEditingController();

  /// Last loaded status; null until the first [notifyStatus] resolves.
  bool? _slackConfigured;
  bool? _telegramConfigured;
  bool _loadingStatus = false;

  /// Which inline action is currently running, so its button shows a spinner
  /// and the others are disabled while it streams.
  _Action? _busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStatus());
  }

  @override
  void dispose() {
    _slackUrl.dispose();
    _tgToken.dispose();
    _tgChat.dispose();
    super.dispose();
  }

  CliService get _cli => ref.read(cliServiceProvider);

  Future<void> _loadStatus() async {
    if (!mounted) return;
    setState(() => _loadingStatus = true);
    bool? slack;
    bool? telegram;
    try {
      await for (final CliEvent e in _cli.notifyStatus()) {
        if (e case DataEvent(kind: 'notify', value: final Map<String, dynamic>? v)
            when v != null) {
          slack = v['slack'] == true;
          telegram = v['telegram'] == true;
        }
      }
    } catch (_) {
      // Leave previous status in place on failure.
    }
    if (!mounted) return;
    setState(() {
      _loadingStatus = false;
      if (slack != null) _slackConfigured = slack;
      if (telegram != null) _telegramConfigured = telegram;
    });
  }

  /// Drains [stream] to its [DoneEvent], returning whether it ended ok. Marks
  /// [action] busy for the duration so the matching button spins.
  Future<bool> _run(_Action action, Stream<CliEvent> stream) async {
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

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveSlack() async {
    final String url = _slackUrl.text.trim();
    if (url.isEmpty) {
      _snack('Enter a Slack webhook URL first');
      return;
    }
    final bool ok = await _run(_Action.slack, _cli.notifySetSlack(url));
    _snack(ok ? 'Saved' : 'Could not save Slack webhook');
    if (ok) await _loadStatus();
  }

  Future<void> _saveTelegram() async {
    final String token = _tgToken.text.trim();
    final String chat = _tgChat.text.trim();
    if (token.isEmpty || chat.isEmpty) {
      _snack('Enter both a bot token and a chat id');
      return;
    }
    final bool ok =
        await _run(_Action.telegram, _cli.notifySetTelegram(token, chat));
    _snack(ok ? 'Saved' : 'Could not save Telegram bot');
    if (ok) await _loadStatus();
  }

  Future<void> _sendTest() async {
    final bool ok = await _run(_Action.test, _cli.notifyTest());
    _snack(ok ? 'Test sent' : 'Could not send test');
    if (ok) await _loadStatus();
  }

  Future<void> _disableAll() async {
    final bool ok = await _run(_Action.off, _cli.notifyOff());
    _snack(ok ? 'Disabled' : 'Could not disable notifications');
    if (ok) await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool anyBusy = _busy != null;

    return GlassCard(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader(
            title: 'Notifications',
            subtitle: 'Get a message on deploy success/failure',
          ),
          const SizedBox(height: Insets.md),
          _StatusRow(
            slackConfigured: _slackConfigured,
            telegramConfigured: _telegramConfigured,
            loading: _loadingStatus,
          ),
          const SizedBox(height: Insets.lg),
          _ChannelForm(
            icon: Icons.tag,
            title: 'Slack',
            fields: <Widget>[
              TextField(
                controller: _slackUrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Incoming webhook URL',
                  hintText: 'https://hooks.slack.com/services/…',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
            ],
            onSave: anyBusy ? null : _saveSlack,
            saving: _busy == _Action.slack,
          ),
          const SizedBox(height: Insets.lg),
          _ChannelForm(
            icon: Icons.send,
            title: 'Telegram',
            fields: <Widget>[
              TextField(
                controller: _tgToken,
                decoration: const InputDecoration(
                  labelText: 'Bot token',
                  hintText: '123456:ABC-DEF…',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
              ),
              const SizedBox(height: Insets.sm),
              TextField(
                controller: _tgChat,
                decoration: const InputDecoration(
                  labelText: 'Chat id',
                  hintText: '@channel or -1001234567890',
                  prefixIcon: Icon(Icons.forum_outlined),
                ),
              ),
            ],
            onSave: anyBusy ? null : _saveTelegram,
            saving: _busy == _Action.telegram,
          ),
          const SizedBox(height: Insets.lg),
          Divider(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
          const SizedBox(height: Insets.md),
          Row(
            children: <Widget>[
              AppButton(
                label: 'Send test',
                icon: Icons.notifications_active_outlined,
                tonal: true,
                loading: _busy == _Action.test,
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
      ),
    );
  }
}

/// The inline action currently streaming, used to scope the busy spinner.
enum _Action { slack, telegram, test, off }

/// A labeled sub-section (Slack / Telegram) with its fields and a Save button.
class _ChannelForm extends StatelessWidget {
  const _ChannelForm({
    required this.icon,
    required this.title,
    required this.fields,
    required this.onSave,
    required this.saving,
  });

  final IconData icon;
  final String title;
  final List<Widget> fields;
  final VoidCallback? onSave;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: Insets.sm),
            Text(
              title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        ...fields,
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerRight,
          child: AppButton(
            label: 'Save',
            icon: Icons.save_outlined,
            loading: saving,
            onPressed: onSave,
          ),
        ),
      ],
    );
  }
}

/// Two pills summarizing which channels are configured, driven by
/// `notifyStatus()`. A muted "—" pill is shown until the first status loads.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.slackConfigured,
    required this.telegramConfigured,
    required this.loading,
  });

  final bool? slackConfigured;
  final bool? telegramConfigured;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _StatusPill(label: 'Slack', configured: slackConfigured),
        const SizedBox(width: Insets.sm),
        _StatusPill(label: 'Telegram', configured: telegramConfigured),
        if (loading) ...<Widget>[
          const SizedBox(width: Insets.md),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ],
    );
  }
}

/// One status pill: green "configured" when set, muted "not configured"
/// otherwise (or "…" before the first load).
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.configured});

  final String label;
  final bool? configured;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool on = configured == true;
    final Color color = on ? Palette.ok : theme.colorScheme.onSurfaceVariant;
    final String state = configured == null
        ? '…'
        : (on ? 'configured' : 'not configured');

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
            on ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            '$label: $state',
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
