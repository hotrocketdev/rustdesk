import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/common/widgets/peer_tab_page.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

/// Deskzap Connect left rail: logo, device navigation, device groups, account,
/// theme and settings.
///
/// Replaces the stock RustDesk left pane in the Connect (outgoing-only) app.
/// Navigation drives the same peer tabs the old icon strip did; groups drive
/// the Accessible-devices tab. [compact] shows icons only (narrow windows).
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

  // Peer tab index -> label and icon. Order is the order shown.
  static const List<int> _order = [4, 0, 1, 2, 3];
  static const Map<int, String> _labels = {
    4: 'Devices',
    0: 'Recent',
    1: 'Favourites',
    2: 'Nearby',
    3: 'Address book',
  };
  static const Map<int, IconData> _icons = {
    4: Icons.desktop_windows_outlined,
    0: Icons.history,
    1: Icons.star_outline,
    2: Icons.explore_outlined,
    3: Icons.contacts_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = DzColors.of(context);
    final bg = dark ? const Color(0xFF0E0E0E) : const Color(0xFFF5F5F5);
    final pad = compact ? 8.0 : 12.0;
    return Container(
      width: compact ? compactWidth : fullWidth,
      decoration: BoxDecoration(
        color: bg,
        border: Border(right: BorderSide(color: c.line)),
      ),
      padding: EdgeInsets.fromLTRB(pad, 18, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _logo(c.fg),
          const SizedBox(height: 20),
          Expanded(
            child: AnimatedBuilder(
              animation: gFFI.peerTabModel,
              builder: (context, _) => SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ..._navItems(c, dark),
                    if (!compact) _groups(c, dark),
                  ],
                ),
              ),
            ),
          ),
          Divider(height: 1, color: c.line),
          const SizedBox(height: 12),
          _account(context, dark, c),
        ],
      ),
    );
  }

  List<Widget> _navItems(DzColors c, bool dark) {
    final model = gFFI.peerTabModel;
    final sel = dark ? const Color(0xFF1A1A1A) : const Color(0xFFEBEBEB);
    final onGroups = model.currentTab == 4;
    return [
      for (final t in _order)
        if (model.isVisibleEnabled[t])
          Obx(() {
            final noGroup = gFFI.groupModel.selectedAccessibleItemName.isEmpty;
            final selected = t == 4
                ? onGroups && noGroup
                : model.currentTab == t;
            return _NavItem(
              compact: compact,
              selected: selected,
              icon: _icons[t]!,
              label: _labels[t]!,
              c: c,
              selectedBg: sel,
              onTap: () {
                if (t == 4) {
                  gFFI.groupModel.selectedAccessibleItemName.value = '';
                }
                PeerTabPage.selectTab?.call(t);
              },
            );
          }),
    ];
  }

  Widget _groups(DzColors c, bool dark) {
    final sel = dark ? const Color(0xFF1A1A1A) : const Color(0xFFEBEBEB);
    return Obx(() {
      if (!gFFI.userModel.isLogin || !gFFI.peerTabModel.isVisibleEnabled[4]) {
        return const SizedBox.shrink();
      }
      final gm = gFFI.groupModel;
      final onGroups = gFFI.peerTabModel.currentTab == 4;
      final items = <Widget>[];
      for (final g in gm.deviceGroups) {
        final name = g.name;
        items.add(_NavItem(
          compact: false,
          selected: onGroups &&
              gm.isSelectedDeviceGroup.value &&
              gm.selectedAccessibleItemName.value == name,
          icon: Icons.folder_outlined,
          label: name,
          c: c,
          selectedBg: sel,
          onTap: () {
            gm.isSelectedDeviceGroup.value = true;
            gm.selectedAccessibleItemName.value = name;
            PeerTabPage.selectTab?.call(4);
          },
        ));
      }
      for (final u in gm.users) {
        final name = u.name;
        final isMe = name == gFFI.userModel.userName.value;
        final label = u.displayNameOrName + (isMe ? '  (me)' : '');
        items.add(_NavItem(
          compact: false,
          selected: onGroups &&
              !gm.isSelectedDeviceGroup.value &&
              gm.selectedAccessibleItemName.value == name,
          icon: Icons.person_outline,
          label: label,
          c: c,
          selectedBg: sel,
          onTap: () {
            gm.isSelectedDeviceGroup.value = false;
            gm.selectedAccessibleItemName.value = name;
            PeerTabPage.selectTab?.call(4);
          },
        ));
      }
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 22, 10, 8),
            child: Text(
              'GROUPS',
              style: TextStyle(
                fontFamily: MyTheme.fontMono,
                fontSize: 10.5,
                letterSpacing: 0.9,
                fontWeight: FontWeight.w500,
                color: c.dim,
              ),
            ),
          ),
          ...items,
        ],
      );
    });
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

  Widget _account(BuildContext context, bool dark, DzColors c) {
    final themeButton = _IconTap(
      tooltip: dark ? 'Light mode' : 'Dark mode',
      icon: dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      color: c.mute,
      onTap: () =>
          MyTheme.changeDarkMode(dark ? ThemeMode.light : ThemeMode.dark),
    );
    final settingsButton = _IconTap(
      tooltip: 'Settings',
      icon: Icons.settings_outlined,
      color: c.mute,
      onTap: onSettings,
    );
    return Obx(() {
      final loggedIn = gFFI.userModel.isLogin;
      final name = gFFI.userModel.displayNameOrUserName;
      final initial = name.isEmpty ? 'D' : name.substring(0, 1).toUpperCase();
      void open() => loggedIn ? onAccount() : loginDialog();
      final avatar = InkWell(
        onTap: open,
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
              onTap: open,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loggedIn ? name : 'Sign in to Deskzap',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.fg,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600),
                  ),
                  Text(
                    loggedIn
                        ? '@${gFFI.userModel.userName.value}'
                        : 'See your devices here',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.mute, fontSize: 11),
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
    required this.c,
    required this.selectedBg,
    required this.onTap,
  });

  final bool compact;
  final bool selected;
  final IconData icon;
  final String label;
  final DzColors c;
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
              Icon(icon, size: 18, color: selected ? c.fg : c.mute),
              if (!compact) ...[
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: selected ? c.fg : c.mute, fontSize: 13.5),
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
