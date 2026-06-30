import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/connection_profile.dart';
import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../transport/platform.dart';
import '../widgets/app_button.dart';
import '../widgets/section_header.dart';

/// Guided onboarding as a 3-step wizard (Server → Identity → Confirm), so the
/// flow stays roomy and one-thing-at-a-time on a phone. Ends by testing the
/// connection (animated success check) or jumping straight into demo mode.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _user = TextEditingController(text: 'deploy');
  final TextEditingController _port = TextEditingController(text: '22');
  final TextEditingController _password = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();

  static const List<String> _stepTitles = <String>['Server', 'Identity', 'Confirm'];

  int _step = 0;
  bool _forward = true;

  AuthMethod _auth = AuthMethod.key;
  String? _keyPath;
  String? _keyPem;
  bool _remember = false;
  bool _connecting = false;
  bool _succeeded = false;
  String? _error;

  /// Connections previously saved via "Remember this connection".
  List<ConnectionProfile> _saved = const <ConnectionProfile>[];

  @override
  void initState() {
    super.initState();
    // Screenshot hook only: SM_CONNECT_STEP pre-fills demo input and jumps to a
    // wizard step so each step can be captured. No effect in normal use.
    final String? step = envVar('SM_CONNECT_STEP');
    if (step != null && step.isNotEmpty) {
      _host.text = 'control.example.com';
      _user.text = 'deploy';
      _auth = AuthMethod.password;
      _password.text = 'correct-horse-battery';
      _step = (int.tryParse(step) ?? 0).clamp(0, _stepTitles.length - 1);
      return;
    }
    _loadSaved();
  }

  /// Loads remembered profiles from the OS vault so they can be offered for
  /// one-tap reconnection.
  Future<void> _loadSaved() async {
    final List<ConnectionProfile> profiles =
        await ref.read(connectionStoreProvider).loadProfiles();
    if (!mounted) return;
    setState(() => _saved = profiles);
  }

  /// Pre-fills the form from a saved [profile], pulling its secret back out of
  /// the vault, and jumps straight to the Confirm step.
  Future<void> _useSaved(ConnectionProfile profile) async {
    final String? secret =
        await ref.read(connectionStoreProvider).readSecret(profile);
    if (!mounted) return;
    setState(() {
      _host.text = profile.host;
      _port.text = profile.port.toString();
      _user.text = profile.username;
      _auth = profile.authMethod;
      _keyPath = profile.keyPath;
      _keyPem = null; // re-read from disk at connect time
      if (profile.authMethod == AuthMethod.password) {
        _password.text = secret ?? '';
      } else {
        _passphrase.text = secret ?? '';
      }
      _remember = true;
      _error = null;
      _forward = true;
      _step = _stepTitles.length - 1;
    });
  }

  /// Forgets a saved [profile] and its secret.
  Future<void> _forget(ConnectionProfile profile) async {
    await ref.read(connectionStoreProvider).deleteProfile(profile.id);
    await _loadSaved();
  }

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _port.dispose();
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _pickKey() async {
    const XTypeGroup group = XTypeGroup(
      label: 'Private keys',
      extensions: <String>['pem', 'key'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[group]);
    if (file == null) return;
    final String contents = await file.readAsString();
    setState(() {
      _keyPath = file.path;
      _keyPem = contents;
    });
  }

  /// Whether the current step has the minimum input needed to advance.
  bool get _canAdvance {
    switch (_step) {
      case 0:
        return _host.text.trim().isNotEmpty;
      case 1:
        final bool hasUser = _user.text.trim().isNotEmpty;
        final bool hasCred = _auth == AuthMethod.key
            ? _keyPem != null
            : _password.text.isNotEmpty;
        return hasUser && hasCred;
      default:
        return true;
    }
  }

  void _next() {
    if (!_canAdvance) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _forward = true;
      _step = (_step + 1).clamp(0, _stepTitles.length - 1);
    });
  }

  void _back() {
    FocusScope.of(context).unfocus();
    setState(() {
      _forward = false;
      _error = null;
      _step = (_step - 1).clamp(0, _stepTitles.length - 1);
    });
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _succeeded = false;
      _error = null;
    });

    final ConnectionProfile profile = ConnectionProfile(
      id: '${_host.text}:${_port.text}:${_user.text}',
      label: _host.text,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _user.text.trim(),
      authMethod: _auth,
      keyPath: _keyPath,
    );

    // For a remembered key profile only the path is stored, so re-read the PEM
    // from disk if we don't already have its contents in memory.
    if (_auth == AuthMethod.key && _keyPem == null && _keyPath != null) {
      try {
        _keyPem = await File(_keyPath!).readAsString();
      } on Object catch (e) {
        setState(() {
          _connecting = false;
          _error = 'Could not read key file at $_keyPath — $e';
        });
        return;
      }
    }

    final ConnectionCredentials creds = ConnectionCredentials(
      profile: profile,
      password: _auth == AuthMethod.password ? _password.text : null,
      privateKeyPem: _auth == AuthMethod.key ? _keyPem : null,
      passphrase: _auth == AuthMethod.key ? _passphrase.text : null,
    );

    final bool ok = await ref
        .read(connectionProvider.notifier)
        .connect(creds, remember: _remember);

    if (!mounted) return;

    if (ok) {
      setState(() {
        _connecting = false;
        _succeeded = true;
      });
      // Brief pause so the success check is visible before navigating.
      Timer(const Duration(milliseconds: 700), () {
        if (mounted) context.go('/dashboard');
      });
    } else {
      setState(() {
        _connecting = false;
        _error = ref.read(connectionProvider).errorMessage;
      });
    }
  }

  void _exploreDemo() {
    ref.read(connectionProvider.notifier).enterDemo();
    context.go('/dashboard');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Brand(theme: theme)
                    .animate()
                    .fadeIn(duration: AppMotion.slow)
                    .slideY(begin: -0.1, curve: AppMotion.emphasized),
                const SizedBox(height: Insets.xl),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _StepIndicator(current: _step, titles: _stepTitles),
                        const SizedBox(height: Insets.lg),
                        // Smoothly grow/shrink the card as steps differ in
                        // height, and slide step content in/out horizontally.
                        AnimatedSize(
                          duration: AppMotion.base,
                          curve: AppMotion.emphasized,
                          alignment: Alignment.topCenter,
                          child: AnimatedSwitcher(
                            duration: AppMotion.base,
                            switchInCurve: AppMotion.emphasized,
                            transitionBuilder:
                                (Widget child, Animation<double> anim) {
                              final Animation<Offset> slide = Tween<Offset>(
                                begin: Offset(_forward ? 0.12 : -0.12, 0),
                                end: Offset.zero,
                              ).animate(anim);
                              return FadeTransition(
                                opacity: anim,
                                child: SlideTransition(
                                  position: slide,
                                  child: child,
                                ),
                              );
                            },
                            child: KeyedSubtree(
                              key: ValueKey<int>(_step),
                              child: _stepContent(theme),
                            ),
                          ),
                        ),
                        const SizedBox(height: Insets.lg),
                        _navRow(),
                      ],
                    ),
                  ),
                ).animate(delay: AppMotion.fast).fadeIn(duration: AppMotion.slow),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepContent(ThemeData theme) {
    switch (_step) {
      case 0:
        return _stepServer();
      case 1:
        return _stepIdentity();
      default:
        return _stepConfirm(theme);
    }
  }

  // ---- Step 0: Server ------------------------------------------------------

  Widget _stepServer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_saved.isNotEmpty) ...<Widget>[
          const SectionHeader(
            title: 'Saved connections',
            subtitle: 'Reconnect with one tap',
          ),
          const SizedBox(height: Insets.sm),
          for (final ConnectionProfile p in _saved)
            _SavedConnectionTile(
              profile: p,
              onUse: () => _useSaved(p),
              onForget: () => _forget(p),
            ),
          const SizedBox(height: Insets.lg),
        ],
        const SectionHeader(
          title: 'Server',
          subtitle: 'Where your server-manager control node lives',
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: _host,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Host',
            hintText: 'control.example.com',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: _port,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(
            labelText: 'Port',
            hintText: '22',
            prefixIcon: Icon(Icons.settings_ethernet),
          ),
        ),
      ],
    );
  }

  // ---- Step 1: Identity ----------------------------------------------------

  Widget _stepIdentity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader(
          title: 'Identity',
          subtitle: 'How to authenticate over SSH',
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: _user,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'User',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: Insets.lg),
        _AuthToggle(
          value: _auth,
          onChanged: (AuthMethod m) => setState(() => _auth = m),
        ),
        const SizedBox(height: Insets.md),
        AnimatedSwitcher(
          duration: AppMotion.base,
          child: _auth == AuthMethod.key ? _keyFields() : _passwordField(),
        ),
      ],
    );
  }

  // ---- Step 2: Confirm -----------------------------------------------------

  Widget _stepConfirm(ThemeData theme) {
    final String portText = _port.text.trim().isEmpty ? '22' : _port.text.trim();
    final String auth =
        _auth == AuthMethod.key ? 'Private key' : 'Password';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader(
          title: 'Confirm',
          subtitle: 'Review and test the connection',
        ),
        const SizedBox(height: Insets.md),
        _SummaryTile(
          icon: Icons.dns_outlined,
          label: 'Host',
          value: '${_host.text.trim()}:$portText',
        ),
        _SummaryTile(
          icon: Icons.person_outline,
          label: 'User',
          value: _user.text.trim(),
        ),
        _SummaryTile(
          icon: _auth == AuthMethod.key
              ? Icons.vpn_key_outlined
              : Icons.lock_outline,
          label: 'Auth',
          value: _auth == AuthMethod.key
              ? (_keyPath?.split('/').last ?? auth)
              : auth,
        ),
        const SizedBox(height: Insets.sm),
        CheckboxListTile(
          value: _remember,
          onChanged: (bool? v) => setState(() => _remember = v ?? false),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Remember this connection'),
          subtitle: const Text('Stores the profile and secret in the OS vault'),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: Insets.sm),
          _ErrorBox(message: _error!),
        ],
      ],
    );
  }

  // ---- Navigation ----------------------------------------------------------

  Widget _navRow() {
    // Last step: Back + the connect/success control.
    if (_step == _stepTitles.length - 1) {
      return Row(
        children: <Widget>[
          _backButton(),
          const SizedBox(width: Insets.md),
          Expanded(child: _connectButton()),
        ],
      );
    }
    // Step 0 offers the demo escape hatch; later steps offer Back.
    return Row(
      children: <Widget>[
        if (_step == 0)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _exploreDemo,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Demo'),
            ),
          )
        else
          _backButton(),
        const SizedBox(width: Insets.md),
        Expanded(
          child: AppButton(
            label: 'Next',
            icon: Icons.arrow_forward,
            onPressed: _canAdvance ? _next : null,
          ),
        ),
      ],
    );
  }

  Widget _backButton() {
    return OutlinedButton.icon(
      onPressed: _connecting ? null : _back,
      icon: const Icon(Icons.arrow_back),
      label: const Text('Back'),
    );
  }

  Widget _connectButton() {
    if (_succeeded) {
      return Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Palette.ok.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(Insets.radiusMd),
          border: Border.all(color: Palette.ok),
        ),
        child: const Icon(Icons.check_circle, color: Palette.ok)
            .animate()
            .scale(
              duration: AppMotion.base,
              curve: Curves.elasticOut,
              begin: const Offset(0.2, 0.2),
              end: const Offset(1, 1),
            ),
      );
    }
    return AppButton(
      label: 'Test connection',
      icon: Icons.bolt_outlined,
      loading: _connecting,
      onPressed: _host.text.isEmpty ? null : _connect,
    );
  }

  Widget _passwordField() {
    return TextField(
      key: const ValueKey<String>('pw'),
      controller: _password,
      obscureText: true,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        labelText: 'Password',
        prefixIcon: Icon(Icons.lock_outline),
      ),
    );
  }

  Widget _keyFields() {
    return Column(
      key: const ValueKey<String>('key'),
      children: <Widget>[
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Private key',
            prefixIcon: Icon(Icons.vpn_key_outlined),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _keyPath ?? 'No key selected',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _keyPath == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ),
              TextButton(onPressed: _pickKey, child: const Text('Choose…')),
            ],
          ),
        ),
        const SizedBox(height: Insets.md),
        TextField(
          controller: _passphrase,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Key passphrase (optional)',
            prefixIcon: Icon(Icons.password_outlined),
          ),
        ),
      ],
    );
  }
}

/// A compact step progress header: a row of segment bars (filled up to the
/// current step) with the active step's name and "Step n of m".
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current, required this.titles});
  final int current;
  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (int i = 0; i < titles.length; i++) ...<Widget>[
              Expanded(
                child: AnimatedContainer(
                  duration: AppMotion.base,
                  height: 6,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: i <= current ? Palette.brandGradient : null,
                    color: i <= current
                        ? null
                        : theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              if (i != titles.length - 1) const SizedBox(width: Insets.xs),
            ],
          ],
        ),
        const SizedBox(height: Insets.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              titles[current],
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'Step ${current + 1} of ${titles.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A read-only row used on the confirm step: icon · label · value.
class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: Insets.sm),
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: <Color>[Palette.violet, Palette.teal],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Palette.violet.withValues(alpha: 0.45),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(Icons.lan_outlined, color: Colors.white, size: 36),
        ),
        const SizedBox(height: Insets.md),
        Text('Server Manager', style: theme.textTheme.headlineSmall),
        Text(
          'Deploy & manage sites over SSH',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A tappable card for a remembered connection: tap to load it into the form,
/// or use the trailing button to forget it.
class _SavedConnectionTile extends StatelessWidget {
  const _SavedConnectionTile({
    required this.profile,
    required this.onUse,
    required this.onForget,
  });

  final ConnectionProfile profile;
  final VoidCallback onUse;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: ListTile(
        onTap: onUse,
        leading: Icon(
          profile.authMethod == AuthMethod.key
              ? Icons.vpn_key_outlined
              : Icons.lock_outline,
          color: theme.colorScheme.primary,
        ),
        title: Text('${profile.host}:${profile.port}'),
        subtitle: Text(
          profile.username,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: IconButton(
          tooltip: 'Forget',
          icon: const Icon(Icons.delete_outline),
          onPressed: onForget,
        ),
      ),
    );
  }
}

class _AuthToggle extends StatelessWidget {
  const _AuthToggle({required this.value, required this.onChanged});
  final AuthMethod value;
  final ValueChanged<AuthMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<AuthMethod>(
      segments: const <ButtonSegment<AuthMethod>>[
        ButtonSegment<AuthMethod>(
          value: AuthMethod.key,
          icon: Icon(Icons.vpn_key_outlined),
          label: Text('Key file'),
        ),
        ButtonSegment<AuthMethod>(
          value: AuthMethod.password,
          icon: Icon(Icons.password_outlined),
          label: Text('Password'),
        ),
      ],
      selected: <AuthMethod>{value},
      onSelectionChanged: (Set<AuthMethod> s) => onChanged(s.first),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: Palette.err.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        border: Border.all(color: Palette.err.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, color: Palette.err, size: 20),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              message,
              style: AppTheme.mono(context, size: 12, color: Palette.err),
            ),
          ),
        ],
      ),
    ).animate().shakeX(amount: 3, duration: AppMotion.slow);
  }
}
