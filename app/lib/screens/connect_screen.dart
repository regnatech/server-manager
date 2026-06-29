import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/connection_profile.dart';
import '../state/connection_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/app_button.dart';
import '../widgets/section_header.dart';

/// Guided onboarding: collect SSH details, test the connection (animated
/// success check), or jump straight into demo mode.
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

  AuthMethod _auth = AuthMethod.key;
  String? _keyPath;
  String? _keyPem;
  bool _remember = false;
  bool _connecting = false;
  bool _succeeded = false;
  String? _error;

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
                        const SectionHeader(
                          title: 'Connect',
                          subtitle: 'SSH into your server-manager control node',
                        ),
                        const SizedBox(height: Insets.md),
                        TextField(
                          controller: _host,
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            hintText: 'control.example.com',
                            prefixIcon: Icon(Icons.dns_outlined),
                          ),
                        ),
                        const SizedBox(height: Insets.md),
                        Row(
                          children: <Widget>[
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _user,
                                decoration: const InputDecoration(
                                  labelText: 'User',
                                  prefixIcon: Icon(Icons.person_outline),
                                ),
                              ),
                            ),
                            const SizedBox(width: Insets.md),
                            Expanded(
                              child: TextField(
                                controller: _port,
                                keyboardType: TextInputType.number,
                                inputFormatters: <TextInputFormatter>[
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                decoration: const InputDecoration(
                                  labelText: 'Port',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Insets.lg),
                        _AuthToggle(
                          value: _auth,
                          onChanged: (AuthMethod m) =>
                              setState(() => _auth = m),
                        ),
                        const SizedBox(height: Insets.md),
                        AnimatedSwitcher(
                          duration: AppMotion.base,
                          child: _auth == AuthMethod.key
                              ? _keyFields()
                              : _passwordField(),
                        ),
                        const SizedBox(height: Insets.md),
                        CheckboxListTile(
                          value: _remember,
                          onChanged: (bool? v) =>
                              setState(() => _remember = v ?? false),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('Remember this connection'),
                          subtitle: const Text(
                            'Stores the profile and secret in the OS vault',
                          ),
                        ),
                        if (_error != null) ...<Widget>[
                          const SizedBox(height: Insets.sm),
                          _ErrorBox(message: _error!),
                        ],
                        const SizedBox(height: Insets.lg),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: _connectButton(),
                            ),
                          ],
                        ),
                        const SizedBox(height: Insets.md),
                        const _OrDivider(),
                        const SizedBox(height: Insets.md),
                        OutlinedButton.icon(
                          onPressed: _exploreDemo,
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text('Explore demo (no server needed)'),
                        ),
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

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final Color c = Theme.of(context).colorScheme.outline;
    return Row(
      children: <Widget>[
        Expanded(child: Divider(color: c)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.md),
          child: Text(
            'or',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(child: Divider(color: c)),
      ],
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
