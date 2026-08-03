export type FeedbackTone = "tap" | "drag" | "drop" | "success" | "error" | "startup";

let audioContext: AudioContext | null = null;
let masterGainNode: GainNode | null = null;
let compressorNode: DynamicsCompressorNode | null = null;
let startupPlayed = false;
let listenerRefCount = 0;
let removeGlobalListeners: (() => void) | null = null;
let lastTone = "";
let lastToneAtMs = 0;
let feedbackEnabled = true;

function getAudioContextClass() {
  if (typeof window === "undefined") return null;
  return (
    window.AudioContext ||
    (window as typeof window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext ||
    null
  );
}

function ensureAudioGraph() {
  const AudioContextClass = getAudioContextClass();
  if (!AudioContextClass) return null;

  if (!audioContext) {
    audioContext = new AudioContextClass();
  }

  if (!masterGainNode || !compressorNode) {
    compressorNode = audioContext.createDynamicsCompressor();
    compressorNode.threshold.value = -18;
    compressorNode.knee.value = 18;
    compressorNode.ratio.value = 3.2;
    compressorNode.attack.value = 0.003;
    compressorNode.release.value = 0.12;

    masterGainNode = audioContext.createGain();
    masterGainNode.gain.value = 0.5;
    compressorNode.connect(masterGainNode);
    masterGainNode.connect(audioContext.destination);
  }

  return audioContext;
}

function resumeAudioContext() {
  const context = ensureAudioGraph();
  if (!context) return null;
  if (context.state === "suspended") {
    void context.resume();
  }
  return context;
}

function shouldSuppressTone(tone: FeedbackTone) {
  const nowMs = typeof performance !== "undefined" ? performance.now() : Date.now();
  const minimumGapMs = tone === "tap" ? 90 : 50;
  if (tone === lastTone && nowMs - lastToneAtMs < minimumGapMs) {
    return true;
  }
  if (tone === "tap" && nowMs - lastToneAtMs < 55) {
    return true;
  }
  lastTone = tone;
  lastToneAtMs = nowMs;
  return false;
}

function createVoice(
  context: AudioContext,
  {
    type,
    startTime,
    duration,
    fromHz,
    toHz,
    gainPeak,
    filterHz,
    q
  }: {
    type: OscillatorType;
    startTime: number;
    duration: number;
    fromHz: number;
    toHz: number;
    gainPeak: number;
    filterHz: number;
    q: number;
  }
) {
  const oscillator = context.createOscillator();
  const gainNode = context.createGain();
  const filterNode = context.createBiquadFilter();

  oscillator.type = type;
  oscillator.frequency.setValueAtTime(fromHz, startTime);
  oscillator.frequency.exponentialRampToValueAtTime(Math.max(80, toHz), startTime + duration);

  filterNode.type = "lowpass";
  filterNode.frequency.setValueAtTime(filterHz, startTime);
  filterNode.Q.value = q;

  gainNode.gain.setValueAtTime(0.0001, startTime);
  gainNode.gain.exponentialRampToValueAtTime(gainPeak, startTime + Math.min(0.012, duration * 0.3));
  gainNode.gain.exponentialRampToValueAtTime(0.0001, startTime + duration);

  oscillator.connect(filterNode);
  filterNode.connect(gainNode);
  gainNode.connect(compressorNode!);

  oscillator.start(startTime);
  oscillator.stop(startTime + duration + 0.01);
}

function playFeedbackSound(tone: FeedbackTone) {
  if (typeof window === "undefined" || !feedbackEnabled || shouldSuppressTone(tone)) {
    return;
  }

  const context = resumeAudioContext();
  if (!context || !compressorNode) return;

  const now = context.currentTime + 0.003;

  switch (tone) {
    case "tap":
      createVoice(context, {
        type: "triangle",
        startTime: now,
        duration: 0.048,
        fromHz: 1700,
        toHz: 1180,
        gainPeak: 0.028,
        filterHz: 3200,
        q: 1.2
      });
      createVoice(context, {
        type: "sine",
        startTime: now + 0.002,
        duration: 0.04,
        fromHz: 980,
        toHz: 780,
        gainPeak: 0.015,
        filterHz: 2400,
        q: 0.8
      });
      break;
    case "drag":
      createVoice(context, {
        type: "triangle",
        startTime: now,
        duration: 0.03,
        fromHz: 780,
        toHz: 620,
        gainPeak: 0.018,
        filterHz: 1800,
        q: 0.9
      });
      break;
    case "drop":
      createVoice(context, {
        type: "triangle",
        startTime: now,
        duration: 0.06,
        fromHz: 920,
        toHz: 560,
        gainPeak: 0.026,
        filterHz: 2500,
        q: 1.0
      });
      break;
    case "success":
      createVoice(context, {
        type: "sine",
        startTime: now,
        duration: 0.05,
        fromHz: 760,
        toHz: 1040,
        gainPeak: 0.02,
        filterHz: 2800,
        q: 0.7
      });
      createVoice(context, {
        type: "triangle",
        startTime: now + 0.04,
        duration: 0.08,
        fromHz: 1040,
        toHz: 1380,
        gainPeak: 0.024,
        filterHz: 3200,
        q: 0.8
      });
      break;
    case "error":
      createVoice(context, {
        type: "sawtooth",
        startTime: now,
        duration: 0.08,
        fromHz: 340,
        toHz: 180,
        gainPeak: 0.022,
        filterHz: 1400,
        q: 1.4
      });
      break;
    case "startup":
      createVoice(context, {
        type: "sine",
        startTime: now,
        duration: 0.1,
        fromHz: 523.25,
        toHz: 659.25,
        gainPeak: 0.02,
        filterHz: 2400,
        q: 0.7
      });
      createVoice(context, {
        type: "triangle",
        startTime: now + 0.065,
        duration: 0.12,
        fromHz: 659.25,
        toHz: 783.99,
        gainPeak: 0.024,
        filterHz: 2600,
        q: 0.8
      });
      createVoice(context, {
        type: "sine",
        startTime: now + 0.14,
        duration: 0.16,
        fromHz: 783.99,
        toHz: 1046.5,
        gainPeak: 0.026,
        filterHz: 3200,
        q: 0.7
      });
      break;
  }
}

function isPressableElement(target: EventTarget | null) {
  if (!(target instanceof Element)) return false;
  const button = target.closest("button,[role=\"button\"],input[type=\"button\"],input[type=\"submit\"]");
  if (!button) return false;
  if (button instanceof HTMLButtonElement && button.disabled) return false;
  if (button instanceof HTMLInputElement && button.disabled) return false;
  return !button.hasAttribute("data-sound-skip");
}

export function primeUiAudio() {
  resumeAudioContext();
}

export function setUiFeedbackEnabled(enabled: boolean) {
  feedbackEnabled = enabled;
}

export function playStartupFeedback() {
  if (startupPlayed || typeof window === "undefined") return;
  startupPlayed = true;
  window.setTimeout(() => {
    playFeedbackSound("startup");
  }, 480);
}

export function installGlobalButtonFeedback() {
  if (typeof window === "undefined" || typeof document === "undefined") {
    return () => undefined;
  }

  listenerRefCount += 1;
  if (listenerRefCount === 1) {
    const handlePointerDown = (event: PointerEvent) => {
      if (!isPressableElement(event.target)) return;
      lightTapFeedback("tap");
    };

    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        resumeAudioContext();
      }
    };

    document.addEventListener("pointerdown", handlePointerDown, true);
    document.addEventListener("visibilitychange", handleVisibilityChange);
    removeGlobalListeners = () => {
      document.removeEventListener("pointerdown", handlePointerDown, true);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }

  return () => {
    listenerRefCount = Math.max(0, listenerRefCount - 1);
    if (listenerRefCount === 0 && removeGlobalListeners) {
      removeGlobalListeners();
      removeGlobalListeners = null;
    }
  };
}

export function lightTapFeedback(tone: Exclude<FeedbackTone, "startup"> = "tap") {
  navigator.vibrate?.(tone === "drag" ? 12 : 8);
  playFeedbackSound(tone);
}
