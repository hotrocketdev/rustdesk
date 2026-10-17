import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_hbb/desktop/widgets/dz_icon.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:get/get.dart';

/// The device last clicked in the Connect device list. The detail panel shows it.
final Rx<Peer?> dzFocusedPeer = Rx<Peer?>(null);

/// Open sessions by device ID: 'connecting' or 'connected' (absent = none).
final RxMap<String, String> dzSessions = <String, String>{}.obs;

/// Right-hand panel in Connect: details and quick actions for the focused device.
class DeskzapDetailPanel extends StatelessWidget {
  const DeskzapDetailPanel({Key? key}) : super(key: key);

  static const double width = 320;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = DzColors.of(context);
    final bg = c.rail;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: bg,
        border: Border(left: BorderSide(color: c.line)),
      ),
      padding: const EdgeInsets.all(22),
      child: AnimatedBuilder(
        animation: gFFI.peerTabModel,
        builder: (context, _) => Obx(() {
        final focused = dzFocusedPeer.value;
        // The lists are rebuilt on every load, so resolve the current instance by ID.
        final peer = focused == null
            ? null
            : (gFFI.peerTabModel.currentTabCachedPeers
                    .firstWhereOrNull((p) => p.id == focused.id) ??
                focused);
        if (peer == null) {
          return Align(
            alignment: Alignment.topLeft,
            child: Text(
              translate('Select a device to see its details and quick actions.'),
              style: TextStyle(fontSize: 13, color: c.dim, height: 1.5),
            ),
          );
        }
        return _Details(peer: peer, c: c);
      })),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.peer, required this.c});

  final Peer peer;
  final DzColors c;

  @override
  Widget build(BuildContext context) {
    final title = peer.alias.isNotEmpty
        ? peer.alias
        : (peer.hostname.isNotEmpty ? peer.hostname : formatID(peer.id));
    final mono = TextStyle(
      fontFamily: MyTheme.fontMono,
      fontSize: 10.5,
      letterSpacing: 0.9,
      fontWeight: FontWeight.w500,
    );
    final statusColor = peer.online ? c.ok : c.dim;
    final rows = <MapEntry<String, String>>[
      if (peer.platform.isNotEmpty) MapEntry('System', peer.platform),
      if (peer.username.isNotEmpty) MapEntry('User', peer.username),
      if (peer.hostname.isNotEmpty) MapEntry('Host', peer.hostname),
      if (peer.device_group_name.isNotEmpty)
        MapEntry('Group', peer.device_group_name),
      if (peer.note.isNotEmpty) MapEntry('Note', peer.note),
    ];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(7, 4, 8, 4),
            decoration: BoxDecoration(border: Border.all(color: c.line2)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                      color: peer.online ? c.ok : c.off, shape: BoxShape.circle),
                ),
                const SizedBox(width: 7),
                Text(translate(peer.online ? 'Online' : 'Offline').toUpperCase(),
                    style: mono.copyWith(color: statusColor)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: MyTheme.fontDisplay,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: c.fg,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            formatID(peer.id),
            style: TextStyle(
                fontFamily: MyTheme.fontMono,
                fontSize: 12,
                letterSpacing: 0.3,
                color: c.dim),
          ),
          const SizedBox(height: 20),
          Obx(() {
            final st = dzSessions[peer.id];
            final connected = st == 'connected';
            final connecting = st == 'connecting';
            final fill = connected ? c.ok.withOpacity(0.14) : MyTheme.accent;
            final fg = connected ? c.ok : Colors.white;
            return InkWell(
              onTap: () => connect(context, peer.id),
              child: Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fill,
                  border: Border.all(color: connected ? c.ok : MyTheme.accent),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(translate(connected ? 'Connected' : (connecting ? 'Connecting' : 'Connect')).toUpperCase(),
                        style: mono.copyWith(color: fg)),
                    const SizedBox(width: 8),
                    DzIcon(connected ? 'check' : 'connect', size: 14, color: fg),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _Secondary(
                  label: translate('Files').toUpperCase(),
                  icon: 'files',
                  c: c,
                  onTap: () => connect(context, peer.id, isFileTransfer: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Secondary(
                  label: translate('Terminal').toUpperCase(),
                  icon: 'actions',
                  c: c,
                  onTap: () => connect(context, peer.id, isTerminal: true),
                ),
              ),
            ],
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 24),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 72,
                      child: Text(r.key,
                          style: TextStyle(fontSize: 12.5, color: c.dim)),
                    ),
                    Expanded(
                      child: Text(r.value,
                          style: TextStyle(fontSize: 12.5, color: c.fg)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Secondary extends StatelessWidget {
  const _Secondary({
    required this.label,
    required this.icon,
    required this.c,
    required this.onTap,
  });

  final String label;
  final String icon;
  final DzColors c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 34,
        decoration: BoxDecoration(border: Border.all(color: c.line2)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DzIcon(icon, size: 15, color: c.mute),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontFamily: MyTheme.fontMono,
                fontSize: 10.5,
                letterSpacing: 0.9,
                fontWeight: FontWeight.w500,
                color: c.fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
