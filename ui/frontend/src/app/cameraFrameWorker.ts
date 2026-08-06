type FrameRequest = {
  type: "frame";
  buffer: ArrayBuffer;
  requestMs: number;
  sourceAgeMs: number;
  bytes: number;
};

let decodeBusy = false;
let pendingFrame: FrameRequest | null = null;
let frameSequence = 0;
let droppedFrames = 0;

const workerScope = self as unknown as {
  postMessage(message: unknown, transfer: Transferable[]): void;
  onmessage: ((event: MessageEvent<FrameRequest>) => void) | null;
};

async function decodeFrame(frame: FrameRequest) {
  decodeBusy = true;
  const startedAt = performance.now();

  try {
    const bitmap = await createImageBitmap(new Blob([frame.buffer], { type: "image/jpeg" }));
    frameSequence += 1;
    workerScope.postMessage({
      type: "bitmap",
      bitmap,
      sequence: frameSequence,
      decodeMs: performance.now() - startedAt,
      droppedFrames,
      requestMs: frame.requestMs,
      sourceAgeMs: frame.sourceAgeMs,
      bytes: frame.bytes
    }, [bitmap]);
    droppedFrames = 0;
  } catch {
    workerScope.postMessage({ type: "error" }, []);
  } finally {
    decodeBusy = false;
    const nextFrame = pendingFrame;
    pendingFrame = null;
    if (nextFrame) void decodeFrame(nextFrame);
  }
}

workerScope.onmessage = (event: MessageEvent<FrameRequest>) => {
  if (event.data.type !== "frame") return;

  if (decodeBusy) {
    if (pendingFrame) droppedFrames += 1;
    pendingFrame = event.data;
    return;
  }

  void decodeFrame(event.data);
};

export {};
