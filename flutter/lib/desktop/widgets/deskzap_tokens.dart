import 'package:flutter/material.dart';

/// Deskzap colours for the light and dark themes (same values as the website).
/// Pick with [DzColors.of]; do not hard-code these in widgets.
class DzColors {
  const DzColors._({
    required this.fg,
    required this.mute,
    required this.dim,
    required this.line,
    required this.line2,
    required this.card,
    required this.raise,
    required this.ok,
    required this.off,
  });

  final Color fg;
  final Color mute;
  final Color dim;
  final Color line;
  final Color line2;
  final Color card;
  final Color raise;
  final Color ok;
  final Color off;

  static const DzColors _dark = DzColors._(
    fg: Color(0xFFFAFAFA),
    mute: Color(0xFFA3A3A3),
    dim: Color(0xFF737373),
    line: Color(0xFF262626),
    line2: Color(0xFF333333),
    card: Color(0xFF121212),
    raise: Color(0xFF1A1A1A),
    ok: Color(0xFF3DDC84),
    off: Color(0xFF737373),
  );

  static const DzColors _light = DzColors._(
    fg: Color(0xFF0A0A0A),
    mute: Color(0xFF525252),
    dim: Color(0xFF737373),
    line: Color(0xFFE5E5E5),
    line2: Color(0xFFD4D4D4),
    card: Color(0xFFFFFFFF),
    raise: Color(0xFFF0F0F0),
    ok: Color(0xFF16863F),
    off: Color(0xFF8A8A8A),
  );

  static DzColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;
}
