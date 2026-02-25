import 'dart:io';

const supportsIoPlatform = true;

String? environmentValue(String key) => Platform.environment[key];
