/**
 * Gemini OrangeBox multi-project Vertex AI client sample.
 *
 * Executes inside a Client Workload Project using local Application Default
 * Credentials (ADC), while routing model inference, quota, and billing to the
 * Model & Quota Project on the Vertex AI global endpoint.
 */

import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { GoogleGenAI } from '@google/genai';

const VERTEX_LOCATION = 'global';

const DEFAULT_MODELS = [
  'gemini-4-argon-cyber-permissive',
  'gemini-4-carbon-cyber-permissive',
  'gemini-3.8-flash-cyber',
];

function createOrangeBoxClient(modelProject) {
  return new GoogleGenAI({
    vertexai: true,
    project: modelProject,
    location: VERTEX_LOCATION,
    // Authenticate via local workload ADC, but route quota & billing
    // explicitly to the central Model & Quota Project.
    googleAuthOptions: {
      scopes: ['https://www.googleapis.com/auth/cloud-platform'],
      quotaProjectId: modelProject,
    },
    httpOptions: {
      headers: {
        'X-Goog-User-Project': modelProject,
      },
    },
  });
}

async function runAuditTriggerTest(ai, modelId) {
  console.log(`\nInvoking ${modelId} on global endpoint...`);
  const response = await ai.models.generateContent({
    model: modelId,
    contents:
      'Perform a brief security readiness check: list 3 common CWE categories for memory-unsafe C++ parsers.',
    config: {
      temperature: 0.2,
      maxOutputTokens: 256,
    },
  });

  console.log(`Response from ${modelId}:\n${response.text}\n`);
}

async function resolveModelProject() {
  if (process.env.CENTRAL_MODEL_PROJECT?.trim()) {
    return process.env.CENTRAL_MODEL_PROJECT.trim();
  }
  const rl = readline.createInterface({ input, output });
  try {
    const answer = (await rl.question('Enter Model & Quota Project ID: ')).trim();
    if (!answer) {
      throw new Error('CENTRAL_MODEL_PROJECT is required.');
    }
    return answer;
  } finally {
    rl.close();
  }
}

async function main() {
  const modelProject = await resolveModelProject();
  const ai = createOrangeBoxClient(modelProject);
  // First call triggers asynchronous creation of:
  // <audit-logging-project>.genai_global_logs.request_response_logging
  for (const modelId of DEFAULT_MODELS) {
    await runAuditTriggerTest(ai, modelId);
  }
}

main().catch((err) => {
  console.error('Inference test failed:', err);
  process.exit(1);
});
