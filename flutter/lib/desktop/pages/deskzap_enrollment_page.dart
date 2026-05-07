import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// DeskzapEnrollmentPage
//
// Shown in Host (incoming-only) mode when the device is not yet enrolled.
// Replaces the old OAuth device-code / browser-redirect flow with a simple
// email + password form — identical in feel to the Deskzap Connect sign-in.
//
// Flow:
//   1. User enters their Deskzap account email + password and taps "Sign in".
//   2. We call the same gFFI.userModel.login() path used by the Connect client.
//   3. On success the Rust backend (common.rs) sees the access token, completes
//      device enrollment via POST /api/v1/devices/enroll, and updates the
//      device-auth state to "enrolled".
//   4. We detect "enrolled" via our existing _poll() loop and switch to the
//      success screen.
//
// The original browser / QR-code flow is preserved in
// deskzap_enrollment_page.dart.bak if you ever need to roll back.
// ---------------------------------------------------------------------------

class DeskzapEnrollmentPage extends StatefulWidget {
  const DeskzapEnrollmentPage({Key? key}) : super(key: key);

  @override
  State<DeskzapEnrollmentPage> createState() => _DeskzapEnrollmentPageState();
}

class _DeskzapEnrollmentPageState extends State<DeskzapEnrollmentPage> {
  // ── form state ────────────────────────────────────────────────────────────
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocus = FocusNode();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  // ── enrollment poll state ─────────────────────────────────────────────────
  Timer? _pollTimer;
  String _enrollmentStatus = ''; // '', 'pending_login', 'enrolled', 'error'

  // ── brand colours (same palette as the existing enrollment page) ──────────
  static const _blue = Color(0xFF2963F2);
  static const _dark = Color(0xFF16213D);
  static const _muted = Color(0xFF5C6C8F);
  static const _bg = Color(0xFFF4F8FF);
  static const _cardBg = Colors.white;
  static const _inputBorder = Color(0xFFD7E3FF);
  static const _inputFill = Color(0xFFF7FAFF);

  @override
  void initState() {
    super.initState();
    // Poll for enrollment state so we catch success set from the Rust side.
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollEnrollment());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  // ── enrollment polling ────────────────────────────────────────────────────

  void _pollEnrollment() {
    final raw = bind.mainGetDeskzapDeviceAuthState();
    if (raw.isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final status = map['status'] as String? ?? '';
      if (status == 'enrolled' && _enrollmentStatus != 'enrolled') {
        if (mounted) setState(() => _enrollmentStatus = 'enrolled');
        _pollTimer?.cancel();
        // Clear state after a short delay so Host opens normally on next launch.
        Future.delayed(const Duration(seconds: 5), () {
          bind.mainClearDeskzapDeviceAuthState();
        });
      }
    } catch (_) {}
  }

  // ── sign-in logic ─────────────────────────────────────────────────────────

  Future<void> _handleSignIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty) {
      setState(() => _errorMessage = 'Please enter your email address.');
      _emailFocus.requestFocus();
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorMessage = 'Please enter your password.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Add a 15-second timeout to the FFI login call
      final resp = await gFFI.userModel.login(LoginRequest(
        username: email,
        password: password,
        id: await bind.mainGetMyId(),
        uuid: await bind.mainGetUuid(),
        autoLogin: true,
        type: HttpType.kAuthReqTypeAccount,
      )).timeout(const Duration(seconds: 15), onTimeout: () {
        throw TimeoutException('Login timed out');
      });

      if (!mounted) return;

      switch (resp.type) {
        case HttpType.kAuthResTypeToken:
          if (resp.access_token != null) {
            // Store token so Rust backend can use it for device enrollment.
            await bind.mainSetLocalOption(
                key: 'access_token', value: resp.access_token!);
            await bind.mainSetLocalOption(
                key: 'user_info', value: jsonEncode(resp.user ?? {}));
            
            // Perform the device enrollment API call directly from Flutter
            try {
              final apiServer = await bind.mainGetApiServer();
              final hostName = Platform.localHostname;
              final osName = Platform.operatingSystem == 'windows' ? 'Windows' : 
                             Platform.operatingSystem == 'macos' ? 'macOS' : 
                             Platform.operatingSystem == 'linux' ? 'Linux' : Platform.operatingSystem;
              
              // Ensure we have a device signing key generated before enrolling.
              var pubKey = await bind.mainGetDevicePublicKeyBase64();
              if (pubKey.isEmpty) {
                pubKey = await bind.mainGenerateDeviceKey();
              }

              final payload = jsonEncode({
                "rustdesk_runtime_id": await bind.mainGetMyId(),
                "hostname": hostName,
                "display_name": hostName,
                "operating_system": osName,
                "agent_version": await bind.mainGetVersion(),
                "device_public_key": pubKey,
              });

              final client = HttpClient();
              // Remove trailing slash if any
              final baseUrl = apiServer.endsWith('/') ? apiServer.substring(0, apiServer.length - 1) : apiServer;
              final req = await client.postUrl(Uri.parse('$baseUrl/api/v1/devices/enroll'));
              req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${resp.access_token!}');
              req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
              req.write(payload);
              final response = await req.close();
              final responseBody = await response.transform(utf8.decoder).join();
              client.close();

              if (response.statusCode >= 200 && response.statusCode < 300) {
                final data = jsonDecode(responseBody) as Map<String, dynamic>;
                final deviceId = data['device']?['id'] as String?;
                final heartbeatToken = data['runtime_heartbeat_token'] as String?;

                if (deviceId != null && heartbeatToken != null) {
                  // Write to Config (not just LocalConfig) so the Rust heartbeat loop
                  // and SYSTEM service process can both read the token.
                  bind.mainDeskzapPersistEnrollmentResult(deviceId: deviceId, heartbeatToken: heartbeatToken);
                  // Also keep LocalConfig copies for Flutter-side reads.
                  await bind.mainSetLocalOption(key: 'deskzap-device-id', value: deviceId);
                  await bind.mainSetLocalOption(key: 'deskzap-runtime-heartbeat-token', value: heartbeatToken);
                }

                // Bypass Rust OAuth polling by triggering "enrolled" instantly.
                setState(() => _enrollmentStatus = 'enrolled');
                _pollTimer?.cancel();
                
                // After 3 seconds, clear the OAuth state JSON in Rust to unmount this screen.
                Future.delayed(const Duration(seconds: 3), () {
                  bind.mainClearDeskzapDeviceAuthState();
                });
              } else {
                debugPrint('Enrollment API error: status ${response.statusCode} - $responseBody');
                setState(() => _errorMessage = 'Enrollment failed: $responseBody');
              }
            } catch (err) {
              debugPrint('Enrollment API exception: $err');
              setState(() => _errorMessage = 'Could not complete enrollment: $err');
            }
          } else {
            setState(() => _errorMessage = 'Sign in failed. Please try again.');
          }
          break;

        case HttpType.kAuthResTypeEmailCheck:
          setState(() =>
              _errorMessage = 'Email verification required. Please check your inbox.');
          break;

        default:
          setState(() => _errorMessage = 'Sign in failed. Please try again.');
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _errorMessage = 'Connection timed out. Please try again.');
      }
    } on RequestException catch (err) {
      if (mounted) {
        setState(() => _errorMessage = _formatError(err.cause));
      }
    } catch (err) {
      if (mounted) {
        setState(() => _errorMessage = 'Could not sign in. Please check your connection.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatError(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'Could not sign in. Please try again.';
    final lower = t.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      return 'The server returned an unexpected response. Please try again.';
    }
    if (lower.contains('invalid') && lower.contains('password')) {
      return 'Incorrect email or password.';
    }
    if (lower.contains('user') && lower.contains('not found')) {
      return 'No account found with that email.';
    }
    return t.length > 160 ? '${t.substring(0, 157)}…' : t;
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Force a light theme so our hardcoded light-mode colors (like the white
    // input backgrounds) don't get overridden by a system dark mode theme,
    // which causes the password box to turn black when focused.
    return Theme(
      data: ThemeData.light().copyWith(
        colorScheme: const ColorScheme.light(
          primary: _blue,
          background: _bg,
        ),
      ),
      child: Container(
        color: _bg,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: _buildContent(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_enrollmentStatus == 'enrolled') return _buildSuccess();
    if (_enrollmentStatus == 'pending_login') return _buildEnrolling();
    return _buildSignInCard();
  }

  // ── sign-in card ──────────────────────────────────────────────────────────

  Widget _buildSignInCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _inputBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A0F172A),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Logo / brand mark
          _buildLogo(),
          const SizedBox(height: 28),

          // Heading
          const Text(
            'Sign in to Deskzap (v3)',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.black, // Forced black to guarantee contrast
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This computer will be added to your workspace automatically after sign-in.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: _muted,
            ),
          ),
          const SizedBox(height: 32),

          // Error banner
          if (_errorMessage != null) ...[
            _buildErrorBanner(_errorMessage!),
            const SizedBox(height: 16),
          ],

          // Email field
          _buildLabel('Email'),
          const SizedBox(height: 6),
          _buildEmailField(),
          const SizedBox(height: 16),

          // Password field
          _buildLabel('Password'),
          const SizedBox(height: 6),
          _buildPasswordField(),
          const SizedBox(height: 28),

          // Sign-in button
          _buildSignInButton(),

          const SizedBox(height: 12),
          // Forgot password
          Center(
            child: TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://my.deskzap.co.uk/forgot-password'),
                mode: LaunchMode.externalApplication,
              ),
              style: TextButton.styleFrom(
                foregroundColor: _blue,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Forgot password?',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ),

          const SizedBox(height: 20),
          const Divider(color: Color(0xFFE8EEFF)),
          const SizedBox(height: 16),

          // Create account
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                "Don't have an account? ",
                style: TextStyle(fontSize: 13, color: _muted),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://my.deskzap.co.uk/register'),
                  mode: LaunchMode.externalApplication,
                ),
                style: TextButton.styleFrom(
                  foregroundColor: _blue,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Create a free account',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Center(
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _blue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.monitor_outlined, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.black, // Forced black
      ),
    );
  }

  Widget _buildEmailField() {
    return TextField(
      controller: _emailController,
      focusNode: _emailFocus,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
      onChanged: (_) {
        if (_errorMessage != null) setState(() => _errorMessage = null);
      },
      style: const TextStyle(fontSize: 15, color: Colors.black), // Forced black
      decoration: _inputDecoration(
        hint: 'you@example.com',
        icon: Icons.email_outlined,
      ),
    );
  }

  Widget _buildPasswordField() {
    return TextField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      autofillHints: const [AutofillHints.password],
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _isLoading ? null : _handleSignIn(),
      onChanged: (_) {
        if (_errorMessage != null) setState(() => _errorMessage = null);
      },
      style: const TextStyle(fontSize: 15, color: Colors.black), // Forced black
      decoration: _inputDecoration(
        hint: 'Your password',
        icon: Icons.lock_outline,
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 20,
            color: _muted,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
          splashRadius: 18,
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF5C6C8F), fontSize: 14),
      prefixIcon: Icon(icon, size: 18, color: _muted),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: Colors.white, // Forced white background
      hoverColor: Colors.white,
      focusColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _inputBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _blue, width: 1.5),
      ),
    );
  }

  Widget _buildSignInButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleSignIn,
        style: ElevatedButton.styleFrom(
          backgroundColor: _blue,
          foregroundColor: Colors.white,
          disabledBackgroundColor: _blue.withOpacity(0.55),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
              )
            : const Text('Sign in and add this computer'),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFCDD2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF991B1B),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── enrolling / pending state ─────────────────────────────────────────────

  Widget _buildEnrolling() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 48),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _inputBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A0F172A),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: _blue,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Adding this computer…',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _dark,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Finishing setup. This will only take a moment.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── success state ─────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 48),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _inputBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A0F172A),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E),
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Icon(Icons.check, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 20),
          const Text(
            "You're connected.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: _dark,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'This computer is now linked to your workspace.\nIt will appear in your dashboard in a few moments.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _muted, height: 1.55),
          ),
        ],
      ),
    );
  }
}
