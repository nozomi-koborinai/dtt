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

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dart_config.dart';

part 'trigger_config.g.dart';

/// Mapping metadata tracking trigger types, import URIs, and class definitions.
final class TriggerTypeMeta {
  final String importPath;
  final String className;
  final String enumName;
  final String defaultPath;
  final bool isGlobal;
  final String? triggerLocation;
  final String? eventDataContentType;

  const TriggerTypeMeta._({
    required this.importPath,
    required this.className,
    required this.enumName,
    required this.defaultPath,
    this.isGlobal = false,
    this.triggerLocation,
    this.eventDataContentType,
  });
}

/// Strongly typed representation of a declared Eventarc trigger.
base class TriggerConfig {
  const TriggerConfig._({
    required this.name,
    required this.type,
    required this.path,
    required this.handler,
    this.resourceRef,
    this.deadLetterTopic,
    this.retryPolicy,
  });

  final String name;
  final TriggerType type;
  final String path;

  /// The handler function name; `null` when `lib/dtt_config.dart` binds the
  /// handler itself.
  final String? handler;
  final String? resourceRef;
  final String? deadLetterTopic;
  final RetryPolicy? retryPolicy;

  TriggerTypeMeta get meta => type.meta;

  factory TriggerConfig.fromMap(
    Map<Object?, Object?> node, {
    String? defaultHandler,
  }) {
    final paramsNode = node['parameters'] as Map<Object?, Object?>?;
    Object? field(String key) => node[key] ?? paramsNode?[key];

    final name = field('name') as String? ?? 'trigger';
    final typeStr = field('type') as String?;
    final path = field('path') as String? ?? '/events';
    final handler = field('handler') as String? ?? defaultHandler;
    final resourceRef = field('resource_ref') as String?;
    final deadLetterTopic = field('dead_letter_topic') as String?;
    final retryPolicy = switch (field('retry_policy')) {
      null => null,
      {'max_attempts': final int maxAttempts} => RetryPolicy(
        maxAttempts: maxAttempts,
      ),
      final other => throw FormatException(
        'Trigger [$name] retry_policy must be a mapping such as '
        '{max_attempts: 1}, not [$other].',
      ),
    };

    if (typeStr == null) {
      throw const FormatException(
        'Trigger declaration missing required [type] attribute.',
      );
    }

    final type = TriggerType.fromIdentifier(typeStr);
    final bucket = field('bucket') as String?;
    final document = field('document') as String?;
    final database = field('database') as String? ?? '(default)';

    return switch (type) {
      TriggerType.gcsObjectFinalized ||
      TriggerType.gcsObjectDeleted ||
      TriggerType.gcsObjectArchived ||
      TriggerType.gcsObjectMetadataUpdated => StorageTriggerConfig._(
        name: name,
        type: type,
        path: path,
        handler: handler,
        resourceRef: resourceRef,
        deadLetterTopic: deadLetterTopic,
        retryPolicy: retryPolicy,
        bucket:
            bucket ??
            (throw FormatException(
              'Cloud Storage trigger [$name] missing required [bucket] '
              'declaration.',
            )),
      ),
      TriggerType.firestoreDocumentWritten ||
      TriggerType.firestoreDocumentCreated ||
      TriggerType.firestoreDocumentUpdated ||
      TriggerType.firestoreDocumentDeleted => FirestoreTriggerConfig._(
        name: name,
        type: type,
        path: path,
        handler: handler,
        resourceRef: resourceRef,
        deadLetterTopic: deadLetterTopic,
        retryPolicy: retryPolicy,
        document:
            document ??
            (throw FormatException(
              'Firestore trigger [$name] missing required [document] '
              'declaration.',
            )),
        database: database,
      ),
      _ => TriggerConfig._(
        name: name,
        type: type,
        path: path,
        handler: handler,
        resourceRef: resourceRef,
        deadLetterTopic: deadLetterTopic,
        retryPolicy: retryPolicy,
      ),
    };
  }
}

final class StorageTriggerConfig extends TriggerConfig {
  const StorageTriggerConfig._({
    required super.name,
    required super.type,
    required super.path,
    required super.handler,
    super.resourceRef,
    super.deadLetterTopic,
    super.retryPolicy,
    required this.bucket,
  }) : super._();

  final String bucket;
}

final class FirestoreTriggerConfig extends TriggerConfig {
  const FirestoreTriggerConfig._({
    required super.name,
    required super.type,
    required super.path,
    required super.handler,
    super.resourceRef,
    super.deadLetterTopic,
    super.retryPolicy,
    required this.document,
    this.database = '(default)',
  }) : super._();

  final String document;
  final String database;
}

/// Eventarc delivery retries, emitted as the trigger's `retry_policy` block.
final class RetryPolicy {
  const RetryPolicy({required this.maxAttempts});

  final int maxAttempts;
}

enum ServiceKind { service, job }

enum SecurityProfile { standard, secure }

/// Where a package declares its config.
enum ConfigSource {
  /// `dtt.yaml`, whose triggers name their handler functions.
  yaml,

  /// `lib/dtt_config.dart`, whose `dttConfig` binds handlers directly.
  dart,
}

class DttConfig {
  final String serviceName;
  final String projectId;
  final String region;
  final ServiceKind kind;
  final SecurityProfile securityProfile;
  final Map<String, String> labels;
  final List<TriggerConfig> triggers;
  final ConfigSource source;

  DttConfig({
    required this.serviceName,
    required this.projectId,
    required this.region,
    required this.kind,
    required this.securityProfile,
    required this.labels,
    required this.triggers,
    required this.source,
  });

  /// Parses the `dtt.yaml` shape, which `DttConfig.toJson()` in
  /// `package:dtt_runtime` also emits.
  factory DttConfig.fromMap(Map<Object?, Object?> doc, ConfigSource source) {
    final serviceNode = doc['service'] as Map<Object?, Object?>?;
    if (serviceNode == null) {
      throw const FormatException(
        'Config missing mandatory [service] mapping block.',
      );
    }

    final triggersNode = doc['triggers'] as List<Object?>?;
    if (triggersNode == null || triggersNode.isEmpty) {
      throw const FormatException(
        'Config missing [triggers] declarations list.',
      );
    }

    final labelsNode = serviceNode['labels'] as Map<Object?, Object?>?;

    return DttConfig(
      serviceName: serviceNode['name'] as String? ?? 'dtt-service',
      projectId: serviceNode['project_id'] as String? ?? 'gcp-project-id',
      region: serviceNode['region'] as String? ?? 'us-central1',
      kind: switch (serviceNode['kind'] ?? 'service') {
        'service' => ServiceKind.service,
        'job' => ServiceKind.job,
        final other => throw FormatException('Unknown service kind [$other].'),
      },
      securityProfile: switch (serviceNode['security_profile'] ?? 'default') {
        'default' => SecurityProfile.standard,
        'secure' => SecurityProfile.secure,
        final other => throw FormatException(
          'Unknown security_profile [$other].',
        ),
      },
      labels: {
        for (final MapEntry(:key, :value) in (labelsNode ?? const {}).entries)
          key.toString(): value.toString(),
      },
      triggers: [
        for (final node in triggersNode)
          if (node is Map<Object?, Object?>)
            TriggerConfig.fromMap(
              node,
              defaultHandler: source == ConfigSource.yaml ? 'onEvent' : null,
            )
          else
            throw const FormatException(
              'Trigger mappings must specify name, type, path, and handler '
              'callbacks.',
            ),
      ],
      source: source,
    );
  }

  /// Loads `lib/dtt_config.dart` when present, otherwise `dtt.yaml`.
  static Future<DttConfig> load(String packageDir) async {
    if (await File(p.join(packageDir, dartConfigPath)).exists()) {
      return DttConfig.fromMap(
        await evaluateDartConfig(packageDir),
        ConfigSource.dart,
      );
    }

    final configFile = File(p.join(packageDir, 'dtt.yaml'));
    if (!await configFile.exists()) {
      throw FileSystemException(
        'Neither $dartConfigPath nor dtt.yaml found inside package folder.',
        configFile.path,
      );
    }

    final doc = loadYaml(await configFile.readAsString()) as YamlMap;
    return DttConfig.fromMap(doc, ConfigSource.yaml);
  }
}

String toSnakeCase(String input) => input
    .replaceAllMapped(
      RegExp(r'(.)([A-Z])'),
      (Match match) => '${match.group(1)}_${match.group(2)}',
    )
    .replaceAll('-', '_')
    .toLowerCase();
