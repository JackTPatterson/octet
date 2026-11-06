/** Keeps the last `capacity` bytes of a pty's output for replay on attach. */
export class RingBuffer {
  private chunks: Array<Buffer> = [];
  private size = 0;
  private readonly capacity: number;

  constructor(capacity: number) {
    this.capacity = capacity;
  }

  append(chunk: Buffer): void {
    if (chunk.length === 0) return;
    if (chunk.length >= this.capacity) {
      this.chunks = [chunk.subarray(chunk.length - this.capacity)];
      this.size = this.capacity;
      return;
    }
    this.chunks.push(chunk);
    this.size += chunk.length;
    while (this.size > this.capacity) {
      const first = this.chunks[0]!;
      const excess = this.size - this.capacity;
      if (first.length <= excess) {
        this.chunks.shift();
        this.size -= first.length;
      } else {
        this.chunks[0] = first.subarray(excess);
        this.size -= excess;
      }
    }
  }

  contents(): Buffer {
    return Buffer.concat(this.chunks, this.size);
  }

  get length(): number {
    return this.size;
  }
}
