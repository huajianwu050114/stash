import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/quick_stash/application/quick_stash_controller.dart';
import 'package:stash/platform/desktop_window/desktop_window_service.dart';

void main() {
  test('visible focused Quick Stash hides on toggle', () async {
    final window = _FakeWindow();
    final controller = QuickStashController(window);
    await controller.showQuick();
    window.calls.clear();

    await controller.toggleQuick();

    expect(window.calls, ['isVisible', 'isFocused', 'hideQuick']);
    expect(window.visible, isFalse);
  });

  test('visible unfocused Quick Stash focuses instead of hiding', () async {
    final window = _FakeWindow();
    final controller = QuickStashController(window);
    await controller.showQuick();
    window
      ..focused = false
      ..calls.clear();
    final generation = controller.activationGeneration;

    await controller.toggleQuick();

    expect(window.calls, ['isVisible', 'isFocused', 'focus']);
    expect(window.visible, isTrue);
    expect(window.focused, isTrue);
    expect(controller.activationGeneration, generation + 1);
  });

  test('hidden Quick Stash shows and focuses on toggle', () async {
    final window = _FakeWindow();
    final controller = QuickStashController(window);
    await controller.showQuick();
    window
      ..visible = false
      ..focused = false
      ..calls.clear();

    await controller.toggleQuick();

    expect(window.calls, ['isVisible', 'showQuick']);
    expect(window.visible, isTrue);
    expect(window.focused, isTrue);
  });

  test(
    'only a Quick-surface focus event requests editor reactivation',
    () async {
      final window = _FakeWindow();
      final controller = QuickStashController(window);

      window.emitFocus(false);
      window.emitFocus(true);
      expect(controller.activationGeneration, 0);

      await controller.showQuick();
      final generation = controller.activationGeneration;
      window.emitFocus(false);
      expect(controller.activationGeneration, generation);

      window.emitFocus(true);
      expect(controller.activationGeneration, generation + 1);

      await controller.showFull();
      window.emitFocus(true);
      expect(controller.activationGeneration, generation + 1);
    },
  );

  test(
    'Quick Channel toggle uses the quick window and tracks its Channel',
    () async {
      final window = _FakeWindow();
      final controller = QuickStashController(window);

      await controller.showQuickChannel('memes');

      expect(controller.surface, StashSurface.quickChannel);
      expect(controller.quickChannelId, 'memes');
      expect(window.calls, ['showQuick']);

      window.calls.clear();
      await controller.toggleQuickChannel('memes');
      expect(window.calls, ['isVisible', 'isFocused', 'hideQuick']);
    },
  );

  test('another Quick Channel replaces the visible palette', () async {
    final window = _FakeWindow();
    final controller = QuickStashController(window);
    await controller.showQuickChannel('first');
    window.calls.clear();

    await controller.toggleQuickChannel('second');

    expect(controller.quickChannelId, 'second');
    expect(window.calls, ['showQuick']);
  });

  test(
    'a failed window transition does not block the next activation',
    () async {
      final window = _FakeWindow()..failNextQuickShow = true;
      final controller = QuickStashController(window);

      await expectLater(controller.showQuick(), throwsStateError);
      await controller.showQuick();

      expect(window.calls, ['showQuick', 'showQuick']);
      expect(controller.surface, StashSurface.quick);
      expect(window.visible, isTrue);
    },
  );
}

class _FakeWindow implements DesktopWindowService {
  final List<String> calls = [];
  final Set<WindowFocusListener> _focusListeners = {};
  bool visible = true;
  bool focused = true;
  bool failNextQuickShow = false;

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
  Future<bool> isFocused() async {
    calls.add('isFocused');
    return focused;
  }

  @override
  Future<void> focus() async {
    calls.add('focus');
    focused = true;
    emitFocus(true);
  }

  @override
  Future<void> showQuick() async {
    calls.add('showQuick');
    if (failNextQuickShow) {
      failNextQuickShow = false;
      throw StateError('window failed');
    }
    visible = true;
    focused = true;
    emitFocus(true);
  }

  @override
  Future<void> hideQuick() async {
    calls.add('hideQuick');
    visible = false;
    focused = false;
    emitFocus(false);
  }

  @override
  Future<void> showFull() async {
    calls.add('showFull');
    visible = true;
    focused = true;
    emitFocus(true);
  }

  @override
  Future<void> hide() => hideQuick();

  @override
  Future<void> setCloseHandler(WindowCloseHandler? handler) async {}

  @override
  Future<void> destroy() async {}

  @override
  void dispose() {}

  @override
  void addFocusListener(WindowFocusListener listener) {
    _focusListeners.add(listener);
  }

  @override
  void removeFocusListener(WindowFocusListener listener) {
    _focusListeners.remove(listener);
  }

  void emitFocus(bool isFocused) {
    focused = isFocused;
    for (final listener in Set<WindowFocusListener>.of(_focusListeners)) {
      listener(isFocused);
    }
  }
}
