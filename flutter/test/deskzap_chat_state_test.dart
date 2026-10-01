import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/deskzap_chat_state.dart';

DeskzapChatMessage msg(String id, String at,
        {String sender = 'operator', String session = 's1'}) =>
    DeskzapChatMessage(
        id: id,
        sessionId: session,
        sender: sender,
        body: 'body $id',
        createdAt: DateTime.parse(at));

void main() {
  group('polling cursor', () {
    test('an overlapping refetch never duplicates messages', () {
      final state = DeskzapChatState();
      state.merge([msg('a', '2026-10-01T10:00:00Z'), msg('b', '2026-10-01T10:00:01Z')], chatOpen: true);
      state.merge([msg('b', '2026-10-01T10:00:01Z'), msg('c', '2026-10-01T10:00:02Z')], chatOpen: true);
      expect(state.messages.map((m) => m.id), ['a', 'b', 'c']);
    });

    test('a message this device sent is kept once when the next poll returns it', () {
      final state = DeskzapChatState();
      final sent = msg('d1', '2026-10-01T10:00:03Z', sender: 'device');
      state.merge([sent], chatOpen: true);
      state.merge([sent, msg('op2', '2026-10-01T10:00:04Z')], chatOpen: true);
      expect(state.messages.map((m) => m.id), ['d1', 'op2']);
    });

    test('sending does not move the cursor, so an earlier operator message is not skipped', () {
      final state = DeskzapChatState();
      state.merge([msg('o1', '2026-10-01T10:00:00Z')], chatOpen: true);
      // The operator posts o2, then this device sends d1 before the next poll.
      state.addSent(msg('d1', '2026-10-01T10:00:02Z', sender: 'device'));
      expect(state.cursor, 'o1');
      state.merge([msg('o2', '2026-10-01T10:00:01Z'), msg('d1', '2026-10-01T10:00:02Z', sender: 'device')], chatOpen: true);
      expect(state.messages.map((m) => m.id), ['o1', 'o2', 'd1']);
      expect(state.cursor, 'd1');
    });

    test('server order (created_at, id) is kept and the cursor is the newest id', () {
      final state = DeskzapChatState();
      expect(state.cursor, isNull);
      state.merge([
        msg('y', '2026-10-01T10:00:00Z'),
        msg('x', '2026-10-01T10:00:00Z'),
        msg('w', '2026-10-01T09:59:59Z'),
      ], chatOpen: true);
      expect(state.messages.map((m) => m.id), ['w', 'x', 'y']);
      expect(state.cursor, 'y');
    });
  });

  group('new chat session', () {
    test('a probe from another session marks the transcript stale; reset starts over', () {
      final state = DeskzapChatState();
      state.merge([msg('o1', '2026-10-01T10:00:00Z')], chatOpen: false);
      expect(state.isStale([msg('o1', '2026-10-01T10:00:00Z')]), isFalse);
      expect(state.isStale([]), isFalse);
      expect(state.isStale([msg('n1', '2026-10-01T11:00:00Z', session: 's2')]), isTrue);
      state.reset();
      expect(state.cursor, isNull);
      expect(state.unread, 0);
      final inbound = state.merge([msg('n1', '2026-10-01T11:00:00Z', session: 's2')], chatOpen: false);
      expect(inbound.map((m) => m.id), ['n1']);
      expect(state.isStale([msg('n1', '2026-10-01T11:00:00Z', session: 's2')]), isFalse);
    });
  });

  group('unread and bubble', () {
    test('only new operator messages count, and only while the chat is closed', () {
      final state = DeskzapChatState();
      final inbound = state.merge([
        msg('o1', '2026-10-01T10:00:00Z'),
        msg('d1', '2026-10-01T10:00:01Z', sender: 'device'),
        msg('o2', '2026-10-01T10:00:02Z'),
      ], chatOpen: false);
      expect(inbound.map((m) => m.id), ['o1', 'o2']);
      expect(state.unread, 2);
      // Refetching the same page raises nothing new.
      expect(state.merge([msg('o2', '2026-10-01T10:00:02Z')], chatOpen: false), isEmpty);
      expect(state.unread, 2);
      state.markRead();
      expect(state.unread, 0);
      state.merge([msg('o3', '2026-10-01T10:00:03Z')], chatOpen: true);
      expect(state.unread, 0);
      expect(state.latestFromOperator?.id, 'o3');
    });

    test('preview uses the first line, trimmed', () {
      expect(deskzapChatPreview('  Hello there  \nsecond line'), 'Hello there');
      expect(deskzapChatPreview('x' * 100, max: 10), '${'x' * 9}…');
    });
  });

  group('parsing', () {
    test('skips malformed entries and tolerates an empty page', () {
      final page = {
        'messages': [
          {'id': 'a', 'sender': 'operator', 'body': 'hi', 'created_at': '2026-10-01T10:00:00Z'},
          {'id': 1, 'sender': 'operator'},
          'nonsense',
        ]
      };
      expect(DeskzapChatMessage.listFromPage(page).map((m) => m.id), ['a']);
      expect(DeskzapChatMessage.listFromPage({'messages': null}), isEmpty);
      expect(DeskzapChatMessage.listFromPage(null), isEmpty);
    });
  });
}
