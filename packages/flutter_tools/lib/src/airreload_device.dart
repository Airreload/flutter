// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:vm_service/vm_service.dart' as vm_service;

import 'application_package.dart';
import 'base/logger.dart';
import 'build_info.dart';
import 'convert.dart';
import 'device.dart';
import 'device_port_forwarder.dart';
import 'project.dart';
import 'vmservice.dart';

class AirreloadDevice extends Device {
  AirreloadDevice({required super.logger, this.platform = TargetPlatform.android_arm64})
    : _logger = logger,
      super(
        'airreload',
        category: Category.mobile,
        platformType: PlatformType.android,
        ephemeral: true,
      );

  final Logger _logger;
  final TargetPlatform platform;

  @override
  String get name => 'Airreload ${getNameForTargetPlatform(platform)}';

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode == BuildMode.debug;

  @override
  bool get supportsStartPaused => false;

  @override
  Future<TargetPlatform> get targetPlatform async => platform;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<String?> get emulatorId async => null;

  @override
  Future<String> get sdkNameAndVersion async => 'App-managed TLS tunnel';

  @override
  bool isSupportedForProject(FlutterProject flutterProject) => true;

  @override
  Future<bool> isSupported() async => true;

  @override
  DevicePortForwarder? get portForwarder => null;

  @override
  DeviceLogReader getLogReader({ApplicationPackage? app, bool includePastLogs = false}) =>
      _logReader;

  late final _logReader = AirreloadLogReader(name, logger: _logger);

  @override
  void clearLogs() {}

  @override
  Future<void> dispose() async {
    _logReader.dispose();
    await dds.shutdown();
  }

  /// Hot restart replaces the Dart isolate. Airreload's transport is owned by
  /// the Android process, so the VM-service tunnel survives isolate replacement.
  @override
  bool get supportsHotRestart => true;

  @override
  bool get supportsFlutterExit => false;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app, {String? userIdentifier}) async => true;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => true;

  @override
  Future<bool> installApp(ApplicationPackage app, {String? userIdentifier}) =>
      throw UnsupportedError('Install the debug APK manually.');

  @override
  Future<bool> uninstallApp(ApplicationPackage app, {String? userIdentifier}) =>
      throw UnsupportedError('Airreload is attach-only.');

  @override
  Future<bool> stopApp(ApplicationPackage? app, {String? userIdentifier}) async => false;

  @override
  Future<LaunchResult> startApp(
    ApplicationPackage? package, {
    String? mainPath,
    String? route,
    required DebuggingOptions debuggingOptions,
    Map<String, Object?> platformArgs = const {},
    bool prebuiltApplication = false,
    String? userIdentifier,
  }) => throw UnsupportedError('Airreload is attach-only; open the debug app on the device.');
}

/// Streams Dart output over the app's existing VM-service connection.
class AirreloadLogReader extends DeviceLogReader {
  AirreloadLogReader(this.name, {required Logger logger}) : _logger = logger;

  @override
  final String name;
  final Logger _logger;
  final _lines = StreamController<String>.broadcast();
  final _subscriptions = <StreamSubscription<vm_service.Event>>[];
  FlutterVmService? _connectedService;
  var _generation = 0;
  var _disposed = false;

  @override
  Stream<String> get logLines => _lines.stream;

  @override
  Future<void> provideVmService(FlutterVmService connectedVmService) async {
    if (_disposed || identical(_connectedService, connectedVmService)) {
      return;
    }
    _connectedService = connectedVmService;
    final int generation = ++_generation;
    final oldSubscriptions = List<StreamSubscription<vm_service.Event>>.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(oldSubscriptions.map((subscription) => subscription.cancel()));
    if (_disposed || generation != _generation) {
      return;
    }

    void onOutput(vm_service.Event event) {
      if (_disposed || generation != _generation || event.bytes == null || event.bytes!.isEmpty) {
        return;
      }
      try {
        final String message = const Utf8Codec(
          reportErrors: false,
        ).decode(base64.decode(event.bytes!));
        // The VM appends a newline. The terminal logger adds its own.
        _lines.add(message.endsWith('\n') ? message.substring(0, message.length - 1) : message);
      } on FormatException {
        _logger.printTrace('Ignoring malformed Airreload log event.');
      }
    }

    final vm_service.VmService service = connectedVmService.service;
    // Register listeners before requesting streams so early output is retained.
    // These streams belong to the VM, so isolate replacement needs no resubscription.
    _subscriptions.addAll(<StreamSubscription<vm_service.Event>>[
      service.onStdoutEvent.listen(onOutput),
      service.onStderrEvent.listen(onOutput),
    ]);
    for (final stream in <String>[
      vm_service.EventStreams.kDebug,
      vm_service.EventStreams.kStdout,
      vm_service.EventStreams.kStderr,
    ]) {
      if (_disposed || generation != _generation) {
        return;
      }
      try {
        // Listening to Debug also enables VM output events on Flutter engines.
        await service.streamListen(stream);
      } on vm_service.RPCError catch (error) {
        if (error.code != vm_service.RPCErrorKind.kStreamAlreadySubscribed.code) {
          _logger.printWarning('Unable to stream Airreload $stream logs: ${error.message}');
        }
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _connectedService = null;
    for (final StreamSubscription<vm_service.Event> subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    // Do not streamCancel: Flutter tooling shares this VM-service client.
    unawaited(_lines.close());
  }
}
