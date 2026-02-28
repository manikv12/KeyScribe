function byId<TElement extends HTMLElement>(id: string): TElement {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing required element: ${id}`);
  }

  return element as TElement;
}

type SettingsData = Awaited<ReturnType<typeof window.keyscribe.settingsGet>>;
type ShortcutConfig = SettingsData['shortcuts'];
type ModelCatalogSnapshot = Awaited<ReturnType<typeof window.keyscribe.modelsList>>;
type ModelCatalogItem = ModelCatalogSnapshot['models'][number];
type ModelDownloadState = ModelCatalogSnapshot['downloadStates'][string];
type ModelDownloadStatus = ModelDownloadState['status'];

const MODEL_SIMULATION_STORAGE_KEY = 'keyscribe.settings.model-simulation.v1';
const FALLBACK_MODELS: Array<Omit<ModelCatalogItem, 'isDownloaded'>> = [
  {
    id: 'whisper-tiny',
    name: 'Whisper Tiny',
    sizeMB: 75,
    isRecommended: false
  },
  {
    id: 'whisper-base',
    name: 'Whisper Base',
    sizeMB: 142,
    isRecommended: true
  },
  {
    id: 'whisper-small',
    name: 'Whisper Small',
    sizeMB: 466,
    isRecommended: false
  }
];

const DEFAULT_SELECTED_MODEL_ID =
  FALLBACK_MODELS.find((model) => model.isRecommended)?.id ?? 'whisper-base';

interface SimulatedModelState {
  modelConfig: SettingsData['modelConfig'];
  downloadStates: SettingsData['modelDownloadStates'];
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message;
  }

  return String(error);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function clampProgress(value: unknown, fallback = 0): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.max(0, Math.min(100, Math.round(value)));
}

function normalizeStatus(value: unknown): ModelDownloadStatus {
  if (value === 'idle' || value === 'downloading' || value === 'downloaded' || value === 'failed') {
    return value;
  }

  return 'idle';
}

function normalizeDownloadState(value: unknown): ModelDownloadState {
  if (!isRecord(value)) {
    return {
      status: 'idle',
      progress: 0
    };
  }

  const status = normalizeStatus(value.status);
  const progress = clampProgress(value.progress, status === 'downloaded' ? 100 : 0);
  const message = typeof value.message === 'string' ? value.message.trim() : '';

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

function normalizeSelectedModelId(value: unknown): string {
  if (typeof value !== 'string') {
    return DEFAULT_SELECTED_MODEL_ID;
  }

  const normalized = value.trim();
  return normalized.length > 0 ? normalized : DEFAULT_SELECTED_MODEL_ID;
}

function buildDefaultDownloadStates(): SettingsData['modelDownloadStates'] {
  const states: SettingsData['modelDownloadStates'] = {};

  for (const model of FALLBACK_MODELS) {
    states[model.id] = {
      status: 'idle',
      progress: 0
    };
  }

  return states;
}

function normalizeDownloadStateMap(value: unknown): SettingsData['modelDownloadStates'] {
  const normalized = buildDefaultDownloadStates();
  if (!isRecord(value)) {
    return normalized;
  }

  for (const [modelId, state] of Object.entries(value)) {
    normalized[modelId] = normalizeDownloadState(state);
  }

  return normalized;
}

function seedSimulationFromSettings(
  current: SimulatedModelState,
  settings: Pick<SettingsData, 'modelConfig' | 'modelDownloadStates'>
): SimulatedModelState {
  return {
    modelConfig: {
      selectedModelId: normalizeSelectedModelId(settings.modelConfig?.selectedModelId)
    },
    downloadStates: normalizeDownloadStateMap({
      ...current.downloadStates,
      ...settings.modelDownloadStates
    })
  };
}

function buildFallbackSnapshot(state: SimulatedModelState): ModelCatalogSnapshot {
  const selectedModelId = normalizeSelectedModelId(state.modelConfig.selectedModelId);
  const models = FALLBACK_MODELS.map((model) => {
    const modelState = state.downloadStates[model.id] ?? {
      status: 'idle',
      progress: 0
    };

    return {
      ...model,
      isDownloaded: modelState.status === 'downloaded'
    };
  });

  return {
    models,
    downloadStates: normalizeDownloadStateMap(state.downloadStates),
    modelConfig: {
      selectedModelId
    }
  };
}

function describeDownloadState(state: ModelDownloadState): string {
  switch (state.status) {
    case 'downloading':
      return `Downloading (${state.progress}%)`;
    case 'downloaded':
      return 'Downloaded';
    case 'failed':
      return state.message ? `Failed: ${state.message}` : 'Failed';
    default:
      return 'Not downloaded';
  }
}

function loadSimulationStateFromStorage(): SimulatedModelState | null {
  try {
    const raw = localStorage.getItem(MODEL_SIMULATION_STORAGE_KEY);
    if (!raw) {
      return null;
    }

    const parsed = JSON.parse(raw) as unknown;
    if (!isRecord(parsed)) {
      return null;
    }

    const modelConfig =
      isRecord(parsed.modelConfig) && typeof parsed.modelConfig.selectedModelId === 'string'
        ? parsed.modelConfig
        : null;

    return {
      modelConfig: {
        selectedModelId: normalizeSelectedModelId(modelConfig?.selectedModelId)
      },
      downloadStates: normalizeDownloadStateMap(parsed.downloadStates)
    };
  } catch {
    return null;
  }
}

async function renderSettingsInfo(): Promise<void> {
  const settingsInfo = byId<HTMLParagraphElement>('settings-info');
  const settingsStatus = byId<HTMLParagraphElement>('settings-status');
  const saveButton = byId<HTMLButtonElement>('save-shortcuts');
  const reloadButton = byId<HTMLButtonElement>('reload-shortcuts');

  const startStopInput = byId<HTMLInputElement>('shortcut-start-stop');
  const toggleMainInput = byId<HTMLInputElement>('shortcut-toggle-main');
  const openSettingsInput = byId<HTMLInputElement>('shortcut-open-settings');

  const modelList = byId<HTMLUListElement>('model-list');
  const modelsStatus = byId<HTMLParagraphElement>('models-status');
  const refreshModelsButton = byId<HTMLButtonElement>('refresh-models');

  const shortcutButtons = [saveButton, reloadButton];

  let simulationState: SimulatedModelState =
    loadSimulationStateFromStorage() ?? {
      modelConfig: {
        selectedModelId: DEFAULT_SELECTED_MODEL_ID
      },
      downloadStates: buildDefaultDownloadStates()
    };
  let latestModelSnapshot: ModelCatalogSnapshot | null = null;
  let activeModelAction: string | null = null;
  const activeSimulationDownloads = new Map<string, number>();

  const setShortcutBusy = (busy: boolean): void => {
    for (const button of shortcutButtons) {
      button.disabled = busy;
    }
  };

  const persistSimulationState = (): void => {
    localStorage.setItem(MODEL_SIMULATION_STORAGE_KEY, JSON.stringify(simulationState));
  };

  const applyShortcuts = (shortcuts: ShortcutConfig): void => {
    startStopInput.value = shortcuts.startStopRecording;
    toggleMainInput.value = shortcuts.toggleMainWindow;
    openSettingsInput.value = shortcuts.openSettings;
  };

  const readShortcuts = (): ShortcutConfig => ({
    startStopRecording: startStopInput.value.trim(),
    toggleMainWindow: toggleMainInput.value.trim(),
    openSettings: openSettingsInput.value.trim()
  });

  const renderModelList = (snapshot: ModelCatalogSnapshot): void => {
    latestModelSnapshot = snapshot;
    modelList.replaceChildren();

    if (snapshot.models.length === 0) {
      const placeholder = document.createElement('li');
      placeholder.className = 'model-item model-item--placeholder';
      placeholder.textContent = 'No models are available yet.';
      modelList.append(placeholder);
      return;
    }

    for (const model of snapshot.models) {
      const state = normalizeDownloadState(snapshot.downloadStates[model.id]);
      const isSelected = snapshot.modelConfig.selectedModelId === model.id;
      const isDownloaded = model.isDownloaded || state.status === 'downloaded';

      const item = document.createElement('li');
      item.className = 'model-item';

      const header = document.createElement('div');
      header.className = 'model-item__header';

      const title = document.createElement('h3');
      title.className = 'model-item__title';
      title.textContent = model.name;

      const badges = document.createElement('div');
      badges.className = 'model-item__badges';

      if (model.isRecommended) {
        const recommendedBadge = document.createElement('span');
        recommendedBadge.className = 'model-badge model-badge--recommended';
        recommendedBadge.textContent = 'Recommended';
        badges.append(recommendedBadge);
      }

      if (isSelected) {
        const selectedBadge = document.createElement('span');
        selectedBadge.className = 'model-badge model-badge--selected';
        selectedBadge.textContent = 'Selected';
        badges.append(selectedBadge);
      }

      if (isDownloaded) {
        const downloadedBadge = document.createElement('span');
        downloadedBadge.className = 'model-badge';
        downloadedBadge.textContent = 'Downloaded';
        badges.append(downloadedBadge);
      }

      header.append(title, badges);

      const meta = document.createElement('p');
      meta.className = 'model-item__meta';
      meta.textContent = `${model.sizeMB} MB | ${describeDownloadState(state)}`;

      const progress = document.createElement('div');
      progress.className = 'model-progress';
      progress.setAttribute('aria-hidden', 'true');

      const progressFill = document.createElement('span');
      progressFill.className = `model-progress__fill model-progress__fill--${state.status}`;
      progressFill.style.width = `${state.progress}%`;
      progress.append(progressFill);

      const actions = document.createElement('div');
      actions.className = 'actions';

      const downloadButton = document.createElement('button');
      downloadButton.type = 'button';
      downloadButton.className = 'button';
      downloadButton.textContent = state.status === 'downloading' ? 'Downloading...' : 'Download';
      downloadButton.disabled =
        state.status === 'downloading' || state.status === 'downloaded' || activeModelAction !== null;
      downloadButton.addEventListener('click', () => {
        void downloadModel(model.id);
      });

      const retryButton = document.createElement('button');
      retryButton.type = 'button';
      retryButton.className = 'button button--ghost';
      retryButton.textContent = 'Retry';
      retryButton.hidden = state.status !== 'failed';
      retryButton.disabled = state.status !== 'failed' || activeModelAction !== null;
      retryButton.addEventListener('click', () => {
        void downloadModel(model.id);
      });

      const selectButton = document.createElement('button');
      selectButton.type = 'button';
      selectButton.className = isSelected ? 'button button--secondary' : 'button button--ghost';
      selectButton.textContent = isSelected ? 'Selected' : 'Select';
      selectButton.disabled = !isDownloaded || isSelected || activeModelAction !== null;
      selectButton.addEventListener('click', () => {
        void selectModel(model.id);
      });

      actions.append(downloadButton, retryButton, selectButton);
      item.append(header, meta, progress, actions);
      modelList.append(item);
    }
  };

  const renderFallbackModelList = (): void => {
    renderModelList(buildFallbackSnapshot(simulationState));
  };

  const renderCurrentModelList = (): void => {
    if (latestModelSnapshot) {
      renderModelList(latestModelSnapshot);
      return;
    }

    renderFallbackModelList();
  };

  const loadSettings = async (announceFailure: boolean): Promise<void> => {
    try {
      const settings = await window.keyscribe.settingsGet();
      applyShortcuts(settings.shortcuts);
      simulationState = seedSimulationFromSettings(simulationState, settings);
      persistSimulationState();
      settingsStatus.textContent = 'Shortcuts loaded.';
    } catch (error) {
      if (announceFailure) {
        settingsStatus.textContent = `Failed to load shortcuts: ${errorMessage(error)}`;
      } else {
        settingsStatus.textContent = 'Failed to load shortcuts.';
      }
    }
  };

  const refreshModelList = async (announceFailure: boolean): Promise<void> => {
    refreshModelsButton.disabled = true;

    try {
      const snapshot = await window.keyscribe.modelsList();
      simulationState = {
        modelConfig: {
          selectedModelId: normalizeSelectedModelId(snapshot.modelConfig.selectedModelId)
        },
        downloadStates: normalizeDownloadStateMap(snapshot.downloadStates)
      };
      persistSimulationState();
      renderModelList(snapshot);
      modelsStatus.textContent = 'Model catalog loaded.';
    } catch (error) {
      renderFallbackModelList();
      modelsStatus.textContent = announceFailure
        ? `Model service is unavailable: ${errorMessage(error)}. Showing simulated model catalog.`
        : 'Model service unavailable. Showing simulated model catalog.';
    } finally {
      refreshModelsButton.disabled = false;
    }
  };

  const updateSimulationDownloadState = (
    modelId: string,
    state: ModelDownloadState,
    announce?: string
  ): void => {
    simulationState = {
      ...simulationState,
      downloadStates: {
        ...simulationState.downloadStates,
        [modelId]: state
      }
    };
    persistSimulationState();
    const baseSnapshot = latestModelSnapshot ?? buildFallbackSnapshot(simulationState);
    latestModelSnapshot = {
      ...baseSnapshot,
      downloadStates: {
        ...baseSnapshot.downloadStates,
        [modelId]: state
      },
      models: baseSnapshot.models.map((model) =>
        model.id === modelId
          ? {
              ...model,
              isDownloaded: state.status === 'downloaded'
            }
          : model
      )
    };
    renderCurrentModelList();
    if (announce) {
      modelsStatus.textContent = announce;
    }
  };

  const stopSimulationDownload = (modelId: string): void => {
    const timer = activeSimulationDownloads.get(modelId);
    if (timer !== undefined) {
      window.clearInterval(timer);
      activeSimulationDownloads.delete(modelId);
    }
  };

  const modelNameById = (modelId: string): string => {
    return (
      latestModelSnapshot?.models.find((model) => model.id === modelId)?.name ??
      FALLBACK_MODELS.find((model) => model.id === modelId)?.name ??
      modelId
    );
  };

  const simulateDownload = (modelId: string): void => {
    stopSimulationDownload(modelId);

    updateSimulationDownloadState(
      modelId,
      {
        status: 'downloading',
        progress: 0,
        message: 'Preparing download'
      },
      `Simulating download for ${modelNameById(modelId)}...`
    );

    const shouldFail = Math.random() < 0.18;

    const timer = window.setInterval(() => {
      const current = simulationState.downloadStates[modelId] ?? {
        status: 'downloading',
        progress: 0
      };

      if (current.status !== 'downloading') {
        stopSimulationDownload(modelId);
        return;
      }

      const nextProgress = Math.min(100, current.progress + Math.floor(Math.random() * 15) + 8);

      if (shouldFail && nextProgress >= 65) {
        updateSimulationDownloadState(
          modelId,
          {
            status: 'failed',
            progress: nextProgress,
            message: 'Network interrupted. Please retry.'
          },
          `${modelNameById(modelId)} download failed. Retry when ready.`
        );
        stopSimulationDownload(modelId);
        return;
      }

      if (nextProgress >= 100) {
        updateSimulationDownloadState(
          modelId,
          {
            status: 'downloaded',
            progress: 100
          },
          `${modelNameById(modelId)} downloaded.`
        );
        stopSimulationDownload(modelId);
        return;
      }

      updateSimulationDownloadState(modelId, {
        status: 'downloading',
        progress: nextProgress,
        message: `Downloading... ${nextProgress}%`
      });
    }, 450);

    activeSimulationDownloads.set(modelId, timer);
  };

  const downloadModel = async (modelId: string): Promise<void> => {
    const modelName = modelNameById(modelId);
    activeModelAction = modelId;
    refreshModelsButton.disabled = true;
    renderCurrentModelList();

    try {
      const state = await window.keyscribe.modelsDownload(modelId);
      updateSimulationDownloadState(modelId, normalizeDownloadState(state), `${modelName} download started.`);
      await refreshModelList(false);
    } catch {
      simulateDownload(modelId);
    } finally {
      activeModelAction = null;
      refreshModelsButton.disabled = false;
      renderCurrentModelList();
    }
  };

  const selectModel = async (modelId: string): Promise<void> => {
    const modelName = modelNameById(modelId);
    activeModelAction = modelId;
    refreshModelsButton.disabled = true;
    renderCurrentModelList();

    try {
      const settings = await window.keyscribe.settingsUpdateSelectedModel(modelId);
      simulationState = seedSimulationFromSettings(simulationState, settings);
      persistSimulationState();
      await refreshModelList(false);
      modelsStatus.textContent = `${modelName} selected.`;
    } catch {
      simulationState = {
        ...simulationState,
        modelConfig: {
          selectedModelId: modelId
        }
      };
      persistSimulationState();
      renderFallbackModelList();
      modelsStatus.textContent = `${modelName} selected (simulated).`;
    } finally {
      activeModelAction = null;
      refreshModelsButton.disabled = false;
      renderCurrentModelList();
    }
  };

  try {
    const appInfo = await window.keyscribe.getAppInfo();
    settingsInfo.textContent = `Running ${appInfo.name} ${appInfo.version} (${appInfo.platform}).`;
  } catch {
    settingsInfo.textContent = 'Unable to load app details.';
  }

  saveButton.addEventListener('click', async () => {
    settingsStatus.textContent = 'Saving shortcuts...';
    setShortcutBusy(true);

    try {
      const updated = await window.keyscribe.settingsUpdateShortcuts(readShortcuts());
      applyShortcuts(updated.shortcuts);
      simulationState = seedSimulationFromSettings(simulationState, updated);
      persistSimulationState();
      settingsStatus.textContent = 'Shortcuts saved.';
    } catch (error) {
      settingsStatus.textContent = `Failed to save shortcuts: ${errorMessage(error)}`;
    } finally {
      setShortcutBusy(false);
    }
  });

  reloadButton.addEventListener('click', async () => {
    settingsStatus.textContent = 'Reloading shortcuts...';
    setShortcutBusy(true);
    try {
      await loadSettings(false);
      await refreshModelList(false);
    } finally {
      setShortcutBusy(false);
    }
  });

  refreshModelsButton.addEventListener('click', async () => {
    modelsStatus.textContent = 'Refreshing model catalog...';
    await refreshModelList(true);
  });

  await loadSettings(false);
  await refreshModelList(false);
}

void renderSettingsInfo();

export {};
