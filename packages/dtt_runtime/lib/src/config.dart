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

import 'dart:async';

import 'package:google_cloud_events/google_cloud_events.dart';
import 'package:protobuf/protobuf.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart';

import 'cloudevent.dart';
import 'router.dart';

part 'triggers.g.dart';

/// A handler for CloudEvents whose payload is [T].
typedef EventHandler<T extends GeneratedMessage> =
    FutureOr<void> Function(CloudEvent<T> event);

/// Typed replacement for `dtt.yaml`, declared as `dttConfig` in a package's
/// `lib/dtt_config.dart`.
final class DttConfig {
  const DttConfig({required this.service, required this.triggers});

  final Service service;
  final List<Trigger<GeneratedMessage>> triggers;

  /// The config in the `dtt.yaml` shape, which `dtt generate` reads.
  Map<String, Object?> toJson() => {
    'service': service.toJson(),
    'triggers': [for (final trigger in triggers) trigger.toJson()],
  };
}

/// The Cloud Run workload that receives the triggers' events.
final class Service {
  const Service({
    required this.name,
    required this.projectId,
    this.region = 'us-central1',
    this.kind = ServiceKind.service,
    this.securityProfile = SecurityProfile.standard,
    this.labels = const {},
  });

  final String name;
  final String projectId;
  final String region;
  final ServiceKind kind;
  final SecurityProfile securityProfile;
  final Map<String, String> labels;

  Map<String, Object?> toJson() => {
    'name': name,
    'project_id': projectId,
    'region': region,
    'kind': kind.name,
    'security_profile': securityProfile.yamlName,
    if (labels.isNotEmpty) 'labels': labels,
  };
}

enum ServiceKind { service, job }

enum SecurityProfile {
  standard('default'),
  secure('secure');

  const SecurityProfile(this.yamlName);

  final String yamlName;
}

/// Eventarc delivery retries. Eventarc accepts only `maxAttempts: 1`, which
/// disables retries, and only for [ServiceKind.service].
final class RetryPolicy {
  const RetryPolicy({required this.maxAttempts});

  final int maxAttempts;

  Map<String, Object?> toJson() => {'max_attempts': maxAttempts};
}

extension on Trigger<GeneratedMessage> {
  Map<String, Object?> toJson() => {
    'name': name,
    'type': event.eventType,
    'path': path ?? event.defaultPath,
    ...filters,
    'dead_letter_topic': ?deadLetterTopic,
    if (retryPolicy case final policy?) 'retry_policy': policy.toJson(),
  };
}
