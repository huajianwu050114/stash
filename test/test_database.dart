import 'package:drift/native.dart';
import 'package:stash/core/database/app_database.dart';

/// Opens a fresh in-memory database for a single test.
///
/// Tests never touch the user's real on-device database file.
AppDatabase createInMemoryDatabase() => AppDatabase(NativeDatabase.memory());
