import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/terminal_panel.dart';

/// An interactive remote-shell terminal.
///
/// In demo mode (or on web, or with no live session) it attaches an xterm
/// emulator to a simulated [RemoteShell]; with a live SSH session it attaches to
/// a real PTY shell on the control node. The shell is resolved by
/// [terminalShellProvider] and the embedded [TerminalPanel] closes it on
/// dispose.
class TerminalScreen extends ConsumerWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool demo = ref.watch(demoModeProvider);
    final String? host = ref.watch(connectionProvider).profile?.host;

    final String label = demo || host == null ? 'demo' : host;

    return Scaffold(
      backgroundColor: Palette.darkBg,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to dashboard',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        title: Text('Terminal — $label'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
            child: Center(
              child: _StatusChip(
                label: demo ? 'demo' : 'connected',
                color: demo ? Palette.warn : Palette.ok,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
        ],
      ),
      body: TerminalPanel(
        shellProvider: terminalShellProvider,
        title: 'Interactive shell on the control node',
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
