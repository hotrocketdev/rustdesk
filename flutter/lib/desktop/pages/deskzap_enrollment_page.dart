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
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_hbb/desktop/widgets/dz_icon.dart';
import 'package:flutter_svg/flutter_svg.dart';

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

  @override
  void initState() {
    super.initState();

    // Fast-path: if the device is already enrolled (heartbeat token present),
    // skip login form and show enrolled state immediately.
    final existingToken = bind.mainGetLocalOption(
      key: 'deskzap-runtime-heartbeat-token',
    );
    if (existingToken.isNotEmpty) {
      _enrollmentStatus = 'enrolled';
      // Clear the Rust auth state so the parent widget unmounts this page
      // and shows the main host screen. Without this, the success screen
      // stays visible forever because the poll timer is never started.
      Future.delayed(const Duration(seconds: 2), () {
        bind.mainClearDeskzapDeviceAuthState();
      });
      return;
    }

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
      } else if ((status == 'expired' || status.startsWith('error:')) &&
                 _enrollmentStatus != 'enrolled') {
        // OAuth device code expired/errored — check if the user already enrolled via
        // the email/password path (token written to LocalConfig during sign-in).
        final token = bind.mainGetLocalOption(key: 'deskzap-runtime-heartbeat-token');
        if (token.isNotEmpty && mounted) {
          setState(() => _enrollmentStatus = 'enrolled');
          _pollTimer?.cancel();
          Future.delayed(const Duration(seconds: 2), () {
            bind.mainClearDeskzapDeviceAuthState();
          });
        }
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
                  // Apply RustDesk password so managed connect auto-authenticates without CM popup.
                  final rustdeskPassword = data['rustdesk_password'] as String?;
                  if (rustdeskPassword != null && rustdeskPassword.isNotEmpty) {
                    await bind.mainSetPermanentPassword(password: rustdeskPassword);
                    await bind.mainSetOption(key: 'approve-mode', value: 'password');
                    await bind.mainSetOption(key: 'allow-hide-cm', value: 'Y');
                    await bind.mainSetOption(key: 'verification-method', value: 'use-permanent-password');
                  }
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: dark ? const Color(0xFF0A0A0A) : Colors.white,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: _buildContent(),
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

  DzColors get _c => DzColors.of(context);

  TextStyle _mono(Color color) => TextStyle(
        fontFamily: MyTheme.fontMono,
        fontSize: 10.5,
        letterSpacing: 0.9,
        fontWeight: FontWeight.w500,
        color: color,
      );

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 34),
      decoration: BoxDecoration(
        color: _c.card,
        border: Border.all(color: _c.line),
      ),
      child: child,
    );
  }

  // The Host app icon: white hexagon on the Host pink.
  Widget _hostTile() {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      color: const Color(0xFFFF2E88),
      child: SvgPicture.asset('assets/deskzap/deskzap-mark.svg',
          width: 22,
          height: 26,
          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn)),
    );
  }

  // ── sign-in card ──────────────────────────────────────────────────────────

  Widget _buildSignInCard() {
    final c = _c;
    return _card(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _hostTile(),
              const SizedBox(width: 12),
              Text('DESKZAP HOST', style: _mono(c.dim)),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            'Sign in to add this computer',
            style: TextStyle(
              fontFamily: MyTheme.fontDisplay,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: c.fg,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This computer joins your workspace automatically after you sign in.',
            style: TextStyle(fontSize: 14, height: 1.5, color: c.mute),
          ),
          const SizedBox(height: 28),
          if (_errorMessage != null) ...[
            _buildErrorBanner(_errorMessage!),
            const SizedBox(height: 16),
          ],
          Text('EMAIL', style: _mono(c.dim)),
          const SizedBox(height: 6),
          _buildEmailField(),
          const SizedBox(height: 16),
          Text('PASSWORD', style: _mono(c.dim)),
          const SizedBox(height: 6),
          _buildPasswordField(),
          const SizedBox(height: 26),
          _buildSignInButton(),
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://my.deskzap.co.uk/forgot-password'),
                mode: LaunchMode.externalApplication,
              ),
              style: TextButton.styleFrom(
                foregroundColor: MyTheme.accentInk,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Forgot password?', style: TextStyle(fontSize: 13)),
            ),
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: c.line),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text("Don't have an account? ",
                  style: TextStyle(fontSize: 13, color: c.mute)),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://my.deskzap.co.uk/register'),
                  mode: LaunchMode.externalApplication,
                ),
                style: TextButton.styleFrom(
                  foregroundColor: MyTheme.accentInk,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Create a free account',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
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
      style: TextStyle(fontSize: 15, color: _c.fg),
      decoration: _inputDecoration(hint: 'you@example.com', icon: 'user'),
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
      style: TextStyle(fontSize: 15, color: _c.fg),
      decoration: _inputDecoration(
        hint: 'Your password',
        icon: 'shield',
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 19,
            color: _c.mute,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
          splashRadius: 18,
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required String icon,
    Widget? suffixIcon,
  }) {
    final c = _c;
    final dark = Theme.of(context).brightness == Brightness.dark;
    OutlineInputBorder b(Color color, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(MyTheme.dzRadius),
          borderSide: BorderSide(color: color, width: w),
        );
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: c.dim, fontSize: 14),
      prefixIcon: Padding(
        padding: const EdgeInsets.all(13),
        child: DzIcon(icon, size: 18, color: c.mute),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: dark ? const Color(0xFF141414) : Colors.white,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      border: b(c.line2),
      enabledBorder: b(c.line2),
      focusedBorder: b(MyTheme.accent, 1.5),
    );
  }

  Widget _buildSignInButton() {
    return SizedBox(
      height: 46,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleSignIn,
        style: ElevatedButton.styleFrom(
          backgroundColor: MyTheme.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: MyTheme.accent.withOpacity(0.55),
          disabledForegroundColor: Colors.white70,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(MyTheme.dzRadius),
          ),
          textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
              )
            : const Text('Sign in and add this computer'),
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    const red = Color(0xFFFF5D5D);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: red.withOpacity(0.08),
        border: Border.all(color: red.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const DzIcon('info', size: 18, color: red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(fontSize: 13, color: _c.fg, height: 1.4)),
          ),
        ],
      ),
    );
  }

  // ── enrolling / pending state ─────────────────────────────────────────────

  Widget _buildEnrolling() {
    final c = _c;
    return _card(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3, color: MyTheme.accent),
          ),
          const SizedBox(height: 24),
          Text(
            'Adding this computer…',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: MyTheme.fontDisplay,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: c.fg,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Finishing setup. This only takes a moment.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.mute, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── success state ─────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    final c = _c;
    return _card(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(border: Border.all(color: c.ok, width: 1.5)),
            child: DzIcon('check', size: 26, color: c.ok),
          ),
          const SizedBox(height: 20),
          Text(
            'This computer is connected',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: MyTheme.fontDisplay,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: c.fg,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'It is linked to your workspace and will appear in your dashboard in a few moments.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.mute, height: 1.55),
          ),
        ],
      ),
    );
  }
}
