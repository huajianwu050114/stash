import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash/platform/desktop_window/window_manager_desktop_window_service.dart';

void main() {
  test('desktop surfaces use distinct lightweight default sizes', () {
    expect(WindowManagerDesktopWindowService.fullSize, const Size(960, 660));
    expect(WindowManagerDesktopWindowService.quickSize, const Size(410, 600));
    expect(
      WindowManagerDesktopWindowService.quickChannelSize,
      const Size(410, 500),
    );
  });

  test('compact surface is right aligned and vertically centered', () {
    final bounds = WindowManagerDesktopWindowService.compactBoundsFor(
      visibleOrigin: const Offset(1920, 40),
      visibleSize: const Size(1920, 1040),
      desiredSize: WindowManagerDesktopWindowService.quickSize,
    );

    expect(bounds, const Rect.fromLTWH(3430, 260, 410, 600));
  });

  test('compact surface stays inside a smaller work area', () {
    final bounds = WindowManagerDesktopWindowService.compactBoundsFor(
      visibleOrigin: const Offset(-900, 0),
      visibleSize: const Size(900, 500),
      desiredSize: WindowManagerDesktopWindowService.quickSize,
    );

    expect(bounds, const Rect.fromLTWH(-410, 0, 410, 500));
  });
}
