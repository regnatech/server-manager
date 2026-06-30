import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/plan_field.dart';
import '../state/connection_provider.dart';
import '../state/deploy_provider.dart';
import '../state/sites_provider.dart';
import '../theme/app_theme.dart';
import '../transport/cli_event.dart';
import '../widgets/app_button.dart';
import '../widgets/deploy_timeline.dart';
import '../widgets/section_header.dart';

/// Animated wizard for `add`: Discover (fetch plan) → Configure (dynamic form)
/// → Provision (live timeline) → Done (report card).
class AddWizardScreen extends ConsumerStatefulWidget {
  const AddWizardScreen({super.key});

  @override
  ConsumerState<AddWizardScreen> createState() => _AddWizardScreenState();
}

enum _WizardStep { discover, configure, provision, done }

class _AddWizardScreenState extends ConsumerState<AddWizardScreen> {
  _WizardStep _step = _WizardStep.discover;
  AddPlan? _plan;
  final Map<String, String> _answers = <String, String>{};
  String? _error;

  /// True when the control node has no target server registered yet, so the
  /// wizard offers one-tap self-registration before configuring a site.
  bool _needsServer = false;
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _step = _WizardStep.discover;
      _error = null;
    });
    try {
      final cli = ref.read(cliServiceProvider);
      AddPlan? plan;
      await for (final CliEvent e in cli.addPlan()) {
        if (e is DataEvent && e.kind == 'plan' && e.value != null) {
          plan = AddPlan.fromValue(e.value!);
        } else if (e is DoneEvent) {
          break;
        }
      }
      if (!mounted) return;
      if (plan == null) {
        setState(() => _error = 'Backend returned no plan.');
        return;
      }
      // The plan only carries a 'server' field when a target server is
      // registered; its absence means the control node has none yet.
      final bool hasServer =
          plan.fields.any((PlanField f) => f.id == 'server');
      if (!hasServer) {
        setState(() {
          _plan = plan;
          _needsServer = true;
        });
        return;
      }
      // Seed defaults.
      for (final PlanField f in plan.fields) {
        if (f.value != null) _answers[f.id] = f.value!;
      }
      setState(() {
        _plan = plan;
        _step = _WizardStep.configure;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Registers the connected box as a managed target (self-hosting), then
  /// re-discovers so the wizard can proceed.
  Future<void> _registerSelf() async {
    setState(() {
      _registering = true;
      _error = null;
    });
    try {
      final cli = ref.read(cliServiceProvider);
      bool ok = false;
      final List<String> errs = <String>[];
      await for (final CliEvent e in cli.registerSelf()) {
        if (e is DoneEvent) {
          ok = e.ok;
        } else if (e is LogEvent && e.level == 'err') {
          errs.add(e.msg);
        } else if (e is StepEnd && !e.ok && e.err != null) {
          errs.add(e.err!);
        }
      }
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _registering = false;
          _error = errs.isEmpty
              ? 'Could not register this server.'
              : errs.join('\n');
        });
        return;
      }
      ref.invalidate(serversProvider);
      setState(() {
        _registering = false;
        _needsServer = false;
      });
      await _discover();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _registering = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _provision() async {
    setState(() => _step = _WizardStep.provision);
    final Map<String, String> visible = <String, String>{
      for (final PlanField f in _plan!.fields)
        if (f.isVisible(_answers)) f.id: _answers[f.id] ?? '',
    };
    final List<int> bytes = utf8.encode(jsonEncode(visible));
    final cli = ref.read(cliServiceProvider);
    final Stream<CliEvent> events = await cli.addApply(answersBytes: bytes);
    if (!mounted) return;
    ref.read(addProvisionProvider.notifier).start(events);
  }

  @override
  Widget build(BuildContext context) {
    // Advance to "done" once the provision stream terminates.
    ref.listen<DeployState>(addProvisionProvider, (DeployState? p, DeployState n) {
      if (n.done && _step == _WizardStep.provision) {
        setState(() => _step = _WizardStep.done);
      }
    });

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/dashboard'),
        ),
        title: const Text('Add a site'),
      ),
      body: Column(
        children: <Widget>[
          _Stepper(current: _step),
          const Divider(height: 1),
          Expanded(
            child: AnimatedSwitcher(
              duration: AppMotion.base,
              transitionBuilder: (Widget child, Animation<double> a) =>
                  FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.04, 0),
                    end: Offset.zero,
                  ).animate(a),
                  child: child,
                ),
              ),
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return _ErrorPane(
        key: const ValueKey<String>('error'),
        message: _error!,
        onRetry: _needsServer ? _registerSelf : _discover,
      );
    }
    if (_needsServer) {
      return _NoServerPane(
        key: const ValueKey<String>('no-server'),
        registering: _registering,
        onRegister: _registerSelf,
      );
    }
    switch (_step) {
      case _WizardStep.discover:
        return const _DiscoverPane(key: ValueKey<String>('discover'));
      case _WizardStep.configure:
        return _ConfigurePane(
          key: const ValueKey<String>('configure'),
          plan: _plan!,
          answers: _answers,
          onChanged: (String id, String v) =>
              setState(() => _answers[id] = v),
          onSubmit: _provision,
        );
      case _WizardStep.provision:
        return const _ProvisionPane(key: ValueKey<String>('provision'));
      case _WizardStep.done:
        return const _ProvisionPane(key: ValueKey<String>('done'));
    }
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.current});
  final _WizardStep current;

  static const List<(_WizardStep, String, IconData)> _steps =
      <(_WizardStep, String, IconData)>[
    (_WizardStep.discover, 'Discover', Icons.search),
    (_WizardStep.configure, 'Configure', Icons.tune),
    (_WizardStep.provision, 'Provision', Icons.rocket_launch),
    (_WizardStep.done, 'Done', Icons.check_circle),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(Insets.lg),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < _steps.length; i++) ...<Widget>[
            _node(theme, _steps[i], i),
            if (i < _steps.length - 1) Expanded(child: _line(theme, i)),
          ],
        ],
      ),
    );
  }

  bool _isActive(_WizardStep s) => s.index <= current.index;

  Widget _node(ThemeData theme, (_WizardStep, String, IconData) s, int i) {
    final bool active = _isActive(s.$1);
    final bool isCurrent = s.$1 == current;
    final Color color = active ? theme.colorScheme.primary : theme.colorScheme.outline;
    return Column(
      children: <Widget>[
        AnimatedContainer(
          duration: AppMotion.base,
          curve: AppMotion.emphasized,
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.16) : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: isCurrent ? 2.4 : 1.4),
          ),
          child: Icon(s.$3, size: 20, color: color),
        ),
        const SizedBox(height: Insets.xs),
        Text(
          s.$2,
          style: theme.textTheme.labelSmall?.copyWith(
            color: active ? theme.colorScheme.onSurface : color,
            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _line(ThemeData theme, int i) {
    final bool filled = current.index > i;
    return Container(
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: Insets.sm),
      color: theme.colorScheme.outline.withValues(alpha: 0.4),
      child: AnimatedFractionallySizedBox(
        duration: AppMotion.slow,
        curve: AppMotion.emphasized,
        widthFactor: filled ? 1 : 0,
        alignment: Alignment.centerLeft,
        child: Container(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _DiscoverPane extends StatelessWidget {
  const _DiscoverPane({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // A scanning "radar" pulse.
          SizedBox(
            width: 90,
            height: 90,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                )
                    .animate(onPlay: (AnimationController c) => c.repeat())
                    .scaleXY(
                      begin: 0.4,
                      end: 1.0,
                      duration: const Duration(milliseconds: 1400),
                    )
                    .fadeOut(duration: const Duration(milliseconds: 1400)),
                Icon(Icons.radar, size: 36, color: theme.colorScheme.primary),
              ],
            ),
          ),
          const SizedBox(height: Insets.lg),
          Text('Discovering configuration…',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: Insets.xs),
          Text(
            'Fetching the add plan from the control node',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-state shown when the control node has no target server registered.
/// Offers one-tap self-registration (register the connected box itself).
class _NoServerPane extends StatelessWidget {
  const _NoServerPane({
    super.key,
    required this.registering,
    required this.onRegister,
  });

  final bool registering;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.dns_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: Insets.lg),
              Text(
                'No server registered yet',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Insets.sm),
              Text(
                'Before adding a site, register a target server. To host sites '
                'on this machine, register it as its own target.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Insets.xl),
              AppButton(
                label: 'Register this server',
                icon: Icons.add_link,
                loading: registering,
                onPressed: registering ? null : onRegister,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfigurePane extends StatelessWidget {
  const _ConfigurePane({
    super.key,
    required this.plan,
    required this.answers,
    required this.onChanged,
    required this.onSubmit,
  });

  final AddPlan plan;
  final Map<String, String> answers;
  final void Function(String id, String value) onChanged;
  final VoidCallback onSubmit;

  bool get _valid {
    for (final PlanField f in plan.fields) {
      if (!f.isVisible(answers)) continue;
      if (f.required && (answers[f.id]?.trim().isEmpty ?? true)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final List<PlanField> visible =
        plan.fields.where((PlanField f) => f.isVisible(answers)).toList();
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Insets.lg),
            children: <Widget>[
              const SectionHeader(
                title: 'Configure',
                subtitle: 'Fields are generated from the backend plan',
              ),
              const SizedBox(height: Insets.md),
              for (int i = 0; i < visible.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: _FieldEditor(
                    field: visible[i],
                    value: answers[visible[i].id] ?? '',
                    onChanged: (String v) => onChanged(visible[i].id, v),
                  ),
                )
                    .animate(delay: Duration(milliseconds: 40 * i))
                    .fadeIn(duration: AppMotion.base)
                    .slideY(begin: 0.1, curve: AppMotion.emphasized),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              AppButton(
                label: 'Provision',
                icon: Icons.rocket_launch,
                onPressed: _valid ? onSubmit : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Renders the right input control for a [PlanField] based on its type.
class _FieldEditor extends StatelessWidget {
  const _FieldEditor({
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final PlanField field;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    switch (field.type) {
      case PlanFieldType.bool:
        return SwitchListTile(
          value: value == 'true',
          onChanged: (bool v) => onChanged(v ? 'true' : 'false'),
          title: Text(field.label),
          contentPadding: EdgeInsets.zero,
        );
      case PlanFieldType.enumeration:
        return DropdownButtonFormField<String>(
          value: (field.options?.contains(value) ?? false) ? value : null,
          decoration: InputDecoration(labelText: field.label),
          items: <DropdownMenuItem<String>>[
            for (final String o in field.options ?? const <String>[])
              DropdownMenuItem<String>(value: o, child: Text(o)),
          ],
          onChanged: (String? v) => onChanged(v ?? ''),
        );
      case PlanFieldType.secret:
        return TextFormField(
          initialValue: value,
          obscureText: true,
          decoration: InputDecoration(
            labelText: field.label,
            prefixIcon: const Icon(Icons.key_outlined),
          ),
          onChanged: onChanged,
        );
      case PlanFieldType.domain:
      case PlanFieldType.abspath:
      case PlanFieldType.string:
        return TextFormField(
          initialValue: value,
          decoration: InputDecoration(
            labelText: field.label + (field.required ? ' *' : ''),
            prefixIcon: Icon(_iconFor(field.type)),
            hintText: _hintFor(field.type),
          ),
          onChanged: onChanged,
        );
    }
  }

  IconData _iconFor(PlanFieldType t) {
    switch (t) {
      case PlanFieldType.domain:
        return Icons.public;
      case PlanFieldType.abspath:
        return Icons.folder_outlined;
      default:
        return Icons.edit_outlined;
    }
  }

  String? _hintFor(PlanFieldType t) {
    switch (t) {
      case PlanFieldType.domain:
        return 'example.com';
      case PlanFieldType.abspath:
        return '/var/www';
      default:
        return null;
    }
  }
}

class _ProvisionPane extends ConsumerWidget {
  const _ProvisionPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DeployState state = ref.watch(addProvisionProvider);
    return Column(
      children: <Widget>[
        Expanded(child: DeployTimeline(state: state)),
        if (state.done)
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                AppButton(
                  label: 'Back to dashboard',
                  icon: Icons.dashboard_outlined,
                  onPressed: () => context.go('/dashboard'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({
    super.key,
    required this.message,
    required this.onRetry,
  });
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 48, color: Palette.err),
          const SizedBox(height: Insets.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.mono(context, size: 12),
            ),
          ),
          const SizedBox(height: Insets.md),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
