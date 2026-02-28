function byId<TElement extends HTMLElement>(id: string): TElement {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing required element: ${id}`);
  }

  return element as TElement;
}

type RuntimeActionResult = Awaited<ReturnType<typeof window.keyscribe.runtimeStopDictation>>;
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

function randomLevel(min: number, max: number): number {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

async function initHud(): Promise<void> {
  const shellEl = byId<HTMLElement>('hud-meter').closest('.hud-shell');
  if (!shellEl) {
    throw new Error('Missing HUD shell element.');
  }

  const meterEl = byId<HTMLDivElement>('hud-meter');
  const meterFillEl = byId<HTMLDivElement>('hud-meter-fill');
  const statusEl = byId<HTMLParagraphElement>('hud-status');
  const detailEl = byId<HTMLParagraphElement>('hud-detail');
  const stopButton = byId<HTMLButtonElement>('hud-stop-dictation');

  let busy = false;
  let dictating = false;
  let currentLevel = 0;

  const setLevel = (next: number): void => {
    currentLevel = Math.max(0, Math.min(100, next));
    meterFillEl.style.width = `${currentLevel}%`;
    meterEl.setAttribute('aria-valuenow', String(currentLevel));
  };

  const syncControls = (): void => {
    stopButton.disabled = busy || !dictating;
    shellEl.classList.toggle('hud-shell--active', dictating);
  };

  const setBusy = (isBusy: boolean): void => {
    busy = isBusy;
    syncControls();
  };

  const refreshRuntimeStatus = async (announceFailure: boolean): Promise<void> => {
    try {
      const status = await window.keyscribe.runtimeGetStatus();
      dictating = isDictating(status);
      statusEl.textContent = dictating ? 'Dictation is running' : 'Dictation is idle';
      detailEl.textContent = formatRuntimeResult(status);
    } catch (error) {
      dictating = false;
      statusEl.textContent = 'Runtime unavailable';
      detailEl.textContent = errorMessage(error);
      if (announceFailure) {
        detailEl.textContent = `Status refresh failed: ${errorMessage(error)}`;
      }
    } finally {
      syncControls();
    }
  };

  stopButton.addEventListener('click', async () => {
    detailEl.textContent = 'Stopping dictation...';
    setBusy(true);
    try {
      const result = await window.keyscribe.runtimeStopDictation();
      detailEl.textContent = `Stop: ${formatRuntimeResult(result)}`;
      await refreshRuntimeStatus(false);
    } catch (error) {
      detailEl.textContent = `Stop failed: ${errorMessage(error)}`;
    } finally {
      setBusy(false);
    }
  });

  setBusy(true);
  await refreshRuntimeStatus(false);
  setBusy(false);

  const statusPollIntervalMs = 2200;
  const statusPollId = window.setInterval(() => {
    void refreshRuntimeStatus(false);
  }, statusPollIntervalMs);

  const meterAnimationIntervalMs = 220;
  const meterAnimationId = window.setInterval(() => {
    if (!dictating) {
      setLevel(currentLevel > 10 ? currentLevel - 8 : 10);
      return;
    }

    const min = Math.max(18, currentLevel - 22);
    const max = Math.min(100, currentLevel + 28);
    setLevel(randomLevel(min, max));
  }, meterAnimationIntervalMs);

  window.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      void refreshRuntimeStatus(false);
    }
  });

  window.addEventListener('beforeunload', () => {
    window.clearInterval(statusPollId);
    window.clearInterval(meterAnimationId);
  });
}

void initHud();

export {};
