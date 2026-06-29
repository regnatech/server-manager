import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/audit_view.dart';
import '../widgets/section_header.dart';

/// The server-level Security Audit screen, reached from the dashboard.
///
/// Runs `server --json audit` (no domain) through the shared [AuditView],
/// surfacing host-wide findings (SSH, firewall, fail2ban, auto-updates, …)
/// with the same Fix flow as the per-site audit. Auto-runs on open so a
/// screenshot launched at SM_ROUTE=/audit lands on a populated list.
class ServerAuditScreen extends ConsumerWidget {
  const ServerAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool demo = ref.watch(demoModeProvider);
    final String? host = ref.watch(connectionProvider).profile?.host;
    final String label = demo ? 'demo' : (host ?? 'control node');

    final CliService cli = ref.read(cliServiceProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        title: Text('Security Audit — $label'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.lg,
              Insets.lg,
              0,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.security, color: theme.colorScheme.primary),
                const SizedBox(width: Insets.sm),
                const Expanded(
                  child: SectionHeader(
                    title: 'Server hardening',
                    subtitle: 'Host-wide checks across SSH, the firewall, '
                        'fail2ban, updates and service exposure',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AuditView(
              runAudit: () => cli.audit(),
              runFix: (String id) => cli.auditFix(id),
              runFixAll: () => cli.auditFixAll(),
              runHistory: () => cli.auditHistory(),
              autoRun: true,
            ),
          ),
        ],
      ),
    );
  }
}
