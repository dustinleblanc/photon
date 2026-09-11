import 'package:flutter/cupertino.dart';

import '../state/app_state.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});

  final AppState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  final _totpFocus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _totp.dispose();
    _totpFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final requireTotp = widget.state.totpRequired;
    await widget.state.login(
      username: _username.text.trim(),
      password: _password.text,
      totp: requireTotp ? _totp.text.trim() : null,
    );
    if (mounted) {
      setState(() => _busy = false);
      if (widget.state.totpRequired && !requireTotp) {
        _totpFocus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    return CupertinoPageScaffold(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  CupertinoIcons.photo,
                  size: 56,
                  color: theme.primaryColor,
                ),
                const SizedBox(height: 12),
                Text(
                  'Photon Library',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.textStyle.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 24),
                if (widget.state.error != null) ...[
                  _ErrorBanner(message: widget.state.error!),
                  const SizedBox(height: 12),
                ],
                if (widget.state.totpRequired) ...[
                  Text(
                    'Almost there',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.textStyle.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _username.text.trim(),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.textStyle.copyWith(
                      fontSize: 13,
                      color: theme.textTheme.textStyle.color?.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else
                  AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CupertinoTextField(
                          controller: _username,
                          placeholder: 'Proton username',
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                          enabled: !_busy,
                        ),
                        const SizedBox(height: 10),
                        CupertinoTextField(
                          controller: _password,
                          placeholder: 'Password',
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          textInputAction: TextInputAction.go,
                          onSubmitted: (_) => _submit(),
                          enabled: !_busy,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                if (widget.state.totpRequired)
                  CupertinoTextField(
                    controller: _totp,
                    focusNode: _totpFocus,
                    placeholder: '6-digit code from your authenticator app',
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    onSubmitted: (_) => _submit(),
                    enabled: !_busy,
                  ),
                const SizedBox(height: 20),
                CupertinoButton.filled(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const CupertinoActivityIndicator()
                      : Text(widget.state.totpRequired ? 'Verify' : 'Sign in'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Uses an encrypted Proton session. '
                  'Credentials are never stored locally.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.textStyle.copyWith(
                    fontSize: 12,
                    color: theme.textTheme.textStyle.color?.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE4E2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: theme.textTheme.textStyle.copyWith(
          fontSize: 13,
          color: const Color(0xFFB42318),
        ),
      ),
    );
  }
}