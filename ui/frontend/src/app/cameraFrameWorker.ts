let decodeBusy = false;
let pendingFrame: ArrayBuffer | null = null;
let frameSequence = 0;

const workerScope = self as unknown as {
  postMessage(message: unknown, transfer: Transferable[]): void;
  onmessage: ((event: MessageEvent<{ type: "frame"; buffer: ArrayBuffer }>) => void) | null;
};

async function decodeFrame(buffer: ArrayBuffer) {
  decodeBusy = true;

  try {
    const bitmap = await createImageBitmap(new Blob([buffer], { type: "image/jpeg" }));
    frameSequence += 1;
    workerScope.postMessage({ type: "bitmap", bitmap, sequence: frameSequence }, [bitmap]);
  } catch {
    workerScope.postMessage({ type: "error" }, []);
  } finally {
    decodeBusy = false;
    const nextFrame = pendingFrame;
    pendingFrame = null;
    if (nextFrame) {
      void decodeFrame(nextFrame);
    }
  }
}

workerScope.onmessage = (event: MessageEvent<{ type: "frame"; buffer: ArrayBuffer }>) => {
  if (event.data.type !== "frame") {
    return;
  }

  if (decodeBusy) {
    pendingFrame = event.data.buffer;
    return;
  }

  void decodeFrame(event.data.buffer);
};

export {};
