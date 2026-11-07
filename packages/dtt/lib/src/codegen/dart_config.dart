// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../util/dart_sdk.dart';

/// Package-relative path of the typed config, which declares `dttConfig`.
const dartConfigPath = 'lib/dtt_config.dart';

/// Runs the package's `dttConfig` and returns its `toJson()` map.
///
/// The config holds handler tear-offs, so it only exists inside a Dart
/// process that imports the package; a small generated runner provides one.
Future<Map<String, Object?>> evaluateDartConfig(String packageDir) async {
  final pubspec =
      loadYaml(await File(p.join(packageDir, 'pubspec.yaml')).readAsString())
          as YamlMap;
  final packageName = pubspec['name'] as String;

  final runnerDir = Directory(p.join(packageDir, '.dart_tool', 'dtt'));
  await runnerDir.create(recursive: true);
  final runner = File(p.join(runnerDir.path, 'config_runner.dart'));
  final output = File(p.join(runnerDir.path, 'config.json'));
  await runner.writeAsString('''
// This is an auto-generated file - DO NOT EDIT.
import 'dart:convert';
import 'dart:io';

import 'package:$packageName/dtt_config.dart';

void main(List<String> args) =>
    File(args.single).writeAsStringSync(jsonEncode(dttConfig.toJson()));
''');

  final result = await Process.run(resolveDartExecutable(), [
    'run',
    runner.path,
    output.path,
  ], workingDirectory: packageDir);
  if (result.exitCode != 0) {
    throw ProcessException(
      resolveDartExecutable(),
      ['run', runner.path],
      'Evaluating $dartConfigPath failed:\n${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
  return jsonDecode(await output.readAsString()) as Map<String, Object?>;
}
