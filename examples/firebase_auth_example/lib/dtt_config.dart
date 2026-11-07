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

import 'package:dtt_runtime/dtt_runtime.dart';

import 'src/handlers/on_upload.dart';

final dttConfig = DttConfig(
  service: const Service(
    name: 'gcs-triggers',
    projectId: 'dtt-pkg-test',
    region: 'us-central1',
  ),
  triggers: [
    Trigger.gcsObjectFinalized(
      name: 'on-upload',
      bucket: 'dtt-pkg-test-upload',
      handler: onUpload,
    ),
  ],
);
