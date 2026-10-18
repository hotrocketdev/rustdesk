import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A Deskzap icon (`assets/deskzap/icons/dz-<name>.svg`), tinted with [color].
///
/// Names are the part after `dz-`, e.g. `DzIcon('devices')`. The set lives in
/// the repo under docs/design/icons; see its README.
class DzIcon extends StatelessWidget {
  const DzIcon(this.name, {Key? key, this.size = 18, this.color})
      : super(key: key);

  final String name;
  final double size;
  final Color? color;

  static String asset(String name) => 'assets/deskzap/icons/dz-$name.svg';

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? DzColors.of(context).fg;
    return SvgPicture.asset(
      asset(name),
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
    );
  }
}
