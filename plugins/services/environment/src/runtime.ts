import { invoke } from '@/lib/tauri';
import type { BatchLaunchResult } from './types';

export const KERNEL_PREPARE_STATUS_EVENT = 'kernel-prepare-status';

function normalizeInvokeError(error: unknown): Error {
  if (error instanceof Error) return error;
  if (typeof error === 'string') return new Error(error);
  try {
    return new Error(JSON.stringify(error));
  } catch {
    return new Error(String(error));
  }
}

async function invokeEnvironmentRuntime<T>(
  command: string,
  args: Record<string, unknown>
): Promise<T> {
  try {
    return await invoke<T>(command, args);
  } catch (error) {
    throw normalizeInvokeError(error);
  }
}

export async function startEnvironmentRuntime(
  envUuid: string,
  displayId?: string
): Promise<void> {
  await invokeEnvironmentRuntime<void>('start_environment_by_uuid', { envUuid, displayId });
}

export async function stopEnvironmentRuntime(envUuid: string): Promise<void> {
  await invokeEnvironmentRuntime<void>('stop_environment', { envUuid });
}

export async function batchStartEnvironmentsRuntime(
  envUuids: string[],
  displayIdsByEnvUuid?: Record<string, string>
): Promise<BatchLaunchResult[]> {
  return invokeEnvironmentRuntime<BatchLaunchResult[]>('batch_start_environments_by_uuid', {
    envUuids,
    displayIdsByEnvUuid,
  });
}

export async function batchStopEnvironmentsRuntime(
  envUuids: string[]
): Promise<BatchLaunchResult[]> {
  return invokeEnvironmentRuntime<BatchLaunchResult[]>('batch_stop_environments', {
    envUuids,
  });
}
