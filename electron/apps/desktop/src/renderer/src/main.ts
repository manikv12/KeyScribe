function byId<TElement extends HTMLElement>(id: string): TElement {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing required element: ${id}`);
  }

  return element as TElement;
}

function capStatus(isAvailable: boolean): string {
  return isAvailable ? 'available' : 'unavailable';
}

type RuntimeActionResult = Awaited<ReturnType<typeof window.keyscribe.runtimeStartDictation>>;
type RuntimeStatusResult = Awaited<ReturnType<typeof window.keyscribe.runtimeGetStatus>>;
type TranscriptHistoryEntry = Awaited<ReturnType<typeof window.keyscribe.transcriptHistoryList>>[number];

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message;
  }

  return String(error);
}

function formatRuntimeResult(result: RuntimeActionResult | RuntimeStatusResult): string {
  const state = result.ok ? result.status : `error: ${result.status}`;
  return result.reason ? `${state} (${result.reason})` : state;
}

function formatDictationState(status: RuntimeStatusResult): string {
  if (typeof status.isDictating === 'boolean') {
    return status.isDictating ? 'Dictation is running.' : 'Dictation is idle.';
  }

  return `Runtime status: ${status.status}.`;
}

function renderTranscriptHistory(
  historyEl: HTMLUListElement,
  transcriptSummaryEl: HTMLParagraphElement,
  entries: TranscriptHistoryEntry[]
): void {
  historyEl.innerHTML = '';

  if (entries.length === 0) {
    const item = document.createElement('li');
    item.className = 'transcript-item transcript-item--placeholder';
    item.textContent = 'No transcript entries yet.';
    historyEl.append(item);
    transcriptSummaryEl.textContent = 'No transcript entries saved.';
    return;
  }

  for (const entry of entries) {
    const item = document.createElement('li');
    item.className = 'transcript-item';
    const createdAt = new Date(entry.createdAt);
    const stamp = Number.isNaN(createdAt.getTime())
      ? entry.createdAt
      : createdAt.toLocaleString();
    item.textContent = `${stamp} - ${entry.transcript}`;
    historyEl.append(item);
  }

  const noun = entries.length === 1 ? 'entry' : 'entries';
  transcriptSummaryEl.textContent = `${entries.length} transcript ${noun}.`;
}

async function renderAppInfo(): Promise<void> {
  const appInfoEl = byId<HTMLParagraphElement>('app-info');
  const appBuildEl = byId<HTMLParagraphElement>('app-build');
  const runtimePingEl = byId<HTMLParagraphElement>('runtime-ping');
  const runtimeCapabilitiesEl = byId<HTMLParagraphElement>('runtime-capabilities');
  const dictationStateEl = byId<HTMLParagraphElement>('dictation-state');
  const dictationDetailEl = byId<HTMLParagraphElement>('dictation-detail');
  const transcriptHistoryEl = byId<HTMLUListElement>('transcript-history');
  const transcriptSummaryEl = byId<HTMLParagraphElement>('transcript-summary');
  const statusEl = byId<HTMLParagraphElement>('status');
  const openSettingsButton = byId<HTMLButtonElement>('open-settings');
  const refreshRuntimeStatusButton = byId<HTMLButtonElement>('refresh-runtime-status');
  const startDictationButton = byId<HTMLButtonElement>('start-dictation');
  const stopDictationButton = byId<HTMLButtonElement>('stop-dictation');
  const insertTextButton = byId<HTMLButtonElement>('insert-text');
  const insertTextInput = byId<HTMLInputElement>('insert-text-input');
  const refreshHistoryButton = byId<HTMLButtonElement>('refresh-history');
  const clearHistoryButton = byId<HTMLButtonElement>('clear-history');

  const actionButtons = [
    refreshRuntimeStatusButton,
    openSettingsButton,
    startDictationButton,
    stopDictationButton,
    insertTextButton,
    refreshHistoryButton,
    clearHistoryButton
  ];

  let capabilities: Awaited<ReturnType<typeof window.keyscribe.getRuntimeCapabilities>> | null = null;

  const setBusy = (busy: boolean): void => {
    for (const button of actionButtons) {
      button.disabled = busy;
    }
  };

  const refreshRuntimeStatus = async (announceFailure: boolean): Promise<void> => {
    try {
      const runtimeStatus = await window.keyscribe.runtimeGetStatus();
      dictationStateEl.textContent = formatDictationState(runtimeStatus);
      dictationDetailEl.textContent = formatRuntimeResult(runtimeStatus);
    } catch (error) {
      dictationStateEl.textContent = 'Runtime status unavailable.';
      dictationDetailEl.textContent = errorMessage(error);
      if (announceFailure) {
        statusEl.textContent = `Failed to refresh runtime status: ${errorMessage(error)}`;
      }
    }
  };

  const refreshTranscriptHistory = async (announceFailure: boolean): Promise<void> => {
    try {
      const entries = await window.keyscribe.transcriptHistoryList();
      renderTranscriptHistory(transcriptHistoryEl, transcriptSummaryEl, entries);
    } catch (error) {
      transcriptHistoryEl.innerHTML = '';
      const item = document.createElement('li');
      item.className = 'transcript-item transcript-item--placeholder';
      item.textContent = 'Transcript history unavailable.';
      transcriptHistoryEl.append(item);
      transcriptSummaryEl.textContent = 'Unable to load transcript history.';
      if (announceFailure) {
        statusEl.textContent = `Failed to load transcript history: ${errorMessage(error)}`;
      }
    }
  };

  const handleInsertText = async (): Promise<void> => {
    const text = insertTextInput.value.trim();
    if (text.length === 0) {
      statusEl.textContent = 'Enter some text before inserting.';
      return;
    }

    statusEl.textContent = 'Inserting text...';
    setBusy(true);
    try {
      const result = await window.keyscribe.runtimeInsertText(text);
      statusEl.textContent = `Insert text: ${formatRuntimeResult(result)}`;
      insertTextInput.value = '';
      await refreshTranscriptHistory(false);
      await refreshRuntimeStatus(false);
    } catch (error) {
      statusEl.textContent = `Failed to insert text: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  };

  try {
    const appInfo = await window.keyscribe.getAppInfo();
    appInfoEl.textContent = `${appInfo.name} v${appInfo.version}`;
    appBuildEl.textContent = `${appInfo.platform} • ${appInfo.isPackaged ? 'Packaged build' : 'Development build'}`;
  } catch {
    appInfoEl.textContent = 'Unable to load app information.';
    appBuildEl.textContent = 'Build details unavailable.';
  }

  try {
    const ping = await window.keyscribe.runtimePing();
    if (ping.ok && ping.sidecarConnected) {
      runtimePingEl.textContent = `Runtime ping OK at ${new Date(ping.timestampMs).toLocaleTimeString()}`;
    } else if (ping.ok) {
      runtimePingEl.textContent = `Runtime ping OK (fallback runtime): ${ping.message ?? 'native sidecar unavailable'}`;
    } else {
      runtimePingEl.textContent = `Runtime ping unavailable: ${ping.message ?? 'sidecar not connected'}`;
    }
  } catch {
    runtimePingEl.textContent = 'Runtime ping failed.';
  }

  try {
    capabilities = await window.keyscribe.getRuntimeCapabilities();
    runtimeCapabilitiesEl.textContent = `Capabilities: appleSpeech=${capabilities.appleSpeechAvailable}, whisper=${capabilities.whisperAvailable}, caretBounds=${capabilities.caretBoundsAvailable}`;
  } catch {
    runtimeCapabilitiesEl.textContent = 'Runtime capabilities unavailable.';
  }

  openSettingsButton.addEventListener('click', async () => {
    statusEl.textContent = 'Opening settings window...';
    setBusy(true);

    try {
      await window.keyscribe.openSettingsWindow();
      statusEl.textContent = 'Settings window opened.';
    } catch {
      statusEl.textContent = 'Failed to open settings window.';
    } finally {
      setBusy(false);
    }
  });

  refreshRuntimeStatusButton.addEventListener('click', async () => {
    statusEl.textContent = 'Refreshing runtime status...';
    setBusy(true);
    try {
      await refreshRuntimeStatus(false);
      statusEl.textContent = 'Runtime status refreshed.';
    } finally {
      setBusy(false);
    }
  });

  startDictationButton.addEventListener('click', async () => {
    const capabilitySummary = capabilities
      ? `appleSpeech ${capStatus(capabilities.appleSpeechAvailable)}, whisper ${capStatus(capabilities.whisperAvailable)}.`
      : 'Runtime capabilities unknown.';
    statusEl.textContent = `Starting dictation... (${capabilitySummary})`;
    setBusy(true);
    try {
      const result = await window.keyscribe.runtimeStartDictation();
      statusEl.textContent = `Start dictation: ${formatRuntimeResult(result)}`;
      await refreshRuntimeStatus(false);
      await refreshTranscriptHistory(false);
    } catch (error) {
      statusEl.textContent = `Failed to start dictation: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  });

  stopDictationButton.addEventListener('click', async () => {
    statusEl.textContent = 'Stopping dictation...';
    setBusy(true);
    try {
      const result = await window.keyscribe.runtimeStopDictation();
      statusEl.textContent = `Stop dictation: ${formatRuntimeResult(result)}`;
      await refreshRuntimeStatus(false);
      await refreshTranscriptHistory(false);
    } catch (error) {
      statusEl.textContent = `Failed to stop dictation: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  });

  insertTextButton.addEventListener('click', () => {
    void handleInsertText();
  });

  insertTextInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      void handleInsertText();
    }
  });

  refreshHistoryButton.addEventListener('click', async () => {
    statusEl.textContent = 'Refreshing transcript history...';
    setBusy(true);
    try {
      await refreshTranscriptHistory(false);
      statusEl.textContent = 'Transcript history refreshed.';
    } finally {
      setBusy(false);
    }
  });

  clearHistoryButton.addEventListener('click', async () => {
    statusEl.textContent = 'Clearing transcript history...';
    setBusy(true);
    try {
      await window.keyscribe.transcriptHistoryClear();
      await refreshTranscriptHistory(false);
      statusEl.textContent = 'Transcript history cleared.';
    } catch (error) {
      statusEl.textContent = `Failed to clear transcript history: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  });

  await refreshRuntimeStatus(false);
  await refreshTranscriptHistory(false);
}

void renderAppInfo();

export {};
