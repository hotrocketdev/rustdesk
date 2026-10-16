import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/common/widgets/peer_tab_page.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

/// Deskzap Connect left rail: logo, device navigation, account, theme, settings.
///
/// Replaces the stock RustDesk left pane in the Connect (outgoing-only) app.
/// Navigation drives the same peer tabs the old icon strip did. [compact]
/// shows icons only (narrow windows).
class DeskzapRail extends StatelessWidget {
  const DeskzapRail({
    Key? key,
    required this.compact,
    required this.onAccount,
    required this.onSettings,
  }) : super(key: key);

  final bool compact;
  final VoidCallback onAccount;
  final VoidCallback onSettings;

  static const double fullWidth = 236;
  static const double compactWidth = 64;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF0E0E0E) : const Color(0xFFF5F5F5);
    final line = dark ? const Color(0xFF262626) : const Color(0xFFE5E5E5);
    final fg = dark ? const Color(0xFFFAFAFA) : const Color(0xFF0A0A0A);
    final mute = dark ? const Color(0xFFA3A3A3) : const Color(0xFF525252);
    final sel = dark ? const Color(0xFF1A1A1A) : const Color(0xFFEBEBEB);
    final pad = compact ? 8.0 : 12.0;
    return Container(
      width: compact ? compactWidth : fullWidth,
      decoration: BoxDecoration(
        color: bg,
        border: Border(right: BorderSide(color: line)),
      ),
      padding: EdgeInsets.fromLTRB(pad, 18, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _logo(fg),
          const SizedBox(height: 20),
          AnimatedBuilder(
            animation: gFFI.peerTabModel,
            builder: (context, _) {
              final model = gFFI.peerTabModel;
              return Column(
                children: [
                  for (final t in model.visibleEnabledOrderedIndexs)
                    _NavItem(
                      compact: compact,
                      selected: model.currentTab == t,
                      icon: model.tabIcon(t),
                      label: model.tabTooltip(t),
                      fg: fg,
                      mute: mute,
                      selectedBg: sel,
                      onTap: () => PeerTabPage.selectTab?.call(t),
                    ),
                ],
              );
            },
          ),
          const Spacer(),
          Divider(height: 1, color: line),
          const SizedBox(height: 12),
          _account(context, dark, fg, mute),
        ],
      ),
    );
  }

  Widget _logo(Color fg) {
    final filter = ColorFilter.mode(fg, BlendMode.srcIn);
    if (compact) {
      return Center(
        child: SvgPicture.asset('assets/deskzap/deskzap-mark.svg',
            width: 28, height: 32, colorFilter: filter),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SvgPicture.asset('assets/deskzap/deskzap-logo.svg',
            width: 112, height: 45, colorFilter: filter),
      ),
    );
  }

  Widget _account(BuildContext context, bool dark, Color fg, Color mute) {
    final themeButton = _IconTap(
      tooltip: dark ? 'Light mode' : 'Dark mode',
      icon: dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      color: mute,
      onTap: () => MyTheme.changeDarkMode(
          dark ? ThemeMode.light : ThemeMode.dark),
    );
    final settingsButton = _IconTap(
      tooltip: 'Settings',
      icon: Icons.settings_outlined,
      color: mute,
      onTap: onSettings,
    );
    return Obx(() {
      final loggedIn = gFFI.userModel.isLogin;
      final name = gFFI.userModel.displayNameOrUserName;
      final initial = name.isEmpty ? 'D' : name.substring(0, 1).toUpperCase();
      final avatar = InkWell(
        onTap: () => loggedIn ? onAccount() : loginDialog(),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          color: MyTheme.accent,
          child: loggedIn
              ? Text(initial,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600))
              : const Icon(Icons.login, size: 16, color: Colors.white),
        ),
      );
      if (compact) {
        return Column(
          children: [
            Tooltip(message: loggedIn ? name : 'Sign in', child: avatar),
            const SizedBox(height: 6),
            themeButton,
            settingsButton,
          ],
        );
      }
      return Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => loggedIn ? onAccount() : loginDialog(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loggedIn ? name : 'Sign in to Deskzap',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: fg, fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    loggedIn
                        ? '@${gFFI.userModel.userName.value}'
                        : 'See your devices here',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: mute, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          themeButton,
          settingsButton,
        ],
      );
    });
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.compact,
    required this.selected,
    required this.icon,
    required this.label,
    required this.fg,
    required this.mute,
    required this.selectedBg,
    required this.onTap,
  });

  final bool compact;
  final bool selected;
  final IconData icon;
  final String label;
  final Color fg;
  final Color mute;
  final Color selectedBg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          margin: const EdgeInsets.only(bottom: 2),
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 10),
          decoration: BoxDecoration(
            color: selected ? selectedBg : null,
            border: selected
                ? const Border(
                    left: BorderSide(color: MyTheme.accent, width: 2))
                : null,
          ),
          child: Row(
            mainAxisAlignment:
                compact ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: selected ? fg : mute),
              if (!compact) ...[
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected ? fg : mute, fontSize: 13.5),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTap extends StatelessWidget {
  const _IconTap({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}
