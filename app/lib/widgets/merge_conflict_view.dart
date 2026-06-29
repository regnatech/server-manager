import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:highlight/highlight_core.dart' show Mode;
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/plaintext.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

import '../models/git_models.dart';
import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../transport/cli_event.dart';
import 'app_button.dart';
import 'section_header.dart';

/// Picks a `highlight` language [Mode] from a file path's extension.
///
/// `.php`→php, `.json`→json, `.blade.php`/`.html`→xml, `.js`/`.ts`→javascript,
/// `.yaml`/`.yml`→yaml, `.css`→css, `.md`→markdown, `.dart`→dart, else plaintext.
Mode languageForPath(String path) {
  final String lower = path.toLowerCase();
  if (lower.endsWith('.blade.php') ||
      lower.endsWith('.html') ||
      lower.endsWith('.htm') ||
      lower.endsWith('.xml')) {
    return xml;
  }
  if (lower.endsWith('.php')) return php;
  if (lower.endsWith('.json')) return json;
  if (lower.endsWith('.js') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.jsx') ||
      lower.endsWith('.tsx')) {
    return javascript;
  }
  if (lower.endsWith('.yaml') || lower.endsWith('.yml')) return yaml;
  if (lower.endsWith('.css')) return css;
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) return markdown;
  if (lower.endsWith('.dart')) return dart;
  return plaintext;
}

/// A modal conflict-resolution workspace shown after a `git merge` hits
/// conflicts. Left: the conflicted file list. Right: Ours / Theirs (read-only)
/// and an editable Resolution editor, all `CodeField`s with line numbers and
/// dark syntax highlighting. Per-file "Mark resolved" runs `git resolve`; when
/// nothing remains, "Complete merge" runs `git merge-continue`.
class MergeConflictView extends ConsumerStatefulWidget {
  const MergeConflictView({
    super.key,
    required this.domain,
    required this.branch,
    required this.conflicts,
  });

  final String domain;
  final String branch;
  final List<GitConflict> conflicts;

  @override
  ConsumerState<MergeConflictView> createState() => _MergeConflictViewState();
}

class _MergeConflictViewState extends ConsumerState<MergeConflictView> {
  int _selected = 0;
  final Set<String> _resolved = <String>{};
  bool _busy = false;
  String? _progressLabel;

  // Per-file editors, created lazily and disposed on teardown.
  final Map<String, CodeController> _resolution = <String, CodeController>{};
  final Map<String, CodeController> _ours = <String, CodeController>{};
  final Map<String, CodeController> _theirs = <String, CodeController>{};

  @override
  void initState() {
    super.initState();
    for (final GitConflict c in widget.conflicts) {
      final Mode lang = languageForPath(c.path);
      _resolution[c.path] = CodeController(text: c.conflicted, language: lang);
      // Ours/Theirs are made read-only via the CodeField widget (below).
      _ours[c.path] = CodeController(text: c.ours, language: lang);
      _theirs[c.path] = CodeController(text: c.theirs, language: lang);
    }
  }

  @override
  void dispose() {
    for (final CodeController c in _resolution.values) {
      c.dispose();
    }
    for (final CodeController c in _ours.values) {
      c.dispose();
    }
    for (final CodeController c in _theirs.values) {
      c.dispose();
    }
    super.dispose();
  }

  GitConflict get _current => widget.conflicts[_selected];

  bool get _allResolved => _resolved.length >= widget.conflicts.length;

  Future<void> _markResolved() async {
    final GitConflict c = _current;
    final String content = _resolution[c.path]!.fullText;
    setState(() {
      _busy = true;
      _progressLabel = 'Resolving ${c.path}';
    });
    final CliService cli = ref.read(cliServiceProvider);
    bool ok = false;
    await for (final CliEvent e in cli.gitResolve(widget.domain, c.path, content)) {
      if (e is StepStart && mounted) {
        setState(() => _progressLabel = e.label);
      } else if (e is DataEvent && e.kind == 'git_resolved') {
        ok = true;
      } else if (e is DoneEvent) {
        ok = ok || e.ok;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progressLabel = null;
      if (ok) {
        _resolved.add(c.path);
        // Advance to the next still-unresolved file, if any.
        final int next = widget.conflicts.indexWhere(
          (GitConflict x) => !_resolved.contains(x.path),
        );
        if (next >= 0) _selected = next;
      }
    });
  }

  Future<void> _complete() async {
    setState(() {
      _busy = true;
      _progressLabel = 'Completing merge';
    });
    final CliService cli = ref.read(cliServiceProvider);
    bool ok = false;
    await for (final CliEvent e in cli.gitMergeContinue(widget.domain)) {
      if (e is StepStart && mounted) {
        setState(() => _progressLabel = e.label);
      } else if (e is DoneEvent) {
        ok = e.ok;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  Future<void> _abort() async {
    setState(() {
      _busy = true;
      _progressLabel = 'Aborting merge';
    });
    final CliService cli = ref.read(cliServiceProvider);
    await for (final CliEvent e in cli.gitMergeAbort(widget.domain)) {
      if (e is DoneEvent) break;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool compact = context.isCompact;
    return Dialog(
      insetPadding: EdgeInsets.all(compact ? Insets.sm : Insets.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 760),
        child: Padding(
          padding: EdgeInsets.all(compact ? Insets.md : Insets.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SectionHeader(
                title: 'Resolve merge conflicts',
                subtitle:
                    'Merging ${widget.branch} — ${_resolved.length}/${widget.conflicts.length} resolved',
                trailing: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(height: Insets.md),
              Expanded(
                child: compact ? _compactBody() : _wideBody(theme),
              ),
              const SizedBox(height: Insets.md),
              _footer(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Desktop layout: file list on the left, the 3-panel editor on the right.
  Widget _wideBody(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 240,
          child: _ConflictList(
            conflicts: widget.conflicts,
            selected: _selected,
            resolved: _resolved,
            onSelect:
                _busy ? null : (int i) => setState(() => _selected = i),
          ),
        ),
        const SizedBox(width: Insets.md),
        Expanded(child: _editorArea(theme)),
      ],
    );
  }

  /// Phone / narrow layout: a file dropdown on top, then a Ours·Theirs·
  /// Resolution TabBar showing one full-width editor at a time.
  Widget _compactBody() {
    final GitConflict c = _current;
    final bool resolved = _resolved.contains(c.path);
    return DefaultTabController(
      // Start on the editable Resolution tab so the action is one step away.
      initialIndex: 2,
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ConflictDropdown(
            conflicts: widget.conflicts,
            selected: _selected,
            resolved: _resolved,
            onSelect:
                _busy ? null : (int i) => setState(() => _selected = i),
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            children: <Widget>[
              TextButton.icon(
                onPressed:
                    _busy ? null : () => _resolution[c.path]!.text = c.ours,
                icon: const Icon(Icons.arrow_back, size: 15),
                label: const Text('Use ours'),
              ),
              TextButton.icon(
                onPressed:
                    _busy ? null : () => _resolution[c.path]!.text = c.theirs,
                icon: const Icon(Icons.arrow_forward, size: 15),
                label: const Text('Use theirs'),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          const TabBar(
            tabs: <Widget>[
              Tab(text: 'Ours'),
              Tab(text: 'Theirs'),
              Tab(text: 'Resolution'),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _EditorPanel(
                  label: 'Ours (current)',
                  controller: _ours[c.path]!,
                  readOnly: true,
                ),
                _EditorPanel(
                  label: 'Theirs (${widget.branch})',
                  controller: _theirs[c.path]!,
                  readOnly: true,
                ),
                _EditorPanel(
                  label: resolved ? 'Resolution (resolved)' : 'Resolution',
                  controller: _resolution[c.path]!,
                  readOnly: _busy || resolved,
                  accent: resolved ? Palette.ok : Palette.violet,
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.sm),
          SizedBox(
            width: double.infinity,
            child: AppButton(
              label: resolved ? 'Resolved' : 'Mark resolved',
              icon: resolved ? Icons.check : Icons.done_all,
              loading: _busy && _progressLabel != null,
              onPressed: (_busy || resolved) ? null : _markResolved,
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorArea(ThemeData theme) {
    final GitConflict c = _current;
    final bool resolved = _resolved.contains(c.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                c.path,
                style: AppTheme.mono(context, size: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _resolution[c.path]!.text = c.ours,
              icon: const Icon(Icons.arrow_back, size: 15),
              label: const Text('Use ours'),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _resolution[c.path]!.text = c.theirs,
              icon: const Icon(Icons.arrow_forward, size: 15),
              label: const Text('Use theirs'),
            ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        // Ours / Theirs side by side (read-only).
        Expanded(
          flex: 2,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _EditorPanel(
                  label: 'Ours (current)',
                  controller: _ours[c.path]!,
                  readOnly: true,
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: _EditorPanel(
                  label: 'Theirs (${widget.branch})',
                  controller: _theirs[c.path]!,
                  readOnly: true,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Insets.sm),
        // Editable resolution.
        Expanded(
          flex: 3,
          child: _EditorPanel(
            label: resolved ? 'Resolution (resolved)' : 'Resolution',
            controller: _resolution[c.path]!,
            readOnly: _busy || resolved,
            accent: resolved ? Palette.ok : Palette.violet,
          ),
        ),
        const SizedBox(height: Insets.sm),
        Align(
          alignment: Alignment.centerRight,
          child: AppButton(
            label: resolved ? 'Resolved' : 'Mark resolved',
            icon: resolved ? Icons.check : Icons.done_all,
            loading: _busy && _progressLabel != null,
            onPressed: (_busy || resolved) ? null : _markResolved,
          ),
        ),
      ],
    );
  }

  /// The bottom action bar. Wraps so "Abort" / "Complete merge" stay reachable
  /// on a phone where they don't fit on one line.
  Widget _footer(ThemeData theme) {
    final List<Widget> actions = <Widget>[
      AppButton(
        label: 'Abort merge',
        icon: Icons.cancel_outlined,
        tonal: true,
        onPressed: _busy ? null : _abort,
      ),
      AppButton(
        label: 'Complete merge',
        icon: Icons.merge,
        loading: _busy,
        onPressed: (_busy || !_allResolved) ? null : _complete,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_busy && _progressLabel != null) ...<Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  '$_progressLabel…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
        ],
        Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.sm,
          runSpacing: Insets.sm,
          children: actions,
        ),
      ],
    );
  }
}

/// A compact file picker used on narrow screens instead of the left column.
class _ConflictDropdown extends StatelessWidget {
  const _ConflictDropdown({
    required this.conflicts,
    required this.selected,
    required this.resolved,
    required this.onSelect,
  });

  final List<GitConflict> conflicts;
  final int selected;
  final Set<String> resolved;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        border:
            Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: selected,
          isExpanded: true,
          borderRadius: BorderRadius.circular(Insets.radiusMd),
          onChanged: onSelect == null
              ? null
              : (int? i) {
                  if (i != null) onSelect!(i);
                },
          items: <DropdownMenuItem<int>>[
            for (int i = 0; i < conflicts.length; i++)
              DropdownMenuItem<int>(
                value: i,
                child: Row(
                  children: <Widget>[
                    Icon(
                      resolved.contains(conflicts[i].path)
                          ? Icons.check_circle
                          : Icons.warning_amber_rounded,
                      size: 16,
                      color: resolved.contains(conflicts[i].path)
                          ? Palette.ok
                          : Palette.warn,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        conflicts[i].path.split('/').last,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The left-hand list of conflicted files with a per-file resolved indicator.
class _ConflictList extends StatelessWidget {
  const _ConflictList({
    required this.conflicts,
    required this.selected,
    required this.resolved,
    required this.onSelect,
  });

  final List<GitConflict> conflicts;
  final int selected;
  final Set<String> resolved;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.all(Insets.xs),
        itemCount: conflicts.length,
        itemBuilder: (BuildContext context, int i) {
          final GitConflict c = conflicts[i];
          final bool isSel = i == selected;
          final bool done = resolved.contains(c.path);
          return Material(
            color: isSel
                ? theme.colorScheme.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(Insets.radiusSm),
            child: InkWell(
              borderRadius: BorderRadius.circular(Insets.radiusSm),
              onTap: onSelect == null ? null : () => onSelect!(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.sm,
                  vertical: Insets.sm,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      done ? Icons.check_circle : Icons.warning_amber_rounded,
                      size: 16,
                      color: done ? Palette.ok : Palette.warn,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        c.path.split('/').last,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A labeled `CodeField` panel with dark highlighting on a Palette surface.
class _EditorPanel extends StatelessWidget {
  const _EditorPanel({
    required this.label,
    required this.controller,
    this.readOnly = false,
    this.accent,
  });

  final String label;
  final CodeController controller;
  final bool readOnly;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color border =
        (accent ?? theme.colorScheme.outline).withValues(alpha: 0.6);
    return Container(
      decoration: BoxDecoration(
        color: Palette.darkSurface0,
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: 6,
            ),
            color: Palette.darkSurface1,
            child: Row(
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: accent ?? Palette.darkTextDim,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (readOnly)
                  Icon(Icons.lock_outline,
                      size: 12, color: Palette.darkTextDim),
              ],
            ),
          ),
          Expanded(
            child: CodeTheme(
              data: CodeThemeData(styles: atomOneDarkTheme),
              child: SingleChildScrollView(
                child: CodeField(
                  controller: controller,
                  readOnly: readOnly,
                  expands: false,
                  background: Palette.darkSurface0,
                  textStyle: const TextStyle(
                    fontFamily: 'AppMono',
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                  gutterStyle: const GutterStyle(
                    width: 44,
                    textStyle: TextStyle(
                      fontFamily: 'AppMono',
                      fontSize: 11,
                      color: Palette.darkTextDim,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
