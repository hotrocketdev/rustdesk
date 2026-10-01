// Deskzap device chat — remote (Host) side.
//
// Polls GET /api/v1/runtime/chat/messages with the device's runtime heartbeat
// token (same auth and api-server as the Host's command poll). An inbound
// operator message raises a bubble in the bottom-right; clicking it opens the
// chat box. Online-only by design: no queue, nothing persisted locally.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/deskzap_chat_state.dart';
import 'package:flutter_hbb/models/platform_model.dart';

import 'button.dart';

const _pollInterval = Duration(seconds: 3);
const _maxBody = 4000;
const _operatorName = 'Deskzap support';

class DeskzapChatController extends ChangeNotifier {
  final DeskzapChatState state = DeskzapChatState();
  bool chatOpen = false;
  bool bubbleVisible = false;
  bool sending = false;
  String? error;

  /// Called when an operator message arrives while the chat box is closed.
  VoidCallback? onInbound;

  /// Called when the chat box opens or closes (window sizing).
  void Function(bool open)? onChatOpenChanged;

  Timer? _timer;
  bool _polling = false;

  void start() {
    _timer ??= Timer.periodic(_pollInterval, (_) => poll());
    poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<({String baseUrl, String token})?> _endpoint() async {
    final token =
        bind.mainGetLocalOption(key: 'deskzap-runtime-heartbeat-token');
    if (token.isEmpty) return null;
    final apiServer = await bind.mainGetOption(key: 'api-server');
    if (apiServer.isEmpty) return null;
    final baseUrl = apiServer.endsWith('/')
        ? apiServer.substring(0, apiServer.length - 1)
        : apiServer;
    return (baseUrl: baseUrl, token: token);
  }

  Future<void> poll() async {
    if (_polling) return;
    _polling = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final endpoint = await _endpoint();
      if (endpoint == null) return;
      final query = {'limit': '100', if (state.cursor != null) 'since': state.cursor!};
      final uri = Uri.parse('${endpoint.baseUrl}/api/v1/runtime/chat/messages')
          .replace(queryParameters: query);
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', 'Bearer ${endpoint.token}');
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode != 200) return;
      final page = DeskzapChatMessage.listFromPage(jsonDecode(body));
      final inbound = state.merge(page, chatOpen: chatOpen);
      if (inbound.isNotEmpty && !chatOpen) {
        bubbleVisible = true;
        onInbound?.call();
      }
      if (inbound.isNotEmpty || page.isNotEmpty) notifyListeners();
    } catch (_) {
      // Offline or unreachable: the next tick retries.
    } finally {
      client.close();
      _polling = false;
    }
  }

  Future<bool> send(String text) async {
    final body = text.trim();
    if (body.isEmpty || sending) return false;
    sending = true;
    error = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final endpoint = await _endpoint();
      if (endpoint == null) {
        error = 'This computer is not connected to Deskzap.';
        return false;
      }
      final request = await client.postUrl(
          Uri.parse('${endpoint.baseUrl}/api/v1/runtime/chat/messages'));
      request.headers.set('Authorization', 'Bearer ${endpoint.token}');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'body': body}));
      final response = await request.close();
      final payload = await response.transform(const Utf8Decoder()).join();
      if (response.statusCode == 201) {
        final decoded = jsonDecode(payload);
        final message = decoded is Map
            ? DeskzapChatMessage.fromJson(decoded['message'])
            : null;
        if (message != null) state.merge([message], chatOpen: true);
        return true;
      }
      error = switch (response.statusCode) {
        404 => 'This chat has ended.',
        413 => 'Message is too long (maximum $_maxBody characters).',
        400 => 'Type a message first.',
        _ => 'Your message was not sent. Please try again.',
      };
      return false;
    } catch (_) {
      error = 'Could not reach Deskzap. Your message was not sent.';
      return false;
    } finally {
      client.close();
      sending = false;
      notifyListeners();
    }
  }

  void openChat() {
    chatOpen = true;
    bubbleVisible = false;
    state.markRead();
    notifyListeners();
    onChatOpenChanged?.call(true);
  }

  void closeChat() {
    chatOpen = false;
    error = null;
    notifyListeners();
    onChatOpenChanged?.call(false);
  }

  void dismissBubble() {
    bubbleVisible = false;
    notifyListeners();
  }
}

/// Bubble or chat box, layered over the Host window's content.
class DeskzapChatOverlay extends StatelessWidget {
  final DeskzapChatController controller;
  const DeskzapChatOverlay({Key? key, required this.controller})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.chatOpen) {
          return Positioned.fill(child: _ChatBox(controller: controller));
        }
        if (controller.bubbleVisible) {
          return Positioned(
              right: 8, bottom: 8, child: _ChatBubble(controller: controller));
        }
        return const SizedBox.shrink();
      },
    );
  }
}

BoxDecoration _panelDecoration(BuildContext context) => BoxDecoration(
      color: Theme.of(context).colorScheme.background,
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(6),
    );

class _ChatBubble extends StatelessWidget {
  final DeskzapChatController controller;
  const _ChatBubble({required this.controller});

  @override
  Widget build(BuildContext context) {
    final latest = controller.state.latestFromOperator;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final unread = controller.state.unread;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: controller.openChat,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 264,
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          decoration: _panelDecoration(context),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.chat_bubble_outline,
                  size: 18, color: MyTheme.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(_operatorName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: textColor)),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 6),
                        _UnreadBadge(count: unread),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      latest == null ? '' : deskzapChatPreview(latest.body),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: textColor?.withOpacity(0.75)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: translate('Close'),
                iconSize: 16,
                splashRadius: 14,
                icon: const Icon(Icons.close),
                onPressed: controller.dismissBubble,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
          color: MyTheme.accent, borderRadius: BorderRadius.circular(8)),
      child: Text(count > 99 ? '99+' : '$count',
          style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white)),
    );
  }
}

class _ChatBox extends StatefulWidget {
  final DeskzapChatController controller;
  const _ChatBox({required this.controller});

  @override
  State<_ChatBox> createState() => _ChatBoxState();
}

class _ChatBoxState extends State<_ChatBox> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int _shownCount = 0;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ok = await widget.controller.send(_input.text);
    if (ok) _input.clear();
  }

  void _followNewest() {
    final count = widget.controller.state.messages.length;
    if (count == _shownCount) return;
    _shownCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final messages = c.state.messages;
    _followNewest();
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: _panelDecoration(context),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              const Icon(Icons.chat_bubble_outline,
                  size: 16, color: MyTheme.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Chat with $_operatorName',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor)),
              ),
              IconButton(
                tooltip: translate('Close'),
                iconSize: 16,
                splashRadius: 14,
                icon: const Icon(Icons.close),
                onPressed: c.closeChat,
              ),
            ]),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text('No messages yet.',
                        style: TextStyle(
                            fontSize: 12,
                            color: textColor?.withOpacity(0.6))))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(10),
                    itemCount: messages.length,
                    itemBuilder: (context, i) =>
                        _MessageRow(message: messages[i]),
                  ),
          ),
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(c.error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
            ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              // Attachments arrive in a later slice; the slot is reserved.
              IconButton(
                tooltip: 'File sharing is coming soon',
                iconSize: 18,
                splashRadius: 16,
                icon: const Icon(Icons.attach_file),
                onPressed: null,
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !c.sending,
                  maxLength: _maxBody,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    counterText: '',
                    hintText: 'Type a reply',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Button(
                text: c.sending ? 'Sending…' : 'Send',
                onTap: () => _send(),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  final DeskzapChatMessage message;
  const _MessageRow({required this.message});

  @override
  Widget build(BuildContext context) {
    final fromOperator = message.fromOperator;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final time = TimeOfDay.fromDateTime(message.createdAt.toLocal())
        .format(context);
    return Align(
      // From this computer's point of view: support on the left, me on the right.
      alignment: fromOperator ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: fromOperator
              ? Theme.of(context).dividerColor.withOpacity(0.25)
              : MyTheme.accent.withOpacity(0.15),
          border: Border.all(
              color: fromOperator
                  ? Theme.of(context).dividerColor
                  : MyTheme.accent.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${fromOperator ? _operatorName : 'You'} · $time',
                style: TextStyle(
                    fontSize: 11, color: textColor?.withOpacity(0.7))),
            const SizedBox(height: 2),
            SelectableText(message.body,
                style: TextStyle(fontSize: 13, color: textColor)),
          ],
        ),
      ),
    );
  }
}
