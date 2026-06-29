import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';

import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../transport/ssh_session.dart';

/// An interactive remote-shell terminal.
///
/// In demo mode (or on web, or with no live session) it attaches an xterm
/// emulator to a simulated [RemoteShell]; with a live SSH session it attaches to
/// a real PTY shell on the control node. The shell is resolved by
/// [terminalShellProvider] and closed on dispose.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late final Terminal _terminal = Terminal(maxLines: 5000);

  RemoteShell? _shell;
  StreamSubscription<String>? _outputSub;

  /// Wires an opened [RemoteShell] to the xterm [Terminal] (both directions).
  void _attach(RemoteShell shell) {
    if (_shell != null) return;
    _shell = shell;

    _outputSub = shell.output.listen(_terminal.write);
    _terminal.onOutput = (String data) => shell.write(data);
    _terminal.onResize = (int w, int h, int pw, int ph) =>
        shell.resize(w, h);
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _shell?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool demo = ref.watch(demoModeProvider);
    final String? host = ref.watch(connectionProvider).profile?.host;
    final AsyncValue<RemoteShell> shell = ref.watch(terminalShellProvider);

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
      body: Column(
        children: <Widget>[
          const _TerminalHeader(),
          Expanded(
            child: shell.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object e, _) => _ShellError(message: e.toString()),
              data: (RemoteShell s) {
                _attach(s);
                return Container(
                  color: Palette.darkBg,
                  padding: const EdgeInsets.all(Insets.sm),
                  child: TerminalView(
                    _terminal,
                    autofocus: true,
                    backgroundOpacity: 0,
                    theme: _terminalTheme,
                    textStyle: const TerminalStyle(
                      fontFamily: 'AppMono',
                      fontSize: 13,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin header line above the terminal, matching the app's surface styling.
class _TerminalHeader extends StatelessWidget {
  const _TerminalHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.sm,
      ),
      decoration: const BoxDecoration(
        color: Palette.darkSurface1,
        border: Border(
          bottom: BorderSide(color: Palette.darkBorder),
        ),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.terminal, size: 16, color: Palette.teal),
          const SizedBox(width: Insets.sm),
          Text(
            'Interactive shell on the control node',
            style: AppTheme.mono(
              context,
              size: 12,
              color: Palette.darkTextDim,
            ),
          ),
        ],
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

class _ShellError extends StatelessWidget {
  const _ShellError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 48, color: Palette.err),
          const SizedBox(height: Insets.md),
          Text(
            'Could not open shell',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: Insets.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.mono(context, size: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Terminal palette matching the app: dark surface background, green-ish
/// foreground, with sensible ANSI colors drawn from [Palette].
const TerminalTheme _terminalTheme = TerminalTheme(
  cursor: Palette.teal,
  selection: Color(0x405AA9FF),
  foreground: Color(0xFF6CE5A8),
  background: Palette.darkBg,
  black: Color(0xFF14161F),
  red: Palette.err,
  green: Palette.ok,
  yellow: Palette.warn,
  blue: Palette.info,
  magenta: Palette.violet,
  cyan: Palette.teal,
  white: Palette.darkText,
  brightBlack: Palette.darkTextDim,
  brightRed: Color(0xFFFF7A88),
  brightGreen: Color(0xFF6CE5A8),
  brightYellow: Color(0xFFFFC76B),
  brightBlue: Color(0xFF8AC2FF),
  brightMagenta: Color(0xFF9C8BFF),
  brightCyan: Color(0xFF5CEFDA),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Palette.warn,
  searchHitBackgroundCurrent: Palette.teal,
  searchHitForeground: Palette.darkBg,
);
