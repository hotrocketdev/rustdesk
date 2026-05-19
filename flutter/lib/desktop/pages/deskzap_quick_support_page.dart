import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:window_manager/window_manager.dart';

class DeskzapQuickSupportPage extends StatefulWidget {
  const DeskzapQuickSupportPage({Key? key, required this.code})
      : super(key: key);

  final String code;

  static String? supportCodeFromExecutable() {
    final executable = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
    final match = RegExp(
      r'^deskzap-support-([A-Za-z0-9]{6})(?:\.exe)?$',
      caseSensitive: false,
    ).firstMatch(executable);
    return match?.group(1)?.toUpperCase();
  }

  @override
  State<DeskzapQuickSupportPage> createState() => _DeskzapQuickSupportPageState();
}

class _DeskzapQuickSupportPageState extends State<DeskzapQuickSupportPage> {
  static const _publicBaseUrl = 'https://my.deskzap.co.uk';
  static const _bg = Color(0xFF0A0A0A);
  static const _surface = Color(0xFF141414);
  static const _ink = Color(0xFFFFFFFF);
  static const _accent = Color(0xFF5577FF);
  static const _muted = Color(0xFFA3A3A3);
  static const _line = Color(0xFF2A2A2A);

  Timer? _pollTimer;
  bool _registered = false;
  bool _busy = false;
  String _status = 'starting';
  String _peerId = '';
  String _technicianName = 'the technician';
  String _organizationName = 'Deskzap';
  String? _error;
  String _authToken = '';

  @override
  void initState() {
    super.initState();
    windowManager.setTitle('Deskzap Quick Support');
    windowManager.setSize(const Size(540, 560));
    _configure();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sync());
    _sync();
  }

  Future<void> _configure() async {
    await bind.mainSetOption(key: 'approve-mode', value: 'password');
    await bind.mainSetOption(key: 'allow-hide-cm', value: 'Y');
    await bind.mainSetOption(key: 'verification-method', value: 'use-permanent-password');
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    if (_registered && _status != 'completed') {
      _post('end');
    }
    super.dispose();
  }

  Future<String> _baseUrl() async {
    final configured = (await bind.mainGetApiServer()).trim();
    if (configured.isEmpty) return _publicBaseUrl;
    return configured.endsWith('/')
        ? configured.substring(0, configured.length - 1)
        : configured;
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient();
    try {
      final req = await (method == 'POST'
          ? client.postUrl(Uri.parse('${await _baseUrl()}$path'))
          : client.getUrl(Uri.parse('${await _baseUrl()}$path')));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.write(jsonEncode(body));
      }
      final response = await req.close().timeout(const Duration(seconds: 12));
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(text.isEmpty ? 'HTTP ${response.statusCode}' : text);
      }
      if (text.isEmpty) return {};
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _post(String action, {Map<String, dynamic>? body}) async {
    await _request(
      '/api/v1/support-sessions/${widget.code}/$action',
      method: 'POST',
      body: body ?? {},
    );
  }

  Future<void> _sync() async {
    try {
      final data = await _request('/api/v1/support-sessions/${widget.code}');
      final session = data['session'] as Map<String, dynamic>? ?? {};
      final nextStatus = session['status']?.toString() ?? _status;
      final nextTech = session['technician_name']?.toString() ?? _technicianName;
      final nextOrg = session['organization_name']?.toString() ?? _organizationName;

      var nextPeerId = _peerId;
      if (nextPeerId.isEmpty) {
        nextPeerId = (await bind.mainGetMyId()).trim();
      }

      if (!_registered && nextPeerId.isNotEmpty) {
        _registered = true;
        try {
          final regData = await _request(
            '/api/v1/support-sessions/${widget.code}/register',
            method: 'POST',
            body: {'rustdesk_peer_id': nextPeerId},
          );
          final token = (regData['authorization_token'] as String?) ?? '';
          if (token.isNotEmpty) {
            _authToken = token;
            await bind.mainSetPermanentPassword(password: token);
          }
        } catch (_) {
          _registered = false;
          rethrow;
        }
      }

      if (!mounted) return;
      setState(() {
        _status = _registered && nextStatus == 'pending' ? 'registered' : nextStatus;
        _technicianName = nextTech;
        _organizationName = nextOrg;
        _peerId = nextPeerId;
        _error = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not prepare the support session. Check the code or your internet connection.';
      });
    }
  }

  Future<void> _allow() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_registered) {
        await _sync();
      }
      if (_authToken.isNotEmpty) {
        await bind.mainSetPermanentPassword(password: _authToken);
      }
      // Signal the CM process to auto-accept the next incoming connection
      // without showing the authorization dialog.
      final flag = File('${Directory.systemTemp.path}/deskzap_qs_accept.flag');
      await flag.create(recursive: true);
      await _post('accept');
      if (!mounted) return;
      setState(() => _status = 'active');
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not approve this session yet. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    setState(() => _busy = true);
    try {
      await _post('end');
    } catch (_) {
    } finally {
      await bind.mainSetPermanentPassword(password: '');
      try {
        await File('${Directory.systemTemp.path}/deskzap_qs_accept.flag').delete();
      } catch (_) {}
      if (Platform.isWindows) {
        exit(0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _status == 'active';
    final waitingForId = _peerId.isEmpty && _error == null;
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Kicker
                Text(
                  'DESKZAP QUICK SUPPORT',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 10),
                // Title
                Text(
                  active ? 'Session Active' : 'Remote Support Request',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _ink,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  active
                      ? 'You can leave this window open while $_technicianName helps you.'
                      : '$_technicianName from $_organizationName is requesting access to your computer.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 20),
                // Code panel
                Container(
                  decoration: BoxDecoration(
                    color: _surface,
                    border: Border.all(color: _line, width: 2),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Column(
                    children: [
                      Text(
                        'SESSION CODE',
                        style: TextStyle(color: _muted, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 2.5),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.code,
                        style: TextStyle(color: _accent, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 6),
                      ),
                      if (_peerId.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'ID: $_peerId',
                          style: TextStyle(color: _muted, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Status / error
                if (_error != null)
                  _MessageBox(text: _error!, color: const Color(0xFFE5484D), bg: _surface, line: _line)
                else if (waitingForId)
                  _MessageBox(text: 'Starting secure support service...', color: _muted, bg: _surface, line: _line)
                else if (active)
                  _MessageBox(text: 'The technician can now connect. Close this window to end support.', color: const Color(0xFF22C55E), bg: _surface, line: _line)
                else
                  _MessageBox(text: 'Only click Allow if the technician name and company above are correct.', color: _muted, bg: _surface, line: _line),
                const SizedBox(height: 20),
                // Buttons
                if (active)
                  _BrutalistButton(
                    label: 'End Support',
                    onPressed: _busy ? null : _decline,
                    bg: const Color(0xFFE5484D),
                    fg: Colors.white,
                    border: const Color(0xFFE5484D),
                  )
                else ...[
                  _BrutalistButton(
                    label: _busy ? 'Please wait...' : 'Allow Support',
                    onPressed: _busy || waitingForId ? null : _allow,
                    bg: _accent,
                    fg: Colors.white,
                    border: _accent,
                  ),
                  const SizedBox(height: 10),
                  _BrutalistButton(
                    label: 'Decline',
                    onPressed: _busy ? null : _decline,
                    bg: Colors.transparent,
                    fg: _muted,
                    border: _line,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.text, required this.color, required this.bg, required this.line});

  final String text;
  final Color color;
  final Color bg;
  final Color line;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: line, width: 2),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: color, fontSize: 12, height: 1.45),
      ),
    );
  }
}

class _BrutalistButton extends StatelessWidget {
  const _BrutalistButton({
    required this.label,
    required this.onPressed,
    required this.bg,
    required this.fg,
    required this.border,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color bg;
  final Color fg;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: onPressed == null ? bg.withOpacity(0.4) : bg,
          foregroundColor: fg,
          shape: const RoundedRectangleBorder(),
          side: BorderSide(color: border, width: 2),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: onPressed == null ? fg.withOpacity(0.5) : fg,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
