import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shown in Host (incoming-only) mode when no enrollment token is present and
/// the OAuth 2.0 Device Authorization flow is running in the background.
class DeskzapEnrollmentPage extends StatefulWidget {
  const DeskzapEnrollmentPage({Key? key}) : super(key: key);

  @override
  State<DeskzapEnrollmentPage> createState() => _DeskzapEnrollmentPageState();
}

class _DeskzapEnrollmentPageState extends State<DeskzapEnrollmentPage>
    with SingleTickerProviderStateMixin {
  Timer? _pollTimer;
  String _userCode = '';
  String _verificationUri = '';
  String _status = 'loading'; // loading | pending | authorized | enrolled | expired | denied
  late AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _spinController.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    final raw = bind.mainGetDeskzapDeviceAuthState();
    if (raw.isEmpty) {
      if (mounted) setState(() => _status = 'loading');
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _userCode = map['user_code'] as String? ?? '';
        _verificationUri = map['verification_uri'] as String? ?? '';
        _status = map['status'] as String? ?? 'pending';
      });
      if (_status == 'enrolled') {
        _pollTimer?.cancel();
        // Clear persisted state after a short delay so the normal Host UI
        // shows on next launch without re-triggering the enrollment screen.
        Future.delayed(const Duration(seconds: 4), () {
          bind.mainClearDeskzapDeviceAuthState();
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF4F8FF),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_status == 'loading') {
      return const Center(child: CircularProgressIndicator());
    }
    if (_status == 'enrolled') {
      return _buildSuccess();
    }
    if (_status == 'expired') {
      return _buildError('Code expired. Restart the app to try again.');
    }
    if (_status == 'denied') {
      return _buildError('Access denied. Restart the app to try again.');
    }
    return _buildPendingCard();
  }

  Widget _buildPendingCard() {
    final qrData = _verificationUri.isEmpty
        ? ''
        : _userCode.isEmpty
            ? _verificationUri
            : '$_verificationUri?code=$_userCode';

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            const Text(
              'Add this computer to Deskzap',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A2340),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Open the address below in your browser and enter the code.',
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7799)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),

            // Verification URI
            if (_verificationUri.isNotEmpty) ...[
              GestureDetector(
                onTap: () => launchUrl(Uri.parse(_verificationUri)),
                child: Text(
                  _verificationUri.replaceFirst(RegExp(r'^https?://'), ''),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2963F2),
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // User code
            if (_userCode.isNotEmpty) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF4FF),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBDD0FF)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _userCode,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        color: Color(0xFF1A2340),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _userCode));
                      },
                      icon: const Icon(Icons.copy,
                          size: 18, color: Color(0xFF6B7799)),
                      tooltip: 'Copy code',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

            // QR code
            if (qrData.isNotEmpty) ...[
              QrImageView(
                data: qrData,
                version: QrVersions.auto,
                size: 160,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 8),
              const Text(
                'Scan with your phone for convenience',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA8C4)),
              ),
              const SizedBox(height: 24),
            ],

            // Waiting indicator
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RotationTransition(
                  turns: _spinController,
                  child: const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF2963F2),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Waiting for authorization…',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7799)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccess() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
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
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A2340),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This computer is now managed by Deskzap.',
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7799)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 48),
            const SizedBox(height: 20),
            Text(
              message,
              style: const TextStyle(fontSize: 14, color: Color(0xFF1A2340)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
