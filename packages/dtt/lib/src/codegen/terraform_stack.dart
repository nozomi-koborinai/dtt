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

import 'package:terradart_google/cloud_run.dart';
import 'package:terradart_google/data.dart';
import 'package:terradart_google/eventarc.dart';
import 'package:terradart_google/google_beta.dart';
import 'package:terradart_google/iam.dart';
import 'package:terradart_google/provider.dart';
import 'package:terradart_google/pubsub.dart';
import 'package:terradart_google/workflows.dart';

import 'trigger_config.dart';

/// Environment variables a `kind: job` execution reads its event from.
const jobEventPathEnv = 'DTT_EVENT_PATH';
const jobCloudEventEnv = 'DTT_CLOUD_EVENT';

/// The GCP infrastructure for one dtt service, synthesized to
/// `terraform/main.tf.json`.
final class DttStack extends Stack {
  DttStack(DttConfig config) : super(providers: _providers(config)) {
    final projectId = variable<String>(
      'project_id',
      description: 'Target Google Cloud Platform Project ID.',
      defaultValue: config.projectId,
    );
    final region = variable<String>(
      'region',
      description: 'Target GCP region for resources deployment.',
      defaultValue: config.region,
    );
    final image = variable<String>(
      'container_image',
      description:
          'Target Docker/Artifact Registry container image URL or digest.',
    );
    final labels = TfArg.literal({
      'managed_by': 'dart_terraform_triggers',
      ...config.labels,
    });
    final name = config.serviceName;
    final saSuffix = name.length > 15 ? name.substring(0, 15) : name;

    final project = add(DataGoogleProject('project'));
    final invoker = add(
      GoogleServiceAccount(
        'eventarc_invoker',
        accountId: .literal('dtt-$saSuffix-inv'),
        displayName: .literal('Eventarc $name Invoker Service Account'),
      ),
    );
    final invokerMember = _serviceAccountMember(invoker);
    final runtime = switch (config.securityProfile) {
      SecurityProfile.standard => null,
      SecurityProfile.secure => add(
        GoogleServiceAccount(
          'runtime',
          accountId: .literal('dtt-$saSuffix-run'),
          displayName: .literal('$name runtime identity without project roles'),
        ),
      ),
    };

    final EventarcTriggerDestination Function(TriggerConfig) destination;
    switch (config.kind) {
      case ServiceKind.service:
        final service = add(
          GoogleCloudRunV2Service(
            'service',
            name: .literal(name),
            location: region,
            ingress: Ingress.internalOnly,
            deletionProtection: const .literal(false),
            labels: labels,
            template: CloudRunV2ServiceTemplate(
              serviceAccount: runtime?.ref,
              containers: [
                CloudRunV2ServiceContainers(
                  image: image,
                  ports: const CloudRunV2ServicePorts(
                    containerPort: .literal(8080),
                  ),
                ),
              ],
            ),
          ),
        );
        add(
          GoogleCloudRunV2ServiceIamMember(
            'invoker_role',
            service: service.ref,
            location: service.location,
            role: const .literal('roles/run.invoker'),
            member: invokerMember,
          ),
        );
        addOutput(
          'service_url',
          service.uri,
          description:
              'URL of our deployed serverless Dart Cloud Run service '
              'container.',
        );
        destination = (trigger) => EventarcTriggerDestination(
          cloudRunService: EventarcTriggerCloudRunService(
            service: service.name,
            region: region,
            path: .literal(trigger.path),
          ),
        );
      case ServiceKind.job:
        final job = add(
          GoogleCloudRunV2Job(
            'job',
            name: .literal(name),
            location: region,
            deletionProtection: const .literal(false),
            labels: labels,
            template: CloudRunV2JobTemplate(
              template: CloudRunV2JobTemplateTemplate(
                serviceAccount: runtime?.ref,
                containers: [CloudRunV2JobContainers(image: image)],
              ),
            ),
          ),
        );
        add(
          GoogleCloudRunV2JobIamMember(
            'job_runner',
            job: job.ref,
            location: job.location,
            role: const .literal('roles/run.developer'),
            member: invokerMember,
          ),
        );
        add(
          GoogleProjectIamMember(
            'workflows_invoker',
            project: projectId,
            role: const .literal('roles/workflows.invoker'),
            member: invokerMember,
          ),
        );
        addOutput(
          'job_name',
          job.name,
          description: 'Name of the Cloud Run job each event executes.',
        );
        destination = (trigger) {
          final workflow = add(
            GoogleWorkflowsWorkflow(
              'dispatch_${toSnakeCase(trigger.name)}',
              name: .literal('$name-${trigger.name}'),
              region: region,
              serviceAccount: invoker.ref,
              labels: labels,
              sourceContents: TfArg.expression(
                _runJobWorkflow(job, trigger.path),
              ),
            ),
          );
          return EventarcTriggerDestination(workflow: workflow.id);
        };
    }

    add(
      GoogleProjectIamMember(
        'eventarc_receiver',
        project: projectId,
        role: const .literal('roles/eventarc.eventReceiver'),
        member: invokerMember,
      ),
    );

    if (config.triggers.any((t) => t is FirestoreTriggerConfig)) {
      final topic = add(
        GooglePubsubTopic(
          'firestore_topic',
          name: .literal('$name-firestore-topic'),
          labels: labels,
        ),
      );
      add(
        GooglePubsubTopicIamMember(
          'firestore_pubsub_publisher',
          topic: topic.ref,
          role: const .literal('roles/pubsub.publisher'),
          member: _serviceAgent(project, 'gcp-sa-firestore'),
        ),
      );
      add(
        GoogleProjectIamAuditConfig(
          'firestore_audit',
          project: projectId,
          service: const .literal('firestore.googleapis.com'),
          auditLogConfig: const [
            ProjectIamAuditConfigAuditLogConfig(
              logType: ProjectIamAuditConfigAuditLogConfigLogType.dataWrite,
            ),
            ProjectIamAuditConfigAuditLogConfig(
              logType: ProjectIamAuditConfigAuditLogConfigLogType.dataRead,
            ),
          ],
        ),
      );
    }

    if (config.triggers.any((t) => t is StorageTriggerConfig)) {
      final gcsAccount = add(
        DataGoogleStorageProjectServiceAccount('gcs_account'),
      );
      final topic = add(
        GooglePubsubTopic(
          'storage_topic',
          name: .literal('$name-storage-topic'),
          labels: labels,
        ),
      );
      add(
        GooglePubsubTopicIamMember(
          'storage_pubsub_publisher',
          topic: topic.ref,
          role: const .literal('roles/pubsub.publisher'),
          member: .arg(
            TfArg.expression(
              'serviceAccount:${gcsAccount.emailAddress.toTfJson()}',
            ),
          ),
        ),
      );
    }

    add(
      GoogleServiceAccountIamMember(
        'pubsub_token_creator',
        serviceAccount: invoker.ref,
        role: const .literal('roles/iam.serviceAccountTokenCreator'),
        member: _serviceAgent(project, 'gcp-sa-pubsub'),
      ),
    );
    add(
      GoogleServiceAccountIamMember(
        'eventarc_sa_user',
        serviceAccount: invoker.ref,
        role: const .literal('roles/iam.serviceAccountUser'),
        member: _serviceAgent(project, 'gcp-sa-eventarc'),
      ),
    );

    final beta = providers.whereType<GoogleBetaProvider>().firstOrNull;
    final triggers = [
      for (final trigger in config.triggers)
        add(
          GoogleEventarcTrigger(
            'trigger_${toSnakeCase(trigger.name)}',
            name: .literal('$name-${trigger.name}-trigger'),
            location: switch (trigger.meta.triggerLocation) {
              final location? => .literal(location),
              null => region,
            },
            provider: trigger.meta.isGlobal ? beta : null,
            eventDataContentType: switch (trigger.meta.eventDataContentType) {
              final contentType? => .literal(contentType),
              null => null,
            },
            serviceAccount: invoker.ref,
            labels: labels,
            destination: destination(trigger),
            matchingCriteria: [
              for (final (attribute, value) in _filters(trigger))
                EventarcTriggerMatchingCriteria(
                  attribute: .literal(attribute),
                  value: .literal(value),
                ),
            ],
            transport: switch (trigger.deadLetterTopic) {
              final topic? => EventarcTriggerTransport(
                pubsub: EventarcTriggerPubsub(topic: .literal(topic)),
              ),
              null => null,
            },
            retryPolicy: switch (trigger.retryPolicy) {
              final policy? => EventarcTriggerRetryPolicy(
                maxAttempts: .literal(policy.maxAttempts),
              ),
              null => null,
            },
          ),
        ),
    ];
    addOutput(
      'eventarc_trigger_ids',
      TfArg.literal([for (final trigger in triggers) trigger.id]),
      description: 'Resource identifiers tracking active Eventarc triggers.',
    );
  }

  static List<StackProvider> _providers(DttConfig config) => [
    const GoogleProvider(
      project: r'${var.project_id}',
      region: r'${var.region}',
    ),
    if (config.triggers.any((t) => t.meta.isGlobal))
      const GoogleBetaProvider(
        project: r'${var.project_id}',
        region: r'${var.region}',
      ),
  ];
}

IamPrincipal _serviceAccountMember(GoogleServiceAccount account) =>
    .arg(TfArg.expression('serviceAccount:${account.email.toTfJson()}'));

IamPrincipal _serviceAgent(DataGoogleProject project, String agent) => .arg(
  TfArg.expression(
    'serviceAccount:service-${project.number.toTfJson()}'
    '@$agent.iam.gserviceaccount.com',
  ),
);

List<(String, String)> _filters(TriggerConfig trigger) => [
  ('type', trigger.type.identifier),
  ...switch (trigger) {
    FirestoreTriggerConfig(:final database, :final document) => [
      ('database', database),
      ('document', document),
    ],
    StorageTriggerConfig(:final bucket) => [('bucket', bucket)],
    TriggerConfig() => const <(String, String)>[],
  },
];

/// A Workflows program that runs [job] once per event, passing the event
/// through [jobCloudEventEnv]. `$${` escapes the Workflows expression from
/// Terraform's own interpolation.
String _runJobWorkflow(GoogleCloudRunV2Job job, String path) =>
    '''
main:
  params: [event]
  steps:
    - run_job:
        call: googleapis.run.v2.projects.locations.jobs.run
        args:
          name: ${job.id.toTfJson()}
          body:
            overrides:
              containerOverrides:
                - env:
                    - name: $jobEventPathEnv
                      value: "$path"
                    - name: $jobCloudEventEnv
                      value: "\$\${json.encode_to_string(event)}"
''';
