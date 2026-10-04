import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/quick_stash/application/quick_stash_controller.dart';
import 'package:stash/platform/desktop_window/desktop_window_service.dart';

void main() {
  test(
    'window controller shows, toggles, hides, and restores full mode',
    () async {
      final window = _FakeWindow();
      final controller = QuickStashController(window);

      await controller.showQuick();
      expect(controller.surface, StashSurface.quick);
      expect(window.calls, ['showQuick']);

      await controller.toggleQuick();
      expect(window.calls, ['showQuick', 'isVisible', 'hideQuick']);

      window.visible = false;
      await controller.toggleQuick();
      expect(window.calls.last, 'showQuick');

      await controller.hideQuick();
      expect(window.calls.last, 'hideQuick');

      await controller.showFull();
      expect(controller.surface, StashSurface.full);
      expect(window.calls.last, 'showFull');
    },
  );
}

class _FakeWindow implements DesktopWindowService {
  final List<String> calls = [];
  bool visible = true;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isVisible() async {
    calls.add('isVisible');
    return visible;
  }

  @override
  Future<void> showQuick() async {
    visible = true;
    calls.add('showQuick');
  }

  @override
  Future<void> hideQuick() async {
    visible = false;
    calls.add('hideQuick');
  }

  @override
  Future<void> showFull() async => calls.add('showFull');
}
