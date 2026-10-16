import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_hbb/desktop/widgets/dz_icon.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

/// One entry in a Deskzap menu: a label, optional icon, and whether it is the
/// current choice (shown with a check).
class _DzItem {
  const _DzItem(this.label, this.selected, this.onTap, {this.icon});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? icon;
}

/// Opens a Deskzap-styled menu under [anchor]: a mono heading, then the items.
Future<void> _showDzMenu(
  BuildContext anchor,
  String heading,
  List<_DzItem> items,
) {
  final c = DzColors.of(anchor);
  final box = anchor.findRenderObject() as RenderBox;
  final pos = box.localToGlobal(Offset.zero);
  final mono = TextStyle(
    fontFamily: MyTheme.fontMono,
    fontSize: 10.5,
    letterSpacing: 0.9,
    fontWeight: FontWeight.w500,
    color: c.dim,
  );
  return showMenu<void>(
    context: anchor,
    position: RelativeRect.fromLTRB(
        pos.dx, pos.dy + box.size.height + 4, pos.dx + box.size.width, 0),
    color: c.card,
    elevation: 8,
    constraints: const BoxConstraints(minWidth: 210),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MyTheme.dzRadius),
      side: BorderSide(color: c.line2),
    ),
    items: <PopupMenuEntry<void>>[
      PopupMenuItem<void>(
        enabled: false,
        height: 34,
        child: Text(heading.toUpperCase(), style: mono),
      ),
      for (final it in items)
        PopupMenuItem<void>(
          height: 34,
          onTap: it.onTap,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: it.selected
                    ? DzIcon('check', size: 15, color: MyTheme.accentInk)
                    : null,
              ),
              if (it.icon != null) ...[
                DzIcon(it.icon!, size: 16, color: c.mute),
                const SizedBox(width: 10),
              ],
              Text(it.label,
                  style: TextStyle(fontSize: 13, color: c.fg)),
            ],
          ),
        ),
    ],
  );
}

/// Small bordered mono button used for VIEW and SORT in the device list bar.
class _DzBarButton extends StatelessWidget {
  const _DzBarButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final void Function(BuildContext) onTap;

  @override
  Widget build(BuildContext context) {
    final c = DzColors.of(context);
    final mono = TextStyle(
      fontFamily: MyTheme.fontMono,
      fontSize: 10.5,
      letterSpacing: 0.9,
      fontWeight: FontWeight.w500,
    );
    return Builder(
      builder: (btnContext) => InkWell(
        onTap: () => onTap(btnContext),
        child: Container(
          height: 28,
          margin: const EdgeInsets.only(left: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(border: Border.all(color: c.line2)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: mono.copyWith(color: c.dim)),
              const SizedBox(width: 8),
              Text(value.toUpperCase(), style: mono.copyWith(color: c.fg)),
              const SizedBox(width: 6),
              DzIcon('chevron-down', size: 14, color: c.mute),
            ],
          ),
        ),
      ),
    );
  }
}

/// VIEW: comfortable rows or compact rows.
class DzViewButton extends StatelessWidget {
  const DzViewButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final compact = peerCardUiType.value == PeerUiType.tile;
      Future<void> pick(PeerUiType t) async {
        peerCardUiType.value = t;
        await bind.setLocalFlutterOption(
            k: kOptionPeerCardUiType, v: t.index.toString());
      }

      return _DzBarButton(
        label: 'VIEW',
        value: compact ? 'Compact' : 'Rows',
        onTap: (ctx) => _showDzMenu(ctx, 'Change view', [
          _DzItem('Rows', !compact, () => pick(PeerUiType.list),
              icon: 'view-rows'),
          _DzItem('Compact', compact, () => pick(PeerUiType.tile),
              icon: 'view-compact'),
        ]),
      );
    });
  }
}

/// SORT: remote ID, host, username, status.
class DzSortButton extends StatelessWidget {
  const DzSortButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final current = peerSort.value;
      return _DzBarButton(
        label: 'SORT',
        value: translate(current),
        onTap: (ctx) => _showDzMenu(ctx, 'Sort by', [
          for (final e in PeerSortType.values)
            _DzItem(translate(e), e == current, () async {
              peerSort.value = e;
              await bind.setLocalFlutterOption(k: kOptionPeerSorting, v: e);
            }),
        ]),
      );
    });
  }
}
