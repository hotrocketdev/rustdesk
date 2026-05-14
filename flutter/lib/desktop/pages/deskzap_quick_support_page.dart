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
  static const _blue = Color(0xFF2963F2);
  static const _dark = Color(0xFF16213D);
  static const _muted = Color(0xFF5C6C8F);
  static const _bg = Color(0xFFF4F8FF);
  static const _border = Color(0xFFDCE7FF);

  Timer? _pollTimer;
  bool _registered = false;
  bool _busy = false;
  String _status = 'starting';
  String _peerId = '';
  String _technicianName = 'the technician';
  String _organizationName = 'Deskzap';
  String? _error;

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
    await bind.mainSetOption(key: 'approve-mode', value: 'click');
    await bind.mainSetOption(key: 'allow-hide-cm', value: 'Y');
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
      await bind.mainSetOption(key: 'deskzap-pending-accept', value: 'Y');
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
      await bind.mainSetOption(key: 'deskzap-pending-accept', value: '');
      await bind.mainSetPermanentPassword(password: '');
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
          constraints: const BoxConstraints(maxWidth: 460),
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _border),
              boxShadow: [
                BoxShadow(
                  blurRadius: 40,
                  offset: const Offset(0, 20),
                  color: _dark.withOpacity(0.10),
                )
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const CircleAvatar(
                  radius: 34,
                  backgroundColor: Color(0xFFEAF1FF),
                  child: Icon(Icons.computer, size: 34, color: _blue),
                ),
                const SizedBox(height: 22),
                Text(
                  active ? 'Support session approved' : 'Deskzap Quick Support',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _dark,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  active
                      ? 'You can leave this window open while $_technicianName helps you.'
                      : '$_technicianName from $_organizationName is requesting access to your computer.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 16,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 18),
                _CodeRow(code: widget.code, peerId: _peerId),
                const SizedBox(height: 20),
                if (_error != null)
                  _MessageBox(text: _error!, color: const Color(0xFFB42318))
                else if (waitingForId)
                  const _MessageBox(
                    text: 'Starting secure support service...',
                    color: _muted,
                  )
                else if (active)
                  const _MessageBox(
                    text: 'The technician can now connect. Close this window to end support.',
                    color: Color(0xFF0A7A55),
                  )
                else
                  const _MessageBox(
                    text: 'Only click Allow if the technician name and company are correct.',
                    color: _muted,
                  ),
                const SizedBox(height: 22),
                if (active)
                  ElevatedButton(
                    onPressed: _busy ? null : _decline,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE5484D),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: const Text('End Support'),
                  )
                else ...[
                  ElevatedButton(
                    onPressed: _busy || waitingForId ? null : _allow,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: Text(_busy ? 'Please wait...' : 'Allow Support'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: _busy ? null : _decline,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _dark,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Decline'),
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

class _CodeRow extends StatelessWidget {
  const _CodeRow({required this.code, required this.peerId});

  final String code;
  final String peerId;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F7FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            'Code: $code',
            style: const TextStyle(
              color: Color(0xFF263B66),
              fontWeight: FontWeight.w700,
            ),
          ),
          if (peerId.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Secure ID: $peerId',
              style: const TextStyle(color: Color(0xFF5C6C8F), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: color, fontSize: 13, height: 1.4),
      ),
    );
  }
}
