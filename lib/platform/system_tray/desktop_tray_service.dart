import 'dart:async';

import 'package:tray_manager/tray_manager.dart' as tray;

abstract interface class DesktopTrayService {
  Future<void> initialize({
    required Future<void> Function() onOpenFull,
    required Future<void> Function() onOpenQuick,
    required Future<void> Function() onExit,
  });

  Future<void> dispose();
}

class NoopDesktopTrayService implements DesktopTrayService {
  const NoopDesktopTrayService();

  @override
  Future<void> initialize({
    required Future<void> Function() onOpenFull,
    required Future<void> Function() onOpenQuick,
    required Future<void> Function() onExit,
  }) async {}

  @override
  Future<void> dispose() async {}
}

class TrayManagerDesktopTrayService implements DesktopTrayService {
  factory TrayManagerDesktopTrayService({
    required String label,
    required String identifier,
  }) => TrayManagerDesktopTrayService._(label, identifier);

  TrayManagerDesktopTrayService._(this._label, this._identifier);

  static const iconAsset = 'windows/runner/resources/app_icon.ico';

  final String _label;
  final String _identifier;

  tray.TrayIcon? _trayIcon;
  tray.Image? _iconImage;
  tray.Menu? _menu;
  final List<tray.MenuItem> _menuItems = [];
  final List<({tray.MenuItem item, tray.ListenerId listener})> _menuListeners =
      [];
  tray.ListenerId? _trayListener;

  @override
  Future<void> initialize({
    required Future<void> Function() onOpenFull,
    required Future<void> Function() onOpenQuick,
    required Future<void> Function() onExit,
  }) async {
    if (_trayIcon != null) return;
    final trayIcon = tray.TrayIcon.createWithIdentifier(_identifier);
    final image = tray.ImageAsset.fromAsset(iconAsset);
    final menu = tray.Menu.create();
    if (trayIcon == null || image == null || menu == null) {
      trayIcon?.dispose();
      image?.dispose();
      menu?.dispose();
      throw StateError('Could not create the Stash system tray.');
    }

    final open = _menuItem('Open $_label', onOpenFull);
    final quick = _menuItem(
      _label == 'Stash' ? 'Quick Stash' : 'Quick Stash Dev',
      onOpenQuick,
    );
    final exit = _menuItem('Exit', onExit);
    menu
      ..addItem(open)
      ..addItem(quick)
      ..addSeparator()
      ..addItem(exit);
    _menuItems.addAll([open, quick, exit]);

    _trayListener = trayIcon.addListener((event) async {
      if (event is tray.TrayIconClickedEvent) await onOpenFull();
    });
    trayIcon
      ..icon = image
      ..setTooltip(_label)
      ..setContextMenu(menu)
      ..setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
    if (!trayIcon.setVisible(true)) {
      await _disposeResources(trayIcon: trayIcon, image: image, menu: menu);
      throw StateError('Could not show the Stash system tray.');
    }
    _trayIcon = trayIcon;
    _iconImage = image;
    _menu = menu;
  }

  tray.MenuItem _menuItem(String label, Future<void> Function() callback) {
    final item = tray.MenuItem.createWithLabelAndType(
      label,
      tray.MenuItemType.normal,
    );
    if (item == null) throw StateError('Could not create tray menu item.');
    final listener = item.addListener((event) async {
      if (event is tray.MenuItemClickedEvent) await callback();
    });
    _menuListeners.add((item: item, listener: listener));
    return item;
  }

  @override
  Future<void> dispose() async {
    final trayIcon = _trayIcon;
    final image = _iconImage;
    final menu = _menu;
    _trayIcon = null;
    _iconImage = null;
    _menu = null;
    if (trayIcon == null || image == null || menu == null) return;
    await _disposeResources(trayIcon: trayIcon, image: image, menu: menu);
  }

  Future<void> _disposeResources({
    required tray.TrayIcon trayIcon,
    required tray.Image image,
    required tray.Menu menu,
  }) async {
    final trayListener = _trayListener;
    if (trayListener != null) trayIcon.removeListener(trayListener);
    _trayListener = null;
    for (final entry in _menuListeners) {
      entry.item.removeListener(entry.listener);
    }
    _menuListeners.clear();
    trayIcon
      ..setContextMenu(null)
      ..setVisible(false)
      ..dispose();
    menu.dispose();
    for (final item in _menuItems) {
      item.dispose();
    }
    _menuItems.clear();
    image.dispose();
  }
}
