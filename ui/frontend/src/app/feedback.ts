export type FeedbackTone = "tap" | "drag" | "drop" | "success" | "error";

let audioContext: AudioContext | null = null;

function playFeedbackSound(tone: FeedbackTone) {
  if (typeof window === "undefined") {
    return;
  }

  const AudioContextClass =
    window.AudioContext ||
    (window as typeof window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!AudioContextClass) {
    return;
  }

  if (!audioContext) {
    audioContext = new AudioContextClass();
  }

  const context = audioContext;
  if (context.state === "suspended") {
    void context.resume();
  }

  const oscillator = context.createOscillator();
  const gainNode = context.createGain();
  const now = context.currentTime;
  const frequency =
    tone === "success" ? 920 :
    tone === "error" ? 220 :
    tone === "drop" ? 560 :
    tone === "drag" ? 680 : 760;

  oscillator.type = tone === "error" ? "sawtooth" : "triangle";
  oscillator.frequency.setValueAtTime(frequency, now);
  oscillator.frequency.exponentialRampToValueAtTime(Math.max(140, frequency * 0.78), now + 0.045);
  gainNode.gain.setValueAtTime(0.0001, now);
  gainNode.gain.exponentialRampToValueAtTime(0.028, now + 0.008);
  gainNode.gain.exponentialRampToValueAtTime(0.0001, now + 0.055);

  oscillator.connect(gainNode);
  gainNode.connect(context.destination);
  oscillator.start(now);
  oscillator.stop(now + 0.06);
}

export function lightTapFeedback(tone: FeedbackTone = "tap") {
  navigator.vibrate?.(tone === "drag" ? 12 : 8);
  playFeedbackSound(tone);
}
