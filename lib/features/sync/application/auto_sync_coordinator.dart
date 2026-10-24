import 'dart:async';

import '../domain/sync_protocol.dart';

enum AutoSyncState {
  idle,
  syncing,
  upToDate,
  offline,
  waitingForRelay,
  pending,
  conflict,
  error,
}

enum AutoSyncTrigger {
  processStart,
  localMutation,
  relayDiscovered,
  networkAvailable,
  appForeground,
  periodicFallback,
}

class AutoSyncStatus {
  const AutoSyncStatus({
    required this.state,
    required this.pendingCount,
    this.lastSuccessfulSync,
    this.lastErrorCategory,
  });

  const AutoSyncStatus.idle()
    : state = AutoSyncState.idle,
      pendingCount = 0,
      lastSuccessfulSync = null,
      lastErrorCategory = null;

  final AutoSyncState state;
  final int pendingCount;
  final DateTime? lastSuccessfulSync;
  final String? lastErrorCategory;
}

abstract interface class SyncScheduledTask {
  bool get isActive;
  void cancel();
}

abstract interface class SyncScheduler {
  DateTime now();
  SyncScheduledTask schedule(Duration delay, void Function() callback);
}

class TimerSyncScheduler implements SyncScheduler {
  const TimerSyncScheduler();

  @override
  DateTime now() => DateTime.now();

  @override
  SyncScheduledTask schedule(Duration delay, void Function() callback) =>
      _TimerTask(Timer(delay, callback));
}

class _TimerTask implements SyncScheduledTask {
  const _TimerTask(this.timer);
  final Timer timer;

  @override
  bool get isActive => timer.isActive;

  @override
  void cancel() => timer.cancel();
}

/// Event-driven policy layer that decides when to invoke one transport-
/// agnostic SyncEngine cycle. It owns no push, pull, cursor, or conflict logic.
class AutoSyncCoordinator {
  AutoSyncCoordinator({
    required this._syncOnce,
    this.scheduler = const TimerSyncScheduler(),
    this.debounce = const Duration(milliseconds: 500),
    this.periodicFallback = const Duration(minutes: 5),
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
      Duration(minutes: 2),
    ],
  });

  final Future<SyncCycleResult> Function() _syncOnce;
  final SyncScheduler scheduler;
  final Duration debounce;
  final Duration periodicFallback;
  final List<Duration> backoff;
  final _statuses = StreamController<AutoSyncStatus>.broadcast();

  AutoSyncStatus _status = const AutoSyncStatus.idle();
  SyncScheduledTask? _scheduledSync;
  SyncScheduledTask? _periodicTask;
  bool _started = false;
  bool _running = false;
  bool _requestedAgain = false;
  int _backoffIndex = 0;

  AutoSyncStatus get status => _status;
  Stream<AutoSyncStatus> get statuses => _statuses.stream;
  bool get isRunning => _running;

  void start() {
    if (_started) return;
    _started = true;
    _schedulePeriodic();
    _request(AutoSyncTrigger.processStart, immediate: true, resetBackoff: true);
  }

  void notifyLocalMutation() {
    _emit(
      AutoSyncStatus(
        state: AutoSyncState.pending,
        pendingCount: _status.pendingCount < 1 ? 1 : _status.pendingCount,
        lastSuccessfulSync: _status.lastSuccessfulSync,
      ),
    );
    _request(
      AutoSyncTrigger.localMutation,
      delay: debounce,
      resetBackoff: true,
    );
  }

  void notifyRelayDiscovered() => _request(
    AutoSyncTrigger.relayDiscovered,
    immediate: true,
    resetBackoff: true,
  );

  void notifyNetworkAvailable() => _request(
    AutoSyncTrigger.networkAvailable,
    immediate: true,
    resetBackoff: true,
  );

  void notifyAppForeground() => _request(
    AutoSyncTrigger.appForeground,
    immediate: true,
    resetBackoff: true,
  );

  Future<void> dispose() async {
    _started = false;
    _scheduledSync?.cancel();
    _scheduledSync = null;
    _periodicTask?.cancel();
    _periodicTask = null;
    await _statuses.close();
  }

  void _request(
    AutoSyncTrigger trigger, {
    bool immediate = false,
    bool resetBackoff = false,
    Duration? delay,
  }) {
    if (!_started) return;
    if (resetBackoff) _backoffIndex = 0;
    if (_running) {
      _requestedAgain = true;
      return;
    }
    final requestedDelay = immediate ? Duration.zero : delay ?? Duration.zero;
    final existing = _scheduledSync;
    if (existing != null && existing.isActive) {
      if (requestedDelay != Duration.zero) return;
      existing.cancel();
    }
    _scheduledSync = scheduler.schedule(requestedDelay, () {
      _scheduledSync = null;
      unawaited(_run(trigger));
    });
  }

  Future<void> _run(AutoSyncTrigger trigger) async {
    if (!_started || _running) return;
    _running = true;
    _emit(
      AutoSyncStatus(
        state: AutoSyncState.syncing,
        pendingCount: _status.pendingCount,
        lastSuccessfulSync: _status.lastSuccessfulSync,
      ),
    );
    try {
      final result = await _syncOnce();
      final conflict =
          result.conflicts.isNotEmpty ||
          result.errors.any((error) => error.stage == 'push-conflict');
      if (conflict) {
        _backoffIndex = 0;
        _emit(
          AutoSyncStatus(
            state: AutoSyncState.conflict,
            pendingCount: result.remainingPending,
            lastSuccessfulSync: _status.lastSuccessfulSync,
            lastErrorCategory: 'conflict',
          ),
        );
      } else if (result.errors.isNotEmpty) {
        final pending = result.remainingPending;
        _emit(
          AutoSyncStatus(
            state: pending > 0
                ? AutoSyncState.waitingForRelay
                : AutoSyncState.offline,
            pendingCount: pending,
            lastSuccessfulSync: _status.lastSuccessfulSync,
            lastErrorCategory: result.errors.first.stage,
          ),
        );
        _scheduleBackoff();
      } else {
        _backoffIndex = 0;
        _emit(
          AutoSyncStatus(
            state: result.remainingPending == 0
                ? AutoSyncState.upToDate
                : AutoSyncState.pending,
            pendingCount: result.remainingPending,
            lastSuccessfulSync: scheduler.now(),
          ),
        );
      }
    } catch (error) {
      _emit(
        AutoSyncStatus(
          state: _status.pendingCount > 0
              ? AutoSyncState.waitingForRelay
              : AutoSyncState.error,
          pendingCount: _status.pendingCount,
          lastSuccessfulSync: _status.lastSuccessfulSync,
          lastErrorCategory: error is SyncRemoteException
              ? error.kind?.name ?? 'remote'
              : 'unexpected',
        ),
      );
      _scheduleBackoff();
    } finally {
      _running = false;
      if (_requestedAgain && _started) {
        _requestedAgain = false;
        _request(trigger, immediate: true);
      }
    }
  }

  void _scheduleBackoff() {
    if (!_started || backoff.isEmpty) return;
    final index = _backoffIndex.clamp(0, backoff.length - 1);
    _backoffIndex = (_backoffIndex + 1).clamp(0, backoff.length - 1);
    _scheduledSync?.cancel();
    _scheduledSync = scheduler.schedule(backoff[index], () {
      _scheduledSync = null;
      unawaited(_run(AutoSyncTrigger.periodicFallback));
    });
  }

  void _schedulePeriodic() {
    if (!_started || periodicFallback <= Duration.zero) return;
    _periodicTask = scheduler.schedule(periodicFallback, () {
      _periodicTask = null;
      _request(AutoSyncTrigger.periodicFallback, immediate: true);
      _schedulePeriodic();
    });
  }

  void _emit(AutoSyncStatus status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }
}
