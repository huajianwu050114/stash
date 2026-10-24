import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash/features/sync/application/auto_sync_coordinator.dart';
import 'package:stash/features/sync/domain/sync_protocol.dart';
import 'package:stash/features/sync/lan/lan_discovery.dart';

void main() {
  group('AutoSyncCoordinator', () {
    test(
      'process start syncs pending data without a manual sync call',
      () async {
        final scheduler = _FakeScheduler();
        var calls = 0;
        final coordinator = _coordinator(
          scheduler,
          syncOnce: () async {
            calls++;
            return _cycle();
          },
        );
        addTearDown(coordinator.dispose);

        coordinator.start();
        await scheduler.flush();
        await _settle();

        expect(calls, 1);
        expect(coordinator.status.state, AutoSyncState.upToDate);
      },
    );

    test('rapid local mutations debounce into one follow-up cycle', () async {
      final scheduler = _FakeScheduler();
      var calls = 0;
      final coordinator = _coordinator(
        scheduler,
        syncOnce: () async {
          calls++;
          return _cycle();
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      await scheduler.flush();
      await _settle();
      expect(calls, 1);

      coordinator
        ..notifyLocalMutation()
        ..notifyLocalMutation()
        ..notifyLocalMutation();
      await scheduler.elapse(const Duration(milliseconds: 499));
      await _settle();
      expect(calls, 1);
      await scheduler.elapse(const Duration(milliseconds: 1));
      await _settle();
      expect(calls, 2);
    });

    test(
      'relay reappearance bypasses backoff and retries immediately',
      () async {
        final scheduler = _FakeScheduler();
        var calls = 0;
        final coordinator = _coordinator(
          scheduler,
          syncOnce: () async {
            calls++;
            return calls == 1
                ? _cycle(
                    pending: 1,
                    errors: const [
                      SyncFailure(stage: 'push', message: 'offline'),
                    ],
                  )
                : _cycle();
          },
        );
        addTearDown(coordinator.dispose);
        coordinator.start();
        await scheduler.flush();
        await _settle();
        expect(coordinator.status.state, AutoSyncState.waitingForRelay);
        expect(scheduler.nextDelay, const Duration(seconds: 1));

        coordinator.notifyRelayDiscovered();
        await scheduler.flush();
        await _settle();
        expect(calls, 2);
        expect(coordinator.status.state, AutoSyncState.upToDate);
      },
    );

    test('network and foreground events wake sync immediately', () async {
      final scheduler = _FakeScheduler();
      var calls = 0;
      final coordinator = _coordinator(
        scheduler,
        syncOnce: () async {
          calls++;
          return _cycle();
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      await scheduler.flush();
      await _settle();

      coordinator.notifyNetworkAvailable();
      await scheduler.flush();
      await _settle();
      coordinator.notifyAppForeground();
      await scheduler.flush();
      await _settle();
      expect(calls, 3);
    });

    test('single-flight queues exactly one follow-up cycle', () async {
      final scheduler = _FakeScheduler();
      final first = Completer<SyncCycleResult>();
      var calls = 0;
      var active = 0;
      var maxActive = 0;
      final coordinator = _coordinator(
        scheduler,
        syncOnce: () async {
          calls++;
          active++;
          if (active > maxActive) maxActive = active;
          final result = calls == 1 ? await first.future : _cycle();
          active--;
          return result;
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      await scheduler.flush();
      await _settle();
      expect(calls, 1);

      coordinator
        ..notifyLocalMutation()
        ..notifyRelayDiscovered()
        ..notifyAppForeground();
      expect(calls, 1);
      first.complete(_cycle());
      await _settle();
      await scheduler.flush();
      await _settle();
      expect(calls, 2);
      expect(maxActive, 1);
    });

    test(
      'conflict preserves pending status without an automatic retry loop',
      () async {
        final scheduler = _FakeScheduler();
        var calls = 0;
        final coordinator = _coordinator(
          scheduler,
          syncOnce: () async {
            calls++;
            return _cycle(
              pending: 1,
              errors: const [
                SyncFailure(stage: 'push-conflict', message: 'conflict'),
              ],
            );
          },
        );
        addTearDown(coordinator.dispose);
        coordinator.start();
        await scheduler.flush();
        await _settle();
        expect(coordinator.status.state, AutoSyncState.conflict);
        expect(coordinator.status.pendingCount, 1);

        await scheduler.elapse(const Duration(minutes: 1));
        await _settle();
        expect(calls, 1);
      },
    );

    test('bounded retry intervals increase without a tight loop', () async {
      final scheduler = _FakeScheduler();
      var calls = 0;
      final coordinator = _coordinator(
        scheduler,
        syncOnce: () async {
          calls++;
          return _cycle(
            pending: 1,
            errors: const [SyncFailure(stage: 'pull', message: 'offline')],
          );
        },
      );
      addTearDown(coordinator.dispose);
      coordinator.start();
      await scheduler.flush();
      await _settle();
      expect(scheduler.nextDelay, const Duration(seconds: 1));
      await scheduler.elapse(const Duration(seconds: 1));
      await _settle();
      expect(calls, 2);
      expect(scheduler.nextDelay, const Duration(seconds: 2));
      await scheduler.elapse(const Duration(seconds: 2));
      await _settle();
      expect(calls, 3);
      expect(scheduler.nextDelay, const Duration(seconds: 5));
    });
  });

  test(
    'trusted discovery ignores unknown relay and reports reappearance',
    () async {
      final source = _FakeDiscovery();
      final trusted = TrustedLanRelayDiscovery(
        source: source,
        trustedRelayId: 'known',
      );
      final events = <LanRelayAvailability>[];
      final subscription = trusted.changes.listen(events.add);
      addTearDown(subscription.cancel);
      addTearDown(trusted.dispose);
      await trusted.start();

      source.emit(_availability('unknown', true));
      source.emit(_availability('known', true));
      source.emit(_availability('known', false));
      source.emit(_availability('known', true));
      await _settle();

      expect(events.map((event) => event.relay.relayId), everyElement('known'));
      expect(events.map((event) => event.available), [true, false, true]);
    },
  );
}

AutoSyncCoordinator _coordinator(
  _FakeScheduler scheduler, {
  required Future<SyncCycleResult> Function() syncOnce,
}) => AutoSyncCoordinator(
  syncOnce: syncOnce,
  scheduler: scheduler,
  debounce: const Duration(milliseconds: 500),
  periodicFallback: const Duration(days: 1),
  backoff: const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ],
);

SyncCycleResult _cycle({
  int pending = 0,
  List<SyncFailure> errors = const [],
}) => SyncCycleResult(
  pushed: 0,
  pulled: 0,
  conflicts: const [],
  errors: errors,
  remainingPending: pending,
  cursor: 0,
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeScheduler implements SyncScheduler {
  DateTime _now = DateTime.utc(2026);
  final List<_FakeTask> _tasks = [];

  @override
  DateTime now() => _now;

  Duration? get nextDelay {
    final active = _tasks.where((task) => task.isActive).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    return active.isEmpty ? null : active.first.due.difference(_now);
  }

  @override
  SyncScheduledTask schedule(Duration delay, void Function() callback) {
    final task = _FakeTask(_now.add(delay), callback);
    _tasks.add(task);
    return task;
  }

  Future<void> flush() => elapse(Duration.zero);

  Future<void> elapse(Duration duration) async {
    final target = _now.add(duration);
    while (true) {
      final due =
          _tasks
              .where((task) => task.isActive && !task.due.isAfter(target))
              .toList()
            ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      final task = due.first;
      _now = task.due;
      task.run();
      await _settle();
    }
    _now = target;
  }
}

class _FakeTask implements SyncScheduledTask {
  _FakeTask(this.due, this.callback);
  final DateTime due;
  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void run() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

class _FakeDiscovery implements LanRelayDiscovery {
  final _controller = StreamController<LanRelayAvailability>.broadcast();

  @override
  Stream<LanRelayAvailability> get changes => _controller.stream;

  void emit(LanRelayAvailability event) => _controller.add(event);

  @override
  Future<void> start() async {}

  @override
  Future<void> dispose() => _controller.close();
}

LanRelayAvailability _availability(String id, bool available) =>
    LanRelayAvailability(
      relay: LanRelayAdvertisement(
        relayId: id,
        protocolVersion: 1,
        host: '127.0.0.1',
        port: 1234,
      ),
      available: available,
    );
