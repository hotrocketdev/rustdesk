import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';

/// Deskzap on/off switch: square, blue when on. Pass a null [onChanged] to
/// show it disabled.
class DzSwitch extends StatelessWidget {
  const DzSwitch({Key? key, required this.value, required this.onChanged})
      : super(key: key);

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = DzColors.of(context);
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            width: 38,
            height: 22,
            decoration: BoxDecoration(
              color: value ? MyTheme.accent : c.card,
              border: Border.all(color: value ? MyTheme.accent : c.line2),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.all(2),
                color: value ? Colors.white : c.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
