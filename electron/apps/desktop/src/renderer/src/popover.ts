function byId<TElement extends HTMLElement>(id: string): TElement {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing required element: ${id}`);
  }

  return element as TElement;
}

type RuntimeActionResult = Awaited<ReturnType<typeof window.keyscribe.runtimeStartDictation>>;
type RuntimeStatusResult = Awaited<ReturnType<typeof window.keyscribe.runtimeGetStatus>>;

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

function isDictating(status: RuntimeStatusResult): boolean {
  return status.isDictating ?? status.status === 'dictating';
}

function formatDictationLabel(dictating: boolean): string {
  return dictating ? 'Dictation is running' : 'Dictation is idle';
}

function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) {
    return text;
  }

  return `${text.slice(0, maxLength - 1).trimEnd()}…`;
}

function setBadgeState(element: HTMLElement, state: 'active' | 'idle' | 'error'): void {
  element.classList.remove('status-badge--active', 'status-badge--idle', 'status-badge--error');
  element.classList.add(
    state === 'active'
      ? 'status-badge--active'
      : state === 'error'
        ? 'status-badge--error'
        : 'status-badge--idle'
  );
}

async function initPopover(): Promise<void> {
  const runtimeStatusEl = byId<HTMLParagraphElement>('popover-runtime-status');
  const runtimeDetailEl = byId<HTMLParagraphElement>('popover-runtime-detail');
  const transcriptPreviewEl = byId<HTMLParagraphElement>('popover-transcript-preview');
  const statusEl = byId<HTMLParagraphElement>('popover-status');
  const startButton = byId<HTMLButtonElement>('popover-start-dictation');
  const stopButton = byId<HTMLButtonElement>('popover-stop-dictation');
  const openSettingsButton = byId<HTMLButtonElement>('popover-open-settings');
  const refreshPreviewButton = byId<HTMLButtonElement>('popover-refresh-preview');

  const actionButtons = [startButton, stopButton, openSettingsButton, refreshPreviewButton];

  let busy = false;
  let dictating = false;

  const syncButtonState = (): void => {
    startButton.disabled = busy || dictating;
    stopButton.disabled = busy || !dictating;
    openSettingsButton.disabled = busy;
    refreshPreviewButton.disabled = busy;
  };

  const setBusy = (isBusy: boolean): void => {
    busy = isBusy;
    for (const button of actionButtons) {
      button.disabled = isBusy;
    }
    syncButtonState();
  };

  const refreshRuntimeStatus = async (announceFailure: boolean): Promise<void> => {
    try {
      const runtimeStatus = await window.keyscribe.runtimeGetStatus();
      dictating = isDictating(runtimeStatus);
      runtimeStatusEl.textContent = formatDictationLabel(dictating);
      runtimeDetailEl.textContent = formatRuntimeResult(runtimeStatus);
      setBadgeState(runtimeStatusEl, dictating ? 'active' : 'idle');
    } catch (error) {
      dictating = false;
      runtimeStatusEl.textContent = 'Runtime unavailable';
      runtimeDetailEl.textContent = errorMessage(error);
      setBadgeState(runtimeStatusEl, 'error');
      if (announceFailure) {
        statusEl.textContent = `Failed to read runtime status: ${errorMessage(error)}`;
      }
    } finally {
      syncButtonState();
    }
  };

  const refreshTranscriptPreview = async (announceFailure: boolean): Promise<void> => {
    try {
      const entries = await window.keyscribe.transcriptHistoryList();
      const latest = entries.at(0);
      if (!latest) {
        transcriptPreviewEl.classList.add('transcript-preview--placeholder');
        transcriptPreviewEl.textContent = 'No transcript snippets yet.';
        return;
      }

      const createdAt = new Date(latest.createdAt);
      const timestamp = Number.isNaN(createdAt.getTime())
        ? latest.createdAt
        : createdAt.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      transcriptPreviewEl.classList.remove('transcript-preview--placeholder');
      transcriptPreviewEl.textContent = `${timestamp}: ${truncate(latest.transcript, 180)}`;
    } catch (error) {
      transcriptPreviewEl.classList.add('transcript-preview--placeholder');
      transcriptPreviewEl.textContent = 'Transcript preview unavailable.';
      if (announceFailure) {
        statusEl.textContent = `Failed to load transcript preview: ${errorMessage(error)}`;
      }
    }
  };

  const runAction = async (
    message: string,
    action: () => Promise<RuntimeActionResult>,
    successPrefix: string
  ): Promise<void> => {
    statusEl.textContent = message;
    setBusy(true);
    try {
      const result = await action();
      statusEl.textContent = `${successPrefix}: ${formatRuntimeResult(result)}`;
      await Promise.all([refreshRuntimeStatus(false), refreshTranscriptPreview(false)]);
    } catch (error) {
      statusEl.textContent = `${successPrefix} failed: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  };

  startButton.addEventListener('click', () => {
    void runAction('Starting dictation...', () => window.keyscribe.runtimeStartDictation(), 'Start');
  });

  stopButton.addEventListener('click', () => {
    void runAction('Stopping dictation...', () => window.keyscribe.runtimeStopDictation(), 'Stop');
  });

  openSettingsButton.addEventListener('click', async () => {
    statusEl.textContent = 'Opening settings...';
    setBusy(true);
    try {
      await window.keyscribe.openSettingsWindow();
      statusEl.textContent = 'Settings opened.';
    } catch (error) {
      statusEl.textContent = `Could not open settings: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  });

  refreshPreviewButton.addEventListener('click', async () => {
    statusEl.textContent = 'Refreshing preview...';
    setBusy(true);
    try {
      await Promise.all([refreshRuntimeStatus(false), refreshTranscriptPreview(false)]);
      statusEl.textContent = 'Preview refreshed.';
    } finally {
      setBusy(false);
    }
  });

  setBusy(true);
  await Promise.all([refreshRuntimeStatus(false), refreshTranscriptPreview(false)]);
  statusEl.textContent = 'Ready.';
  setBusy(false);

  const pollIntervalMs = 4000;
  const intervalId = window.setInterval(() => {
    void Promise.all([refreshRuntimeStatus(false), refreshTranscriptPreview(false)]);
  }, pollIntervalMs);

  window.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      void Promise.all([refreshRuntimeStatus(false), refreshTranscriptPreview(false)]);
    }
  });

  window.addEventListener('beforeunload', () => {
    window.clearInterval(intervalId);
  });
}

void initPopover();

export {};
