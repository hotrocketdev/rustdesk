import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_switch.dart';
import 'package:flutter_hbb/desktop/widgets/deskzap_tokens.dart';
import 'package:flutter_hbb/desktop/widgets/dz_icon.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

class InstallPage extends StatefulWidget {
  const InstallPage({Key? key}) : super(key: key);

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _InstallPageState() {
    Get.put<DesktopTabController>(tabController);
    const label = "install";
    tabController.add(TabInfo(
        key: label,
        label: label,
        closable: false,
        page: _InstallPageBody(
          key: const ValueKey(label),
        )));
  }

  @override
  void dispose() {
    super.dispose();
    Get.delete<DesktopTabController>();
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(controller: tabController)),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  const _InstallPageBody({Key? key}) : super(key: key);

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = true.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    final installOptions = jsonDecode(bind.installInstallOptions());
    startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
    desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
    printer.value = installOptions['PRINTER'] != '0';
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  Widget Option(RxBool option, {String label = ''}) {
    return InkWell(
      onTap: () => btnEnabled.value ? option.value = !option.value : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(translate(label))),
            Obx(() => DzSwitch(
                  value: option.value,
                  onChanged: btnEnabled.value ? (v) => option.value = v : null,
                )),
          ],
        ),
      ),
    );
  }

  Widget _dzButton(DzColors c, String text, VoidCallback? onTap,
      {bool primary = false, String? icon}) {
    final accent = bind.isIncomingOnly() ? kDzHostPink : MyTheme.accent;
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: primary ? accent : Colors.transparent,
            border: Border.all(color: primary ? accent : c.line2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                DzIcon(icon, size: 14, color: primary ? Colors.white : c.fg),
                const SizedBox(width: 8),
              ],
              Text(
                translate(text).toUpperCase(),
                style: TextStyle(
                  fontFamily: MyTheme.fontMono,
                  fontSize: 11,
                  letterSpacing: 0.9,
                  fontWeight: FontWeight.w500,
                  color: primary ? Colors.white : c.fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double em = 13;
    final c = DzColors.of(context);
    final accent = bind.isIncomingOnly() ? kDzHostPink : MyTheme.accent;
    return Scaffold(
        backgroundColor: null,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  loadIcon(30),
                  const SizedBox(width: 12),
                  Text(
                    translate('Installation'),
                    style: TextStyle(
                      fontFamily: MyTheme.fontDisplay,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: c.fg,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                translate('Installation Path').toUpperCase(),
                style: TextStyle(
                  fontFamily: MyTheme.fontMono,
                  fontSize: 10.5,
                  letterSpacing: 1.0,
                  color: c.dim,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      readOnly: true,
                      style: TextStyle(
                          fontFamily: MyTheme.fontMono, fontSize: 12.5),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.all(0.75 * em),
                      ),
                    ).workaroundFreezeLinuxMint().marginOnly(right: 10),
                  ),
                  Obx(() => _dzButton(c, 'Change Path',
                      btnEnabled.value ? selectInstallPath : null,
                      icon: 'files')),
                ],
              ),
              const SizedBox(height: 14),
              Option(startmenu, label: 'Create start menu shortcuts'),
              Option(desktopicon, label: 'Create desktop icon'),
              Option(printer, label: 'Install {$appName} Printer'),
              Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.card,
                    border: Border(
                      left: BorderSide(color: accent, width: 2),
                      top: BorderSide(color: c.line2),
                      right: BorderSide(color: c.line2),
                      bottom: BorderSide(color: c.line2),
                    ),
                  ),
                  child: Row(
                    children: [
                      DzIcon('info', size: 22, color: c.mute)
                          .marginOnly(right: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(translate('agreement_tip'),
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.45,
                                        color: c.mute))
                                .marginOnly(bottom: 8),
                            InkWell(
                              onTap: () => launchUrlString(
                                  'https://deskzap.co.uk/privacy'),
                              child: Tooltip(
                                message: 'https://deskzap.co.uk/privacy',
                                child: Text(
                                  translate('End-user license agreement'),
                                  style: TextStyle(
                                      decoration: TextDecoration.underline,
                                      color: c.fg,
                                      fontSize: 12.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    ],
                  )).marginSymmetric(vertical: 2 * em),
              Row(
                children: [
                  Expanded(
                    // NOT use Offstage to wrap LinearProgressIndicator
                    child: Obx(() => showProgress.value
                        ? LinearProgressIndicator(
                                color: accent, backgroundColor: c.line)
                            .marginOnly(right: 10)
                        : Offstage()),
                  ),
                  Obx(() => _dzButton(c, 'Cancel',
                          btnEnabled.value ? () => windowManager.close() : null,
                          icon: 'close')
                      .marginOnly(right: 10)),
                  Obx(() => _dzButton(c, 'Accept and Install',
                      btnEnabled.value ? install : null,
                      primary: true, icon: 'check')),
                  Offstage(
                    offstage: bind.installShowRunWithoutInstall(),
                    child: Obx(() => _dzButton(
                            c,
                            'Run without install',
                            btnEnabled.value
                                ? () => bind.installRunWithoutInstall()
                                : null,
                            icon: 'display')
                        .marginOnly(left: 10)),
                  ),
                ],
              )
            ],
          ).paddingSymmetric(horizontal: 4 * em, vertical: 3 * em),
        ));
  }

  void install() {
    do_install() {
      btnEnabled.value = false;
      showProgress.value = true;
      String args = '';
      if (startmenu.value) args += ' startmenu';
      if (desktopicon.value) args += ' desktopicon';
      if (printer.value) args += ' printer';
      bind.installInstallMe(options: args, path: controller.text);
    }

    do_install();
  }

  void selectInstallPath() async {
    String? install_path = await FilePicker.platform
        .getDirectoryPath(initialDirectory: controller.text);
    if (install_path != null) {
      controller.text = join(install_path, await bind.mainGetAppName());
    }
  }
}
