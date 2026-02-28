import {
  app,
  BrowserWindow,
  globalShortcut,
  ipcMain,
  Menu,
  nativeImage,
  screen,
  shell,
  Tray,
  type BrowserWindowConstructorOptions
} from 'electron';
import { spawn } from 'node:child_process';
import { accessSync, constants } from 'node:fs';
import { dirname, join } from 'node:path';
import { IPC_CHANNELS } from '../shared/ipcChannels';
import type {
  AppInfo,
  ModelCatalogItem,
  ModelCatalogSnapshot,
  ModelDownloadState,
  OpenSettingsWindowResult,
  RuntimeActionResult,
  RuntimeCapabilities,
  RuntimePingResult,
  RuntimeStatusResult,
  SettingsModelConfigPatch
} from '@keyscribe/shared-types';
import {
  DEFAULT_SELECTED_MODEL_ID,
  SettingsStore,
  TranscriptHistoryStore,
  type SettingsData,
  type SettingsPatch,
  type ShortcutConfig,
  type TranscriptHistoryEntry
} from './services';

let mainWindow: BrowserWindow | null = null;
let settingsWindow: BrowserWindow | null = null;
let popoverWindow: BrowserWindow | null = null;
let hudWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
let isQuitting = false;
let settingsStore: SettingsStore | null = null;
let transcriptHistoryStore: TranscriptHistoryStore | null = null;
let resolvedRuntimeBinaryPath: string | null | undefined;
let runtimeBinaryCandidates: string[] = [];
let fallbackRuntimeIsDictating = false;
const modelDownloadTimers = new Map<string, NodeJS.Timeout>();

const preloadPath = join(__dirname, '../preload/index.cjs');
const RUNTIME_BINARY_BASE_NAME = 'keyscribe-runtime';
const MODEL_CATALOG: Array<Omit<ModelCatalogItem, 'isDownloaded'>> = [
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

interface RuntimeResponse<T> {
  result?: T;
  error?: { code?: string; message?: string };
}

interface RuntimeRequest {
  id: number;
  method: string;
  params: unknown;
}

interface RuntimePingPayload {
  ok: boolean;
  timestampMs: number;
}

function createSecureWindow(options: BrowserWindowConstructorOptions): BrowserWindow {
  const browserWindow = new BrowserWindow({
    ...options,
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      ...options.webPreferences
    }
  });

  browserWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url);
    return { action: 'deny' };
  });

  browserWindow.webContents.on('will-navigate', (event, url) => {
    if (url !== browserWindow.webContents.getURL()) {
      event.preventDefault();
      void shell.openExternal(url);
    }
  });

  return browserWindow;
}

function resolveRendererUrl(pathname: string): string | null {
  const devServerUrl = process.env.ELECTRON_RENDERER_URL;
  if (!devServerUrl) {
    return null;
  }

  return new URL(pathname, devServerUrl).toString();
}

function createMainWindow(): BrowserWindow {
  const window = createSecureWindow({
    width: 1024,
    height: 700,
    minWidth: 860,
    minHeight: 560,
    show: false,
    title: 'KeyScribe'
  });

  window.on('ready-to-show', () => {
    window.show();
  });

  window.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      window.hide();
    }
  });

  const mainUrl = resolveRendererUrl('/');
  if (mainUrl) {
    void window.loadURL(mainUrl);
  } else {
    void window.loadFile(join(__dirname, '../renderer/index.html'));
  }

  return window;
}

function showMainWindow(): void {
  popoverWindow?.hide();

  if (!mainWindow || mainWindow.isDestroyed()) {
    mainWindow = createMainWindow();
    return;
  }

  mainWindow.show();
  mainWindow.focus();
}

function toggleMainWindowVisibility(): void {
  if (!mainWindow || mainWindow.isDestroyed()) {
    mainWindow = createMainWindow();
    return;
  }

  if (mainWindow.isVisible()) {
    mainWindow.hide();
    return;
  }

  mainWindow.show();
  mainWindow.focus();
}

function openSettingsWindow(): BrowserWindow {
  popoverWindow?.hide();

  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.focus();
    return settingsWindow;
  }

  settingsWindow = createSecureWindow({
    width: 420,
    height: 520,
    minWidth: 420,
    minHeight: 520,
    maxWidth: 560,
    maxHeight: 700,
    resizable: true,
    title: 'KeyScribe Settings',
    show: false,
    parent: mainWindow ?? undefined,
    modal: false
  });

  settingsWindow.on('ready-to-show', () => {
    settingsWindow?.show();
  });

  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });

  const settingsUrl = resolveRendererUrl('/settings.html');
  if (settingsUrl) {
    void settingsWindow.loadURL(settingsUrl);
  } else {
    void settingsWindow.loadFile(join(__dirname, '../renderer/settings.html'));
  }

  return settingsWindow;
}

function createPopoverWindow(): BrowserWindow {
  const window = createSecureWindow({
    width: 380,
    height: 440,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    title: 'KeyScribe Quick Controls'
  });

  window.on('blur', () => {
    if (!window.webContents.isDevToolsOpened()) {
      window.hide();
    }
  });

  window.on('closed', () => {
    popoverWindow = null;
  });

  const popoverUrl = resolveRendererUrl('/popover.html');
  if (popoverUrl) {
    void window.loadURL(popoverUrl);
  } else {
    void window.loadFile(join(__dirname, '../renderer/popover.html'));
  }

  return window;
}

function getOrCreatePopoverWindow(): BrowserWindow {
  if (!popoverWindow || popoverWindow.isDestroyed()) {
    popoverWindow = createPopoverWindow();
  }

  return popoverWindow;
}

function positionPopoverWindow(window: BrowserWindow): void {
  if (!tray) {
    return;
  }

  const trayBounds = tray.getBounds();
  const windowBounds = window.getBounds();
  const display = screen.getDisplayNearestPoint({
    x: Math.round(trayBounds.x + trayBounds.width / 2),
    y: Math.round(trayBounds.y + trayBounds.height / 2)
  });

  const xTarget = Math.round(trayBounds.x + trayBounds.width / 2 - windowBounds.width / 2);
  const yTarget =
    process.platform === 'darwin'
      ? Math.round(trayBounds.y + trayBounds.height + 6)
      : Math.round(trayBounds.y - windowBounds.height - 6);

  const x = Math.max(
    display.workArea.x,
    Math.min(xTarget, display.workArea.x + display.workArea.width - windowBounds.width)
  );
  const y = Math.max(
    display.workArea.y,
    Math.min(yTarget, display.workArea.y + display.workArea.height - windowBounds.height)
  );

  window.setPosition(x, y, false);
}

function togglePopoverWindow(): void {
  const window = getOrCreatePopoverWindow();

  if (window.isVisible()) {
    window.hide();
    return;
  }

  positionPopoverWindow(window);
  window.show();
  window.focus();
}

function createHudWindow(): BrowserWindow {
  const window = createSecureWindow({
    width: 430,
    height: 110,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    show: false,
    title: 'KeyScribe HUD'
  });

  window.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: true
  });

  window.on('closed', () => {
    hudWindow = null;
  });

  window.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      window.hide();
    }
  });

  const hudUrl = resolveRendererUrl('/hud.html');
  if (hudUrl) {
    void window.loadURL(hudUrl);
  } else {
    void window.loadFile(join(__dirname, '../renderer/hud.html'));
  }

  return window;
}

function getOrCreateHudWindow(): BrowserWindow {
  if (!hudWindow || hudWindow.isDestroyed()) {
    hudWindow = createHudWindow();
  }

  return hudWindow;
}

function showHudWindow(): void {
  const window = getOrCreateHudWindow();
  if (!window.isVisible()) {
    window.showInactive();
  }
}

function hideHudWindow(): void {
  if (hudWindow && !hudWindow.isDestroyed()) {
    hudWindow.hide();
  }
}

function createTrayImage() {
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
      <rect x="8" y="8" width="48" height="48" rx="12" fill="#0C5E8C"/>
      <path d="M20 42V22H25L34 34V22H39V42H34L25 30V42H20Z" fill="white"/>
    </svg>
  `;

  return nativeImage.createFromDataURL(
    `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`
  );
}

function createTray(): Tray {
  const trayInstance = new Tray(createTrayImage());

  trayInstance.setToolTip('KeyScribe');
  trayInstance.setContextMenu(
    Menu.buildFromTemplate([
      {
        label: 'Show Dashboard',
        click: () => {
          showMainWindow();
        }
      },
      {
        label: 'Show Quick Controls',
        click: () => {
          togglePopoverWindow();
        }
      },
      {
        label: 'Open Settings',
        click: () => {
          openSettingsWindow();
        }
      },
      { type: 'separator' },
      {
        label: 'Quit',
        click: () => {
          isQuitting = true;
          app.quit();
        }
      }
    ])
  );

  trayInstance.on('click', () => {
    togglePopoverWindow();
  });

  return trayInstance;
}

function getAppInfo(): AppInfo {
  return {
    name: app.getName(),
    version: app.getVersion(),
    platform: process.platform,
    isPackaged: app.isPackaged
  };
}

function defaultRuntimeCapabilities(): RuntimeCapabilities {
  const macos = process.platform === 'darwin';
  return {
    appleSpeechAvailable: macos,
    whisperAvailable: false,
    caretBoundsAvailable: macos
  };
}

function runtimeBinaryNames(): string[] {
  if (process.platform === 'win32') {
    return [`${RUNTIME_BINARY_BASE_NAME}.exe`, RUNTIME_BINARY_BASE_NAME];
  }

  return [RUNTIME_BINARY_BASE_NAME];
}

function isUsableRuntimeBinary(binaryPath: string): boolean {
  const mode = process.platform === 'win32' ? constants.F_OK : constants.F_OK | constants.X_OK;
  try {
    accessSync(binaryPath, mode);
    return true;
  } catch {
    return false;
  }
}

function collectRuntimeBinaryCandidates(): string[] {
  const names = runtimeBinaryNames();
  const candidates = new Set<string>();
  const appPath = app.getAppPath();
  const appDirectory = appPath.endsWith('.asar') ? dirname(appPath) : appPath;

  for (const runtimeBinaryName of names) {
    candidates.add(join(process.resourcesPath, runtimeBinaryName));
    candidates.add(join(process.resourcesPath, 'bin', runtimeBinaryName));
    candidates.add(join(dirname(process.resourcesPath), runtimeBinaryName));
    candidates.add(join(dirname(process.resourcesPath), 'bin', runtimeBinaryName));
    candidates.add(join(appDirectory, runtimeBinaryName));
    candidates.add(join(appDirectory, 'bin', runtimeBinaryName));
  }

  if (!app.isPackaged) {
    for (const runtimeBinaryName of names) {
      candidates.add(join(appDirectory, '../native/target/debug', runtimeBinaryName));
      candidates.add(join(appDirectory, '../native/target/release', runtimeBinaryName));
      candidates.add(join(appDirectory, '../../native/target/debug', runtimeBinaryName));
      candidates.add(join(appDirectory, '../../native/target/release', runtimeBinaryName));
      candidates.add(join(process.cwd(), 'native/target/debug', runtimeBinaryName));
      candidates.add(join(process.cwd(), 'native/target/release', runtimeBinaryName));
      candidates.add(join(process.cwd(), '../native/target/debug', runtimeBinaryName));
      candidates.add(join(process.cwd(), '../native/target/release', runtimeBinaryName));
    }
  }

  return [...candidates];
}

function resolveRuntimeBinaryPath(): string | null {
  const envOverridePath = process.env.KEYSCRIBE_RUNTIME_BIN?.trim();
  if (envOverridePath) {
    runtimeBinaryCandidates = [envOverridePath];
    return envOverridePath;
  }

  runtimeBinaryCandidates = collectRuntimeBinaryCandidates();

  for (const candidate of runtimeBinaryCandidates) {
    if (isUsableRuntimeBinary(candidate)) {
      return candidate;
    }
  }

  return null;
}

function getRuntimeBinaryPath(): string | null {
  if (resolvedRuntimeBinaryPath !== undefined) {
    return resolvedRuntimeBinaryPath;
  }

  resolvedRuntimeBinaryPath = resolveRuntimeBinaryPath();
  return resolvedRuntimeBinaryPath;
}

function createFallbackRuntimeReason(): string {
  return 'Using fallback runtime in Electron main process because native sidecar was not found.';
}

function invokeFallbackRuntime<T>(method: string, params: unknown): T {
  if (method === 'runtime.ping') {
    return {
      ok: true,
      timestampMs: Date.now()
    } as T;
  }

  if (method === 'runtime.get_capabilities') {
    return defaultRuntimeCapabilities() as T;
  }

  if (method === 'runtime.start_dictation') {
    fallbackRuntimeIsDictating = true;
    return {
      ok: true,
      status: 'dictating',
      isDictating: true,
      reason: createFallbackRuntimeReason()
    } as T;
  }

  if (method === 'runtime.stop_dictation') {
    fallbackRuntimeIsDictating = false;
    return {
      ok: true,
      status: 'idle',
      isDictating: false,
      reason: createFallbackRuntimeReason()
    } as T;
  }

  if (method === 'runtime.get_status') {
    return {
      ok: true,
      status: fallbackRuntimeIsDictating ? 'dictating' : 'idle',
      isDictating: fallbackRuntimeIsDictating,
      reason: createFallbackRuntimeReason()
    } as T;
  }

  if (method === 'runtime.insert_text') {
    const transcript = extractTranscriptTextFromInsertParams(params);
    if (!transcript) {
      return {
        ok: false,
        status: 'noop',
        reason: 'No text was provided for insertion.'
      } as T;
    }

    return {
      ok: true,
      status: 'inserted',
      reason: createFallbackRuntimeReason()
    } as T;
  }

  throw new Error(`Unsupported fallback runtime method: ${method}`);
}

async function invokeRuntimeViaBinary<T>(
  runtimeBinaryPath: string,
  method: string,
  params: unknown = {}
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const child = spawn(runtimeBinaryPath, [], {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdoutBuffer = '';
    let stderrBuffer = '';

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    child.stdout.on('data', (chunk: string) => {
      stdoutBuffer += chunk;
    });

    child.stderr.on('data', (chunk: string) => {
      stderrBuffer += chunk;
    });

    child.on('error', (error) => {
      reject(error);
    });

    child.on('close', (code) => {
      const firstLine = stdoutBuffer
        .split(/\r?\n/)
        .find((line) => line.trim().length > 0);

      if (!firstLine) {
        reject(
          new Error(
            `Runtime returned no output (exit ${code ?? 'unknown'}). ${stderrBuffer.trim()}`
          )
        );
        return;
      }

      let payload: RuntimeResponse<T>;
      try {
        payload = JSON.parse(firstLine) as RuntimeResponse<T>;
      } catch (error) {
        reject(new Error(`Runtime returned invalid JSON: ${String(error)}`));
        return;
      }

      if (payload.error) {
        reject(new Error(payload.error.message ?? 'Runtime request failed.'));
        return;
      }

      if (payload.result === undefined) {
        reject(new Error('Runtime response missing result.'));
        return;
      }

      resolve(payload.result);
    });

    const requestPayload: RuntimeRequest = {
      id: Date.now(),
      method,
      params: params === undefined ? {} : params
    };
    const request = JSON.stringify(requestPayload);
    child.stdin.write(`${request}\n`);
    child.stdin.end();
  });
}

async function invokeRuntimeOrFallback<T>(method: string, params: unknown = {}): Promise<T> {
  const runtimeBinaryPath = getRuntimeBinaryPath();
  if (!runtimeBinaryPath) {
    return invokeFallbackRuntime<T>(method, params);
  }

  return await invokeRuntimeViaBinary<T>(runtimeBinaryPath, method, params);
}

function requireSettingsStore(): SettingsStore {
  if (!settingsStore) {
    throw new Error('Settings store is not initialized.');
  }

  return settingsStore;
}

function requireTranscriptHistoryStore(): TranscriptHistoryStore {
  if (!transcriptHistoryStore) {
    throw new Error('Transcript history store is not initialized.');
  }

  return transcriptHistoryStore;
}

function normalizeSettingsShortcutsPatch(value: unknown): SettingsPatch {
  if (!isRecord(value)) {
    return {};
  }

  if (isRecord(value.shortcuts)) {
    return {
      shortcuts: value.shortcuts as Partial<ShortcutConfig>
    };
  }

  return {
    shortcuts: value as Partial<ShortcutConfig>
  };
}

function normalizeSelectedModelPatch(value: unknown): SettingsModelConfigPatch {
  if (!isRecord(value)) {
    return {};
  }

  if (typeof value.selectedModelId === 'string') {
    const selectedModelId = value.selectedModelId.trim();
    if (selectedModelId.length > 0) {
      return { selectedModelId };
    }
  }

  return {};
}

function normalizeModelsDownloadRequest(value: unknown): { modelId: string } {
  if (!isRecord(value) || typeof value.modelId !== 'string') {
    throw new Error('models:download requires a modelId.');
  }

  const modelId = value.modelId.trim();
  if (!modelId) {
    throw new Error('models:download requires a non-empty modelId.');
  }

  return { modelId };
}

function findModelById(modelId: string): (typeof MODEL_CATALOG)[number] | undefined {
  return MODEL_CATALOG.find((model) => model.id === modelId);
}

function ensureKnownModelId(modelId: string): void {
  if (!findModelById(modelId)) {
    throw new Error(`Unknown model id: ${modelId}`);
  }
}

function normalizeModelDownloadState(value: unknown): ModelDownloadState {
  if (!isRecord(value)) {
    return {
      status: 'idle',
      progress: 0
    };
  }

  const status =
    value.status === 'idle' ||
    value.status === 'downloading' ||
    value.status === 'downloaded' ||
    value.status === 'failed'
      ? value.status
      : 'idle';

  const progress =
    typeof value.progress === 'number' && Number.isFinite(value.progress)
      ? Math.max(0, Math.min(100, Math.round(value.progress)))
      : status === 'downloaded'
        ? 100
        : 0;

  const message =
    typeof value.message === 'string' && value.message.trim().length > 0
      ? value.message.trim()
      : undefined;

  return message ? { status, progress, message } : { status, progress };
}

function normalizeSelectedModelId(value: unknown): string {
  const fallback = DEFAULT_SELECTED_MODEL_ID;
  if (typeof value !== 'string') {
    return fallback;
  }

  const normalized = value.trim();
  if (!normalized) {
    return fallback;
  }

  return findModelById(normalized) ? normalized : fallback;
}

async function getModelCatalogSnapshot(): Promise<ModelCatalogSnapshot> {
  const settings = await requireSettingsStore().get();
  const selectedModelId = normalizeSelectedModelId(settings.modelConfig.selectedModelId);
  const downloadStates: Record<string, ModelDownloadState> = {};

  for (const model of MODEL_CATALOG) {
    downloadStates[model.id] = normalizeModelDownloadState(settings.modelDownloadStates[model.id]);
  }

  const models: ModelCatalogItem[] = MODEL_CATALOG.map((model) => {
    const modelState = downloadStates[model.id] ?? {
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
    downloadStates,
    modelConfig: {
      selectedModelId
    }
  };
}

async function updateModelDownloadState(
  modelId: string,
  nextState: ModelDownloadState
): Promise<ModelDownloadState> {
  ensureKnownModelId(modelId);
  const normalizedState = normalizeModelDownloadState(nextState);
  await requireSettingsStore().update({
    modelDownloadStates: {
      [modelId]: normalizedState
    }
  });
  return normalizedState;
}

function clearModelDownloadTimer(modelId: string): void {
  const timer = modelDownloadTimers.get(modelId);
  if (!timer) {
    return;
  }

  clearInterval(timer);
  modelDownloadTimers.delete(modelId);
}

function stopAllModelDownloadTimers(): void {
  for (const modelId of modelDownloadTimers.keys()) {
    clearModelDownloadTimer(modelId);
  }
}

async function startModelDownload(modelId: string): Promise<ModelDownloadState> {
  ensureKnownModelId(modelId);

  const snapshot = await getModelCatalogSnapshot();
  const currentState = normalizeModelDownloadState(snapshot.downloadStates[modelId]);

  if (currentState.status === 'downloaded') {
    return currentState;
  }

  if (modelDownloadTimers.has(modelId)) {
    return currentState.status === 'downloading'
      ? currentState
      : {
          status: 'downloading',
          progress: currentState.progress,
          message: currentState.message
        };
  }

  const initialState = await updateModelDownloadState(modelId, {
    status: 'downloading',
    progress: 0,
    message: 'Preparing download'
  });

  const timer = setInterval(() => {
    void (async () => {
      const latestSnapshot = await getModelCatalogSnapshot();
      const latestState = normalizeModelDownloadState(latestSnapshot.downloadStates[modelId]);
      if (latestState.status !== 'downloading') {
        clearModelDownloadTimer(modelId);
        return;
      }

      const nextProgress = Math.min(100, latestState.progress + Math.floor(Math.random() * 18) + 10);
      if (nextProgress >= 100) {
        await updateModelDownloadState(modelId, {
          status: 'downloaded',
          progress: 100
        });
        clearModelDownloadTimer(modelId);
        return;
      }

      await updateModelDownloadState(modelId, {
        status: 'downloading',
        progress: nextProgress,
        message: `Downloading... ${nextProgress}%`
      });
    })().catch((error) => {
      void updateModelDownloadState(modelId, {
        status: 'failed',
        progress: 0,
        message: String(error)
      });
      clearModelDownloadTimer(modelId);
    });
  }, 500);

  modelDownloadTimers.set(modelId, timer);

  return initialState;
}

function extractTranscriptTextFromInsertParams(params: unknown): string | undefined {
  if (typeof params === 'string') {
    const normalized = params.trim();
    return normalized.length > 0 ? normalized : undefined;
  }

  if (!isRecord(params)) {
    return undefined;
  }

  const textValue = params.text;
  if (typeof textValue === 'string') {
    const normalized = textValue.trim();
    if (normalized.length > 0) {
      return normalized;
    }
  }

  const transcriptValue = params.transcript;
  if (typeof transcriptValue === 'string') {
    const normalized = transcriptValue.trim();
    if (normalized.length > 0) {
      return normalized;
    }
  }

  return undefined;
}

async function initializeStores(): Promise<SettingsData> {
  settingsStore = new SettingsStore();
  transcriptHistoryStore = new TranscriptHistoryStore();

  const [settings] = await Promise.all([
    settingsStore.get(),
    transcriptHistoryStore.get()
  ]);

  return settings;
}

async function toggleDictationFromShortcut(): Promise<void> {
  try {
    const status = await invokeRuntimeOrFallback<RuntimeStatusResult>('runtime.get_status');
    const isDictating = status.isDictating ?? status.status === 'dictating';

    if (isDictating) {
      await invokeRuntimeOrFallback<RuntimeActionResult>('runtime.stop_dictation');
      await syncHudWithRuntimeStatus();
      return;
    }

    await invokeRuntimeOrFallback<RuntimeActionResult>('runtime.start_dictation');
    await syncHudWithRuntimeStatus();
  } catch (error) {
    console.error('Failed to toggle dictation from global shortcut.', error);
  }
}

async function syncHudWithRuntimeStatus(): Promise<void> {
  try {
    const status = await invokeRuntimeOrFallback<RuntimeStatusResult>('runtime.get_status');
    const isDictating = status.isDictating ?? status.status === 'dictating';
    if (isDictating) {
      showHudWindow();
    } else {
      hideHudWindow();
    }
  } catch {
    hideHudWindow();
  }
}

function registerGlobalShortcuts(shortcuts: ShortcutConfig): void {
  globalShortcut.unregisterAll();

  const registrations: Array<{ accelerator: string; handler: () => void }> = [
    {
      accelerator: shortcuts.startStopRecording,
      handler: () => {
        void toggleDictationFromShortcut();
      }
    },
    {
      accelerator: shortcuts.toggleMainWindow,
      handler: () => {
        toggleMainWindowVisibility();
      }
    },
    {
      accelerator: shortcuts.openSettings,
      handler: () => {
        openSettingsWindow();
      }
    }
  ];

  for (const { accelerator, handler } of registrations) {
    const normalized = accelerator.trim();
    if (!normalized) {
      continue;
    }

    const didRegister = globalShortcut.register(normalized, handler);
    if (!didRegister) {
      console.warn(`Failed to register global shortcut: ${normalized}`);
    }
  }
}

function registerIpcHandlers(): void {
  ipcMain.handle(IPC_CHANNELS.GET_APP_INFO, (): AppInfo => getAppInfo());

  ipcMain.handle(
    IPC_CHANNELS.OPEN_SETTINGS_WINDOW,
    (): OpenSettingsWindowResult => {
      openSettingsWindow();
      return { opened: true };
    }
  );

  ipcMain.handle(
    IPC_CHANNELS.RUNTIME_PING,
    async (): Promise<RuntimePingResult> => {
      const runtimeBinaryPath = getRuntimeBinaryPath();
      if (!runtimeBinaryPath) {
        return {
          ok: true,
          timestampMs: Date.now(),
          sidecarConnected: false,
          message: createFallbackRuntimeReason()
        };
      }

      try {
        const runtime = await invokeRuntimeViaBinary<RuntimePingPayload>(
          runtimeBinaryPath,
          'runtime.ping'
        );

        return {
          ok: runtime.ok,
          timestampMs: runtime.timestampMs,
          sidecarConnected: true
        };
      } catch (error) {
        return {
          ok: false,
          timestampMs: Date.now(),
          sidecarConnected: false,
          message: String(error)
        };
      }
    }
  );

  ipcMain.handle(
    IPC_CHANNELS.RUNTIME_GET_CAPABILITIES,
    async (): Promise<RuntimeCapabilities> => {
      try {
        return await invokeRuntimeOrFallback<RuntimeCapabilities>('runtime.get_capabilities');
      } catch {
        return defaultRuntimeCapabilities();
      }
    }
  );

  ipcMain.handle(IPC_CHANNELS.RUNTIME_START_DICTATION, async (_event, params: unknown) => {
    const result = await invokeRuntimeOrFallback<RuntimeActionResult>('runtime.start_dictation', params);
    await syncHudWithRuntimeStatus();
    return result;
  });

  ipcMain.handle(IPC_CHANNELS.RUNTIME_STOP_DICTATION, async (_event, params: unknown) => {
    const result = await invokeRuntimeOrFallback<RuntimeActionResult>('runtime.stop_dictation', params);
    await syncHudWithRuntimeStatus();
    return result;
  });

  ipcMain.handle(IPC_CHANNELS.RUNTIME_GET_STATUS, async (_event, params: unknown) => {
    return await invokeRuntimeOrFallback<RuntimeStatusResult>('runtime.get_status', params);
  });

  ipcMain.handle(IPC_CHANNELS.RUNTIME_INSERT_TEXT, async (_event, params: unknown) => {
    const runtimeResult = await invokeRuntimeOrFallback<RuntimeActionResult>(
      'runtime.insert_text',
      params
    );
    const transcriptText = extractTranscriptTextFromInsertParams(params);
    if (transcriptText) {
      await requireTranscriptHistoryStore().add({ transcript: transcriptText });
    }

    return runtimeResult;
  });

  ipcMain.handle(IPC_CHANNELS.SETTINGS_GET, async (): Promise<SettingsData> => {
    return await requireSettingsStore().get();
  });

  ipcMain.handle(
    IPC_CHANNELS.SETTINGS_UPDATE_SHORTCUTS,
    async (_event, patch: unknown): Promise<SettingsData> => {
      const settings = await requireSettingsStore().update(normalizeSettingsShortcutsPatch(patch));
      registerGlobalShortcuts(settings.shortcuts);
      return settings;
    }
  );

  ipcMain.handle(
    IPC_CHANNELS.SETTINGS_UPDATE_SELECTED_MODEL,
    async (_event, patch: unknown): Promise<SettingsData> => {
      const selectedModelPatch = normalizeSelectedModelPatch(patch);
      const selectedModelId = normalizeSelectedModelId(selectedModelPatch.selectedModelId);
      ensureKnownModelId(selectedModelId);

      const snapshot = await getModelCatalogSnapshot();
      const selectedModelState = normalizeModelDownloadState(snapshot.downloadStates[selectedModelId]);
      if (selectedModelState.status !== 'downloaded') {
        throw new Error(`Model "${selectedModelId}" must be downloaded before selecting it.`);
      }

      return await requireSettingsStore().update({
        modelConfig: {
          selectedModelId
        }
      });
    }
  );

  ipcMain.handle(IPC_CHANNELS.MODELS_LIST, async (): Promise<ModelCatalogSnapshot> => {
    return await getModelCatalogSnapshot();
  });

  ipcMain.handle(IPC_CHANNELS.MODELS_DOWNLOAD, async (_event, request: unknown) => {
    const { modelId } = normalizeModelsDownloadRequest(request);
    return await startModelDownload(modelId);
  });

  ipcMain.handle(
    IPC_CHANNELS.TRANSCRIPT_HISTORY_LIST,
    async (): Promise<TranscriptHistoryEntry[]> => {
      return await requireTranscriptHistoryStore().list();
    }
  );

  ipcMain.handle(IPC_CHANNELS.TRANSCRIPT_HISTORY_CLEAR, async (): Promise<void> => {
    await requireTranscriptHistoryStore().clear();
  });
}

app.whenReady()
  .then(async () => {
    const settings = await initializeStores();
    registerIpcHandlers();
    registerGlobalShortcuts(settings.shortcuts);

    mainWindow = createMainWindow();
    tray = createTray();
    await syncHudWithRuntimeStatus();

    app.on('activate', () => {
      showMainWindow();
    });
  })
  .catch((error) => {
    console.error('KeyScribe main process failed to initialize.', error);
    app.quit();
  });

app.on('before-quit', () => {
  isQuitting = true;
  stopAllModelDownloadTimers();
  popoverWindow?.destroy();
  popoverWindow = null;
  hudWindow?.destroy();
  hudWindow = null;
  globalShortcut.unregisterAll();
  tray?.destroy();
  tray = null;
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
