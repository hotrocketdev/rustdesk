import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_hbb/desktop/widgets/dz_icon.dart';

/// Host home header: app mark, name and one line of help text.
class DzHostHeader extends StatelessWidget {
  const DzHostHeader({Key? key, required this.tip}) : super(key: key);

  final String tip;

  @override
  Widget build(BuildContext context) {
    final c = DzColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          loadIcon(34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DESKZAP HOST',
                  style: TextStyle(
                    fontFamily: MyTheme.fontMono,
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w500,
                    color: c.fg,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  tip,
                  style: TextStyle(fontSize: 12, height: 1.4, color: c.mute),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled value box (ID, one-time password) with a pink left rule and
/// small icon actions on the right.
class DzHostField extends StatelessWidget {
  const DzHostField({
    Key? key,
    required this.label,
    required this.value,
    this.actions = const [],
  }) : super(key: key);

  final String label;
  final Widget value;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = DzColors.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(
          left: const BorderSide(color: kDzHostPink, width: 2),
          top: BorderSide(color: c.line2),
          right: BorderSide(color: c.line2),
          bottom: BorderSide(color: c.line2),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontFamily: MyTheme.fontMono,
                    fontSize: 10,
                    letterSpacing: 1.0,
                    color: c.dim,
                  ),
                ),
                const SizedBox(height: 4),
                value,
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Square icon button used in [DzHostField] actions.
class DzHostAction extends StatelessWidget {
  const DzHostAction({
    Key? key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  }) : super(key: key);

  final String icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = DzColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: DzIcon(icon, size: 16, color: c.mute),
        ),
      ),
    );
  }
}
