export interface SettingsModelConfig {
  selectedModelId: string;
}

export type ModelDownloadStatus = 'idle' | 'downloading' | 'downloaded' | 'failed';

export interface ModelDownloadState {
  status: ModelDownloadStatus;
  progress: number;
  message?: string;
}

export type ModelDownloadStates = Record<string, ModelDownloadState>;

export type ModelDownloadStatesPatch = Record<string, Partial<ModelDownloadState> | undefined>;

export const DEFAULT_SELECTED_MODEL_ID = 'whisper-base';
export const DEFAULT_KNOWN_MODEL_IDS = ['whisper-tiny', 'whisper-base', 'whisper-small'] as const;

const DEFAULT_DOWNLOAD_STATUS: ModelDownloadStatus = 'idle';
const DEFAULT_PROGRESS = 0;

export function createDefaultSettingsModelConfig(): SettingsModelConfig {
  return { selectedModelId: DEFAULT_SELECTED_MODEL_ID };
}

export function normalizeSettingsModelConfig(value: unknown): SettingsModelConfig {
  if (!isRecord(value)) {
    return createDefaultSettingsModelConfig();
  }

  return {
    selectedModelId: readModelId(value.selectedModelId, DEFAULT_SELECTED_MODEL_ID)
  };
}

export function createDefaultModelDownloadStates(): ModelDownloadStates {
  const defaults: ModelDownloadStates = {};

  for (const modelId of DEFAULT_KNOWN_MODEL_IDS) {
    defaults[modelId] = {
      status: DEFAULT_DOWNLOAD_STATUS,
      progress: DEFAULT_PROGRESS
    };
  }

  return defaults;
}

export function normalizeModelDownloadStates(value: unknown): ModelDownloadStates {
  const normalized = createDefaultModelDownloadStates();
  if (!isRecord(value)) {
    return normalized;
  }

  for (const [modelId, state] of Object.entries(value)) {
    normalized[modelId] = normalizeModelDownloadState(state);
  }

  return normalized;
}

export function mergeModelDownloadStates(
  current: ModelDownloadStates,
  patch: unknown
): ModelDownloadStates {
  const merged: ModelDownloadStates = { ...current };
  if (!isRecord(patch)) {
    return merged;
  }

  for (const [modelId, nextState] of Object.entries(patch)) {
    const currentState = merged[modelId] ?? {
      status: DEFAULT_DOWNLOAD_STATUS,
      progress: DEFAULT_PROGRESS
    };

    merged[modelId] = normalizeModelDownloadState({
      ...currentState,
      ...(isRecord(nextState) ? nextState : {})
    });
  }

  return merged;
}

function normalizeModelDownloadState(value: unknown): ModelDownloadState {
  if (!isRecord(value)) {
    return {
      status: DEFAULT_DOWNLOAD_STATUS,
      progress: DEFAULT_PROGRESS
    };
  }

  const status = readStatus(value.status, DEFAULT_DOWNLOAD_STATUS);
  const progress = readProgress(value.progress, status === 'downloaded' ? 100 : DEFAULT_PROGRESS);
  const message = readMessage(value.message);

  return message
    ? {
        status,
        progress,
        message
      }
    : {
        status,
        progress
      };
}

function readModelId(value: unknown, fallback: string): string {
  if (typeof value !== 'string') {
    return fallback;
  }

  const normalized = value.trim();
  return normalized.length > 0 ? normalized : fallback;
}

function readStatus(value: unknown, fallback: ModelDownloadStatus): ModelDownloadStatus {
  if (value === 'idle' || value === 'downloading' || value === 'downloaded' || value === 'failed') {
    return value;
  }

  return fallback;
}

function readProgress(value: unknown, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.max(0, Math.min(100, Math.round(value)));
}

function readMessage(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }

  const normalized = value.trim();
  return normalized.length > 0 ? normalized : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
