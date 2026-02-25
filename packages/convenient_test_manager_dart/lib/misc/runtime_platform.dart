import 'package:convenient_test_manager_dart/misc/runtime_platform_stub.dart'
    if (dart.library.io)
        'package:convenient_test_manager_dart/misc/runtime_platform_io.dart'
    as impl;

bool get supportsIoPlatform => impl.supportsIoPlatform;

String? environmentValue(String key) => impl.environmentValue(key);
