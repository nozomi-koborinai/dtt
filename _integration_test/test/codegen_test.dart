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

import 'package:checks/checks.dart';
import 'package:dtt/src/codegen/generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

/// Generates [packageName] inside the sandbox and returns its
/// `terraform/main.tf.json`.
Future<Map<String, dynamic>> _generate(String packageName) async {
  final workspacePath = d.sandbox;
  await generateProject(
    workspaceRoot: workspacePath,
    packageDir: p.join(workspacePath, packageName),
  );
  final tfFile = File(p.join(workspacePath, 'terraform', 'main.tf.json'));
  return jsonDecode(await tfFile.readAsString()) as Map<String, dynamic>;
}

Map<String, dynamic> _block(
  Map<String, dynamic> tf,
  String type,
  String name, {
  String kind = 'resource',
}) =>
    ((tf[kind] as Map<String, dynamic>)[type] as Map<String, dynamic>)[name]
        as Map<String, dynamic>;

List<Object?> _criteria(Map<String, dynamic> trigger) => [
  for (final c in trigger['matching_criteria'] as List<dynamic>)
    ((c as Map<String, dynamic>)['attribute'], c['value']),
];

Future<String> _server(String packageName) =>
    File(p.join(d.sandbox, packageName, 'bin', 'server.dart')).readAsString();

void main() {
  group('DttGenerator Codebase and Manifests Orchestration Tests', () {
    test('Natively parses dtt.yaml and synthesizes all E2E assets', () async {
      await d.dir('my_package', [
        d.file('dtt.yaml', '''
service:
  name: firebase-auth-triggers
  project_id: n26-full-stack-dart
  region: us-central1

triggers:
  - name: auth-user-created
    type: google.firebase.auth.user.v2.created
    path: /events/auth
    handler: onUserCreated
'''),
      ]).create();

      final tf = await _generate('my_package');

      final serverContent = await _server('my_package');
      check(serverContent).contains(
        "import 'package:google_cloud_events/google_cloud_events.dart';",
      );
      check(serverContent).contains(
        "import 'package:my_package/src/handlers/on_user_created.dart';",
      );
      check(serverContent).contains('void main() async {');
      check(serverContent).contains('await serveHandler(pipeline);');

      for (final legacy in ['main.tf', 'variables.tf', 'outputs.tf']) {
        check(
          File(p.join(d.sandbox, 'terraform', legacy)).existsSync(),
        ).isFalse();
      }

      check(
        (tf['data'] as Map<String, dynamic>).keys,
      ).contains('google_project');
      check(
        _block(tf, 'google_service_account', 'eventarc_invoker'),
      ).containsKey('account_id');
      check(
        _block(tf, 'google_cloud_run_v2_service_iam_member', 'invoker_role'),
      )['name'].equals(r'${google_cloud_run_v2_service.service.name}');

      final trigger = _block(
        tf,
        'google_eventarc_trigger',
        'trigger_auth_user_created',
      );
      check(trigger['provider']).equals('google-beta');
      check(trigger['location']).equals('global');
      check(trigger['destination']).isA<Map<String, dynamic>>().deepEquals({
        'cloud_run_service': {
          'path': '/events/auth',
          'region': r'${var.region}',
          'service': r'${google_cloud_run_v2_service.service.name}',
        },
      });
      check(
        _criteria(trigger),
      ).deepEquals([('type', 'google.firebase.auth.user.v2.created')]);
      check(
        ((tf['terraform'] as Map<String, dynamic>)['required_providers']
                as Map<String, dynamic>)
            .keys,
      ).unorderedEquals(['google', 'google-beta']);
      check(
        (tf['resource'] as Map<String, dynamic>).keys,
      ).not((c) => c.contains('null_resource'));

      final variables = tf['variable'] as Map<String, dynamic>;
      check(
        (variables['project_id'] as Map<String, dynamic>)['default'],
      ).equals('n26-full-stack-dart');
      check(variables.keys).contains('container_image');

      check(
        ((tf['output'] as Map<String, dynamic>)['service_url']
            as Map<String, dynamic>)['value'],
      ).equals(r'${google_cloud_run_v2_service.service.uri}');
    });

    test(
      'Custom Path Override generates path argument in server.dart',
      () async {
        await d.dir('custom_package', [
          d.file('dtt.yaml', '''
service:
  name: firebase-auth-triggers
  project_id: n26-full-stack-dart
  region: us-central1

triggers:
  - name: auth-user-created
    type: google.firebase.auth.user.v2.created
    path: /events/my-custom-endpoint
    handler: onUserCreated
'''),
        ]).create();

        await _generate('custom_package');

        final serverContent = await _server('custom_package');
        check(
          serverContent,
        ).contains('CloudEventTrigger.firebaseAuthUserCreated');
        check(serverContent).contains("path: '/events/my-custom-endpoint'");
        check(serverContent).contains('handler: onUserCreated');
      },
    );

    test(
      'Cloud Firestore trigger generates dynamic database and document filters',
      () async {
        await d.dir('firestore_package', [
          d.file('dtt.yaml', '''
service:
  name: firestore-triggers
  project_id: n26-full-stack-dart
  region: us-central1

triggers:
  - name: user-written
    type: google.cloud.firestore.document.v1.written
    path: /events/users
    handler: onUserWritten
    database: "(default)"
    document: "documents/users/{userId}"
'''),
        ]).create();

        final tf = await _generate('firestore_package');

        final serverContent = await _server('firestore_package');
        check(
          serverContent,
        ).contains('CloudEventTrigger.firestoreDocumentWritten');
        check(serverContent).contains("path: '/events/users'");
        check(serverContent).contains('handler: onUserWritten');

        final trigger = _block(
          tf,
          'google_eventarc_trigger',
          'trigger_user_written',
        );
        check(_criteria(trigger)).deepEquals([
          ('type', 'google.cloud.firestore.document.v1.written'),
          ('database', '(default)'),
          ('document', 'documents/users/{userId}'),
        ]);
        check(
          trigger['event_data_content_type'],
        ).equals('application/protobuf');
        check(
          _block(
            tf,
            'google_pubsub_topic_iam_member',
            'firestore_pubsub_publisher',
          ),
        )['topic'].equals(r'${google_pubsub_topic.firestore_topic.id}');

        final audit = _block(
          tf,
          'google_project_iam_audit_config',
          'firestore_audit',
        );
        check(audit['service']).equals('firestore.googleapis.com');
        check(audit['audit_log_config']).isA<List<dynamic>>().deepEquals([
          {'log_type': 'DATA_WRITE'},
          {'log_type': 'DATA_READ'},
        ]);
      },
    );

    test('Custom labels in dtt.yaml label every labelable resource', () async {
      await d.dir('label_package', [
        d.file('dtt.yaml', '''
service:
  name: label-triggers
  project_id: label-proj
  region: us-central1
  labels:
    env: staging
    team: backend

triggers:
  - name: my-upload
    type: google.cloud.storage.object.v1.finalized
    bucket: my-upload-bucket
    path: /events/uploads
    handler: onUpload
'''),
      ]).create();

      final tf = await _generate('label_package');

      const expected = {
        'managed_by': 'dart_terraform_triggers',
        'env': 'staging',
        'team': 'backend',
      };
      for (final (type, name) in [
        ('google_cloud_run_v2_service', 'service'),
        ('google_pubsub_topic', 'storage_topic'),
        ('google_eventarc_trigger', 'trigger_my_upload'),
      ]) {
        check(
          _block(tf, type, name)['labels'],
        ).isA<Map<String, dynamic>>().deepEquals(expected);
      }
    });

    test(
      'Expanded catalog GCS deleted and Firestore created generate',
      () async {
        await d.dir('expanded_package', [
          d.file('dtt.yaml', '''
service:
  name: expanded-triggers
  project_id: expanded-proj
  region: us-central1

triggers:
  - name: on-gcs-del
    type: google.cloud.storage.object.v1.deleted
    bucket: del-bucket
    path: /events/del
    handler: onDel
  - name: on-fs-create
    type: google.cloud.firestore.document.v1.created
    document: items/{id}
    path: /events/create
    handler: onCreate
'''),
        ]).create();

        final tf = await _generate('expanded_package');

        final serverContent = await _server('expanded_package');
        check(serverContent).contains('CloudEventTrigger.gcsObjectDeleted');
        check(
          serverContent,
        ).contains('CloudEventTrigger.firestoreDocumentCreated');

        check(
          _criteria(
            _block(tf, 'google_eventarc_trigger', 'trigger_on_gcs_del'),
          ),
        ).contains(('type', 'google.cloud.storage.object.v1.deleted'));
        check(
          _criteria(
            _block(tf, 'google_eventarc_trigger', 'trigger_on_fs_create'),
          ),
        ).contains(('type', 'google.cloud.firestore.document.v1.created'));
      },
    );

    test(
      'security_profile: secure runs one service as a role-less identity',
      () async {
        await d.dir('secure_package', [
          d.file('dtt.yaml', '''
service:
  name: secure-service
  project_id: secure-proj
  region: us-central1
  security_profile: secure

triggers:
  - name: on-gcs
    type: google.cloud.storage.object.v1.finalized
    bucket: sec-bucket
    path: /events/sec
    handler: onSec
'''),
        ]).create();

        final tf = await _generate('secure_package');

        check(tf).not((c) => c.containsKey('module'));
        check(
          (tf['resource']
                  as Map<String, dynamic>)['google_cloud_run_v2_service']
              as Map<String, dynamic>,
        ).has((s) => s.keys, 'keys').deepEquals(['service']);
        final template =
            _block(tf, 'google_cloud_run_v2_service', 'service')['template']
                as Map<String, dynamic>;
        check(
          template['service_account'],
        ).equals(r'${google_service_account.runtime.email}');
        check(
          _block(tf, 'google_service_account', 'runtime')['account_id'],
        ).equals('dtt-secure-service-run');
      },
    );

    test(
      'Cloud Run Integrations parameters mapping export schema parsing',
      () async {
        await d.dir('integrations_package', [
          d.file('dtt.yaml', '''
service:
  name: integration-service
  project_id: int-proj
  region: us-central1

triggers:
  - name: export-trigger
    parameters:
      type: google.cloud.storage.object.v1.finalized
      bucket: export-bucket
      path: /events/export
      handler: onExport
'''),
        ]).create();

        final tf = await _generate('integrations_package');

        check(
          _criteria(
            _block(tf, 'google_eventarc_trigger', 'trigger_export_trigger'),
          ),
        ).deepEquals([
          ('type', 'google.cloud.storage.object.v1.finalized'),
          ('bucket', 'export-bucket'),
        ]);
      },
    );

    test('kind: job runs the job from a workflow per trigger', () async {
      await d.dir('job_package', [
        d.file('dtt.yaml', '''
service:
  name: batch-job
  kind: job
  project_id: job-proj
  region: us-central1

triggers:
  - name: on-gcs-job
    type: google.cloud.storage.object.v1.finalized
    bucket: job-bucket
    path: /events/job
    handler: onJob
'''),
      ]).create();

      final tf = await _generate('job_package');
      final resources = tf['resource'] as Map<String, dynamic>;

      check(
        resources.keys,
      ).not((c) => c.contains('google_cloud_run_v2_service'));
      final job = _block(tf, 'google_cloud_run_v2_job', 'job');
      check(job['template']).isA<Map<String, dynamic>>().deepEquals({
        'template': {
          'containers': [
            {'image': r'${var.container_image}'},
          ],
        },
      });

      final workflow = _block(
        tf,
        'google_workflows_workflow',
        'dispatch_on_gcs_job',
      );
      check(workflow['source_contents']).isA<String>()
        ..contains('googleapis.run.v2.projects.locations.jobs.run')
        ..contains(r'name: ${google_cloud_run_v2_job.job.id}')
        ..contains(r'$${json.encode_to_string(event)}');
      check(
        _block(
          tf,
          'google_eventarc_trigger',
          'trigger_on_gcs_job',
        )['destination'],
      ).isA<Map<String, dynamic>>().deepEquals({
        'workflow': r'${google_workflows_workflow.dispatch_on_gcs_job.id}',
      });
      check(
        (tf['output'] as Map<String, dynamic>).keys,
      ).unorderedEquals(['job_name', 'eventarc_trigger_ids']);

      final serverContent = await _server('job_package');
      check(serverContent)
        ..contains("env['DTT_CLOUD_EVENT']")
        ..not((c) => c.contains('serveHandler'));
    });

    test(
      'dead_letter_topic and retry_policy generate Eventarc resiliency blocks',
      () async {
        await d.dir('resiliency_package', [
          d.file('dtt.yaml', '''
service:
  name: resilient-service
  project_id: res-proj
  region: us-central1

triggers:
  - name: on-resilient-event
    type: google.cloud.storage.object.v1.finalized
    bucket: res-bucket
    path: /events/res
    handler: onRes
    dead_letter_topic: projects/res-proj/topics/my-dlq-topic
    retry_policy:
      max_attempts: 1
'''),
        ]).create();

        final tf = await _generate('resiliency_package');

        final trigger = _block(
          tf,
          'google_eventarc_trigger',
          'trigger_on_resilient_event',
        );
        check(trigger['transport']).isA<Map<String, dynamic>>().deepEquals({
          'pubsub': {'topic': 'projects/res-proj/topics/my-dlq-topic'},
        });
        check(
          trigger['retry_policy'],
        ).isA<Map<String, dynamic>>().deepEquals({'max_attempts': 1});
      },
    );

    test('retry_policy as a bare string is rejected', () async {
      await d.dir('legacy_retry_package', [
        d.file('dtt.yaml', '''
service:
  name: legacy-retry
  project_id: res-proj

triggers:
  - name: on-event
    type: google.cloud.storage.object.v1.finalized
    bucket: res-bucket
    handler: onRes
    retry_policy: RETRY_POLICY_RETRY
'''),
      ]).create();

      await check(_generate('legacy_retry_package')).throws<FormatException>();
    });

    test('lib/dtt_config.dart drives server.dart and main.tf.json', () async {
      var rootDir = Directory.current.path;
      if (rootDir.endsWith('_integration_test')) {
        rootDir = p.canonicalize(p.join(rootDir, '..'));
      }
      final exampleDir = p.join(rootDir, 'examples', 'firebase_auth_example');

      await generateProject(workspaceRoot: d.sandbox, packageDir: exampleDir);

      final serverContent = await File(
        p.join(exampleDir, 'bin', 'server.dart'),
      ).readAsString();
      check(serverContent)
        ..contains("import 'package:firebase_auth_example/dtt_config.dart';")
        ..contains('trigger.register(router);');

      final tf =
          jsonDecode(
                await File(
                  p.join(d.sandbox, 'terraform', 'main.tf.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      check(
        _criteria(_block(tf, 'google_eventarc_trigger', 'trigger_on_upload')),
      ).deepEquals([
        ('type', 'google.cloud.storage.object.v1.finalized'),
        ('bucket', 'dtt-pkg-test-upload'),
      ]);
    });

    test('dtt dev warns on invalid JSON payload fixture', () async {
      var rootDir = Directory.current.path;
      if (rootDir.endsWith('_integration_test')) {
        rootDir = p.canonicalize(p.join(rootDir, '..'));
      }
      final exampleDir = p.join(rootDir, 'examples', 'firebase_auth_example');

      final res = await Process.run(Platform.resolvedExecutable, [
        'run',
        'packages/dtt/bin/dtt.dart',
        'dev',
        '--package-dir=$exampleDir',
        '--emit-event=google.cloud.storage.object.v1.finalized',
        '--payload={not-valid-json',
      ], workingDirectory: rootDir);

      final output = '${res.stdout}\n${res.stderr}';
      check(output).contains('Warning: Invalid JSON payload supplied');
    });
  });
}
