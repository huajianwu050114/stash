typedef WindowFocusListener = void Function(bool isFocused);

abstract interface class DesktopWindowService {
  bool get isSupported;

  Future<void> initialize();

  Future<bool> isVisible();

  Future<bool> isFocused();

  Future<void> focus();

  void addFocusListener(WindowFocusListener listener);

  void removeFocusListener(WindowFocusListener listener);

  Future<void> showQuick();

  Future<void> hideQuick();

  Future<void> showFull();
}

class NoopDesktopWindowService implements DesktopWindowService {
  const NoopDesktopWindowService();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<bool> isFocused() async => true;

  @override
  Future<void> focus() async {}

  @override
  void addFocusListener(WindowFocusListener listener) {}

  @override
  void removeFocusListener(WindowFocusListener listener) {}

  @override
  Future<void> showQuick() async {}

  @override
  Future<void> hideQuick() async {}

  @override
  Future<void> showFull() async {}
}
