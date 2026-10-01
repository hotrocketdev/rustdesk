// Deskzap device chat: transcript state for the remote (Host) side.
// Pure Dart (no Flutter imports) so the polling cursor and unread logic are
// unit-testable. API contract: GET/POST /api/v1/runtime/chat/messages
// (docs/plan-device-chat.md in the Deskzap superproject).

class DeskzapChatMessage {
  final String id;

  /// "operator" (the Deskzap user in the web app) or "device" (this machine).
  final String sender;
  final String body;
  final DateTime createdAt;

  const DeskzapChatMessage({
    required this.id,
    required this.sender,
    required this.body,
    required this.createdAt,
  });

  bool get fromOperator => sender == 'operator';

  static DeskzapChatMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final sender = json['sender'];
    final body = json['body'];
    final created = DateTime.tryParse('${json['created_at']}');
    if (id is! String || sender is! String || body is! String || created == null) {
      return null;
    }
    return DeskzapChatMessage(
        id: id, sender: sender, body: body, createdAt: created.toUtc());
  }

  /// Parses a `{"messages": [...]}` page, skipping malformed entries.
  static List<DeskzapChatMessage> listFromPage(Object? page) {
    if (page is! Map) return const [];
    final raw = page['messages'];
    if (raw is! List) return const [];
    return raw.map(fromJson).whereType<DeskzapChatMessage>().toList();
  }
}

int _compare(DeskzapChatMessage a, DeskzapChatMessage b) {
  // Same order the server pages by: (created_at, id).
  final byTime = a.createdAt.compareTo(b.createdAt);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

class DeskzapChatState {
  final List<DeskzapChatMessage> _messages = [];
  int _unread = 0;
  String? _cursor;

  List<DeskzapChatMessage> get messages => List.unmodifiable(_messages);

  /// Operator messages received while the chat box was closed.
  int get unread => _unread;

  /// The `since` cursor: id of the newest *fetched* message (null on first
  /// load). A message this device just sent never moves it, or an operator
  /// message posted just before it would be skipped.
  String? get cursor => _cursor;

  /// Newest message from the operator, for the bubble preview.
  DeskzapChatMessage? get latestFromOperator {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].fromOperator) return _messages[i];
    }
    return null;
  }

  /// Merges a fetched page (server order, newest last) and advances the
  /// cursor. No duplicates (overlapping refetch, or a message this device
  /// just sent). Returns the operator messages that are new, so the caller can
  /// raise the bubble; they count as unread unless [chatOpen].
  List<DeskzapChatMessage> merge(List<DeskzapChatMessage> page,
      {required bool chatOpen}) {
    if (page.isNotEmpty) {
      _cursor = page.reduce((a, b) => _compare(a, b) >= 0 ? a : b).id;
    }
    return _add(page, chatOpen: chatOpen);
  }

  /// Shows a message this device just sent, without moving the cursor.
  void addSent(DeskzapChatMessage message) => _add([message], chatOpen: true);

  List<DeskzapChatMessage> _add(List<DeskzapChatMessage> page,
      {required bool chatOpen}) {
    final known = {for (final m in _messages) m.id};
    final added = <DeskzapChatMessage>[];
    for (final m in page) {
      if (known.add(m.id)) {
        _messages.add(m);
        added.add(m);
      }
    }
    if (added.isEmpty) return const [];
    _messages.sort(_compare);
    final inbound = added.where((m) => m.fromOperator).toList();
    if (!chatOpen) _unread += inbound.length;
    return inbound;
  }

  void markRead() => _unread = 0;
}

/// Bubble preview text: first line, trimmed to [max] characters.
String deskzapChatPreview(String body, {int max = 80}) {
  final firstLine = body.trim().split('\n').first.trim();
  if (firstLine.length <= max) return firstLine;
  return '${firstLine.substring(0, max - 1).trimRight()}…';
}
