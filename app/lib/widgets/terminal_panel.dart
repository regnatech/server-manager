import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';
import '../transport/ssh_session.dart';

/// A reusable, embeddable interactive terminal.
///
/// Owns an xterm [Terminal], watches [shellProvider] for a [RemoteShell],
/// wires output↔input in both directions, reports resizes to the PTY, and
/// closes the shell on dispose. Callers pass any provider that yields a
/// [RemoteShell] (the control-node terminal, a per-site shell, …), so the
/// same widget backs both the `/terminal` route and the site detail screen.
///
/// Web-safe: it renders a [DemoShell] when [shellProvider] resolves to one, and
/// the live PTY path is guarded by the provider, not by this widget.
class TerminalPanel extends ConsumerStatefulWidget {
  const TerminalPanel({super.key, required this.shellProvider, this.title});

  /// A provider that resolves to the [RemoteShell] this panel attaches to.
  final ProviderListenable<AsyncValue<RemoteShell>> shellProvider;

  /// Optional caption shown above the terminal (e.g. "Shell — prod-1").
  final String? title;

  @override
  ConsumerState<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends ConsumerState<TerminalPanel> {
  late final Terminal _terminal = Terminal(maxLines: 5000);

  RemoteShell? _shell;
  StreamSubscription<String>? _outputSub;

  /// Wires an opened [RemoteShell] to the xterm [Terminal] (both directions).
  void _attach(RemoteShell shell) {
    if (_shell != null) return;
    _shell = shell;

    _outputSub = shell.output.listen(_terminal.write);
    _terminal.onOutput = (String data) => shell.write(data);
    _terminal.onResize = (int w, int h, int pw, int ph) => shell.resize(w, h);
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _shell?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<RemoteShell> shell = ref.watch(widget.shellProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.title != null) _PanelCaption(title: widget.title!),
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
                  theme: terminalTheme,
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
    );
  }
}

/// A thin caption line above the terminal, matching the app's surface styling.
class _PanelCaption extends StatelessWidget {
  const _PanelCaption({required this.title});
  final String title;

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
        border: Border(bottom: BorderSide(color: Palette.darkBorder)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.terminal, size: 16, color: Palette.teal),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono(
                context,
                size: 12,
                color: Palette.darkTextDim,
              ),
            ),
          ),
        ],
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
const TerminalTheme terminalTheme = TerminalTheme(
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
