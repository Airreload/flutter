// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/airreload_device.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/dds.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:test/fake.dart';

import '../src/common.dart';

void main() {
  for (final platform in <TargetPlatform>[
    TargetPlatform.android_arm,
    TargetPlatform.android_arm64,
    TargetPlatform.android_x64,
  ]) {
    testWithoutContext('reports the selected architecture $platform', () async {
      final device = AirreloadDevice(logger: BufferLogger.test(), platform: platform);
      expect(await device.targetPlatform, platform);
      expect(device.supportsHotReload, isTrue);
      expect(device.supportsHotRestart, isTrue);
    });
  }

  testWithoutContext(
    'supports only Android ARM64 debug attach, hot reload, and hot restart',
    () async {
      final device = AirreloadDevice(logger: BufferLogger.test());
      expect(await device.targetPlatform, TargetPlatform.android_arm64);
      expect(device.supportsRuntimeMode(BuildMode.debug), isTrue);
      expect(device.supportsRuntimeMode(BuildMode.profile), isFalse);
      expect(device.supportsRuntimeMode(BuildMode.release), isFalse);
      expect(device.supportsHotReload, isTrue);
      expect(device.supportsHotRestart, isTrue);
      expect(device.supportsFlutterExit, isFalse);
      expect(device.supportsStartPaused, isFalse);
      expect(device.portForwarder, isNull);
      expect(device.getLogReader(), isA<NoOpDeviceLogReader>());
    },
  );

  testWithoutContext('does not install, launch, uninstall, or stop an app', () async {
    final device = AirreloadDevice(logger: BufferLogger.test());
    final app = FakeApplicationPackage();
    expect(() => device.installApp(app), throwsUnsupportedError);
    expect(() => device.uninstallApp(app), throwsUnsupportedError);
    expect(
      () => device.startApp(app, debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug)),
      throwsUnsupportedError,
    );
    expect(await device.stopApp(app), isFalse);
  });

  testWithoutContext('dispose shuts down DDS using the synchronous API', () async {
    final dds = PendingDartDevelopmentService();
    final device = TestAirreloadDevice(dds);
    await device.dispose();
    expect(dds.shutdownCalled, isTrue);
  });
}

class FakeApplicationPackage extends Fake implements ApplicationPackage {}

class PendingDartDevelopmentService extends Fake implements DartDevelopmentService {
  bool shutdownCalled = false;

  @override
  void shutdown() {
    shutdownCalled = true;
  }
}

class TestAirreloadDevice extends AirreloadDevice {
  TestAirreloadDevice(this._dds) : super(logger: BufferLogger.test());

  final DartDevelopmentService _dds;

  @override
  DartDevelopmentService get dds => _dds;
}
