// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_tools/src/airreload_device.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/vmservice.dart';
import 'package:test/fake.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

import '../src/common.dart';

void main() {
  late BufferLogger logger;
  late AirreloadLogReader reader;
  late TestVmService service;
  late FlutterVmService connection;
  late List<String> lines;

  setUp(() {
    logger = BufferLogger.test();
    reader = AirreloadLogReader('Airreload', logger: logger);
    service = TestVmService();
    connection = FlutterVmService(service);
    lines = <String>[];
    reader.logLines.listen(lines.add);
  });

  tearDown(() async {
    reader.dispose();
    await service.close();
  });

  testWithoutContext(
    'prints stdout and stderr, preserving indentation and multiline output',
    () async {
      await reader.provideVmService(connection);
      service.stdout.add(output('  hello 🌍\n'));
      service.stderr.add(output('Error: failed\n  #0 main\n'));
      service.stdout.add(output('\n'));
      await pumpEventQueue();
      expect(lines, <String>['  hello 🌍', 'Error: failed\n  #0 main', '']);
      expect(service.requests, <String>['Debug', 'Stdout', 'Stderr']);
    },
  );

  testWithoutContext('listens before streamListen can emit the first event', () async {
    service.onListen = (String stream) {
      if (stream == 'Stdout') {
        service.stdout.add(output('first output\n'));
      }
    };
    await reader.provideVmService(connection);
    await pumpEventQueue();
    expect(lines, <String>['first output']);
  });

  testWithoutContext('keeps receiving output after the root isolate is replaced', () async {
    await reader.provideVmService(connection);
    service.stdout.add(output('before restart\n'));
    await reader.provideVmService(connection);
    service.stdout.add(output('after restart\n', isolateId: 'isolates/2'));
    await pumpEventQueue();
    expect(lines, <String>['before restart', 'after restart']);
    expect(service.requests, <String>['Debug', 'Stdout', 'Stderr']);
  });

  testWithoutContext('reconnection replaces old listeners without duplicating output', () async {
    await reader.provideVmService(connection);
    final replacement = TestVmService();
    addTearDown(replacement.close);
    await reader.provideVmService(FlutterVmService(replacement));
    service.stdout.add(output('stale output\n'));
    replacement.stdout.add(output('new process\n'));
    replacement.stderr.add(output('new error\n'));
    await pumpEventQueue();
    expect(lines, <String>['new process', 'new error']);
    expect(service.stdout.hasListener, isFalse);
    expect(service.stderr.hasListener, isFalse);
  });

  testWithoutContext('already subscribed errors do not prevent the other streams', () async {
    service.errors['Debug'] = vm_service.RPCErrorKind.kStreamAlreadySubscribed.code;
    service.errors['Stdout'] = vm_service.RPCErrorKind.kStreamAlreadySubscribed.code;
    await reader.provideVmService(connection);
    service.stderr.add(output('error output\n'));
    await pumpEventQueue();
    expect(lines, <String>['error output']);
    expect(service.requests, <String>['Debug', 'Stdout', 'Stderr']);
    expect(logger.warningText, isEmpty);
  });

  testWithoutContext(
    'reports unexpected stream errors while preserving attach and other logs',
    () async {
      service.errors['Stdout'] = -32603;
      await reader.provideVmService(connection);
      service.stderr.add(output('still visible\n'));
      await pumpEventQueue();
      expect(lines, <String>['still visible']);
      expect(logger.warningText, contains('Unable to stream Airreload Stdout logs'));
    },
  );

  testWithoutContext('ignores missing or malformed payloads and tolerates invalid UTF-8', () async {
    await reader.provideVmService(connection);
    service.stdout.add(vm_service.Event(kind: 'WriteEvent', timestamp: 0));
    service.stdout.add(vm_service.Event(kind: 'WriteEvent', timestamp: 0, bytes: ''));
    service.stdout.add(vm_service.Event(kind: 'WriteEvent', timestamp: 0, bytes: '%%%'));
    service.stdout.add(
      vm_service.Event(kind: 'WriteEvent', timestamp: 0, bytes: base64Encode(<int>[255, 10])),
    );
    service.stdout.add(output('next log\n'));
    await pumpEventQueue();
    expect(lines, <String>['�', 'next log']);
  });

  testWithoutContext('dispose removes listeners, closes output, and cannot resubscribe', () async {
    await reader.provideVmService(connection);
    final Future<void> done = reader.logLines.drain<void>();
    reader.dispose();
    reader.dispose();
    await done;
    await reader.provideVmService(FlutterVmService(service));
    expect(service.stdout.hasListener, isFalse);
    expect(service.stderr.hasListener, isFalse);
    expect(service.requests, <String>['Debug', 'Stdout', 'Stderr']);
  });

  testWithoutContext('dispose during stream setup does not register more streams', () async {
    service.onListen = (_) => reader.dispose();
    await reader.provideVmService(connection);
    expect(service.requests, <String>['Debug']);
    expect(service.stdout.hasListener, isFalse);
    expect(service.stderr.hasListener, isFalse);
  });
}

vm_service.Event output(String text, {String isolateId = 'isolates/1'}) => vm_service.Event(
  kind: 'WriteEvent',
  timestamp: 0,
  bytes: base64Encode(utf8.encode(text)),
  isolate: vm_service.IsolateRef(id: isolateId, number: '1', name: 'main'),
);

class TestVmService extends Fake implements vm_service.VmService {
  final stdout = StreamController<vm_service.Event>.broadcast(sync: true);
  final stderr = StreamController<vm_service.Event>.broadcast(sync: true);
  final requests = <String>[];
  final errors = <String, int>{};
  void Function(String)? onListen;

  @override
  Stream<vm_service.Event> get onStdoutEvent => stdout.stream;

  @override
  Stream<vm_service.Event> get onStderrEvent => stderr.stream;

  @override
  Future<vm_service.Success> streamListen(String streamId) async {
    requests.add(streamId);
    onListen?.call(streamId);
    if (errors[streamId] case final int code) {
      throw vm_service.RPCError('streamListen', code, 'stream unavailable');
    }
    return vm_service.Success();
  }

  Future<void> close() async {
    await stdout.close();
    await stderr.close();
  }
}
