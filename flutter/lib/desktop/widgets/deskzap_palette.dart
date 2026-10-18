import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/autocomplete.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_hbb/desktop/widgets/dz_icon.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Ctrl+K (Cmd+K on macOS): find a device or run an action.
Future<void> showDzPalette(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _DzPalette(parent: context),
  );
}

class _Item {
  _Item(this.icon, this.title, this.sub, this.run, {this.isPeer = false});
  final String icon;
  final String title;
  final String sub;
  final VoidCallback run;
  final bool isPeer;
}

class _DzPalette extends StatefulWidget {
  const _DzPalette({required this.parent});
  final BuildContext parent;

  @override
  State<_DzPalette> createState() => _DzPaletteState();
}

class _DzPaletteState extends State<_DzPalette> {
  final AllPeersLoader _loader = AllPeersLoader();
  final TextEditingController _text = TextEditingController();
  int _sel = 0;

  @override
  void initState() {
    super.initState();
    _loader.init(setState);
    _loader.getAllPeers();
  }

  @override
  void dispose() {
    _loader.clear();
    _text.dispose();
    super.dispose();
  }

  List<_Item> _items() {
    final q = _text.text.trim().toLowerCase().replaceAll(' ', '');
    bool match(String s) => q.isEmpty || s.toLowerCase().replaceAll(' ', '').contains(q);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final out = <_Item>[];
    final peers = <Peer>[];
    final seen = <String>{};
    for (final p in _loader.peers) {
      if (!seen.add(p.id)) continue;
      if (match(p.id) || match(p.alias) || match(p.hostname) || match(p.username)) {
        peers.add(p);
      }
    }
    peers.sort((a, b) => (b.online ? 1 : 0) - (a.online ? 1 : 0));
    for (final p in peers.take(6)) {
      final name = p.alias.isNotEmpty
          ? p.alias
          : (p.hostname.isNotEmpty ? p.hostname : formatID(p.id));
      out.add(_Item('devices', name, formatID(p.id), () {
        Navigator.of(context).pop();
        connect(widget.parent, p.id);
      }, isPeer: true));
    }
    final actions = <_Item>[
      _Item('settings', 'Open settings', 'Settings', () {
        Navigator.of(context).pop();
        if (DesktopSettingPage.tabKeys.isNotEmpty) {
          DesktopSettingPage.switch2page(DesktopSettingPage.tabKeys[0]);
        }
      }),
      _Item(dark ? 'sun' : 'moon', dark ? 'Switch to light theme' : 'Switch to dark theme', 'Theme', () {
        Navigator.of(context).pop();
        MyTheme.changeDarkMode(dark ? ThemeMode.light : ThemeMode.dark);
      }),
      _Item('plus', 'Add a device', 'Opens the install page', () {
        Navigator.of(context).pop();
        launchUrlString('https://my.deskzap.co.uk/install/host');
      }),
    ];
    out.addAll(actions.where((a) => match(a.title)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = DzColors.of(context);
    final items = _items();
    if (_sel >= items.length) _sel = items.isEmpty ? 0 : items.length - 1;
    final mono = TextStyle(
      fontFamily: MyTheme.fontMono,
      fontSize: 10.5,
      letterSpacing: 0.9,
      fontWeight: FontWeight.w500,
      color: c.dim,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            setState(() => _sel = items.isEmpty ? 0 : (_sel + 1) % items.length),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(
            () => _sel = items.isEmpty ? 0 : (_sel - 1 + items.length) % items.length),
      },
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 96, left: 16, right: 16),
          child: Material(
            color: c.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(MyTheme.dzRadius),
              side: BorderSide(color: c.line2),
            ),
            elevation: 12,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.line)),
                    ),
                    child: Row(
                      children: [
                        DzIcon('search', size: 17, color: c.dim),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _text,
                            autofocus: true,
                            onChanged: (_) => setState(() => _sel = 0),
                            onSubmitted: (_) {
                              if (items.isNotEmpty) items[_sel].run();
                            },
                            style: TextStyle(fontSize: 15, color: c.fg),
                            decoration: InputDecoration(
                              hintText: 'Search devices or type a command',
                              hintStyle: TextStyle(fontSize: 15, color: c.dim),
                              border: InputBorder.none,
                              filled: false,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                        Text('ESC', style: mono),
                      ],
                    ),
                  ),
                  if (items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('No devices or commands match.',
                          style: TextStyle(fontSize: 13, color: c.dim)),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i == 0 || items[i].isPeer != items[i - 1].isPeer)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                                child: Text(items[i].isPeer ? 'DEVICES' : 'COMMANDS', style: mono),
                              ),
                            InkWell(
                              onTap: items[i].run,
                              child: Container(
                                height: 40,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                decoration: BoxDecoration(
                                  color: i == _sel ? c.raise : null,
                                  border: i == _sel
                                      ? const Border(left: BorderSide(color: MyTheme.accent, width: 2))
                                      : null,
                                ),
                                child: Row(
                                  children: [
                                    DzIcon(items[i].icon, size: 17, color: i == _sel ? c.fg : c.mute),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(items[i].title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(fontSize: 14, color: c.fg)),
                                    ),
                                    Text(items[i].sub,
                                        style: TextStyle(
                                            fontFamily: MyTheme.fontMono,
                                            fontSize: 11.5,
                                            color: c.dim)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.line)),
                    ),
                    child: Row(
                      children: [
                        Text('UP/DOWN  NAVIGATE', style: mono),
                        const SizedBox(width: 18),
                        Text('ENTER  RUN', style: mono),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
