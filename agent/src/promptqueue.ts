import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

/// The messages of one run, as the SDK's streaming input. Messages sent while the agent works are held, so they can still be
/// cancelled, until the agent is about to call the model again: then they are released and join the same turn.
export class PromptQueue implements AsyncIterable<SDKUserMessage> {
  private readonly ready: SDKUserMessage[];
  private readonly held = new Map<string, SDKUserMessage>();
  private wake: (() => void) | undefined;
  private closed = false;

  constructor(first: SDKUserMessage) {
    this.ready = [first];
  }

  get hasHeld() {
    return this.held.size > 0;
  }

  get ended() {
    return this.closed;
  }

  hold(id: string, message: SDKUserMessage) {
    this.held.set(id, message);
  }

  cancel(id: string) {
    return this.held.delete(id);
  }

  /// Hands the held messages to the session; their ids.
  release(): string[] {
    const ids = [...this.held.keys()];
    this.ready.push(...this.held.values());
    this.held.clear();
    this.wake?.();
    return ids;
  }

  /// Forgets the held messages; their ids.
  drop(): string[] {
    const ids = [...this.held.keys()];
    this.held.clear();
    return ids;
  }

  /// No more messages: the session finishes what it has and stops.
  end() {
    this.closed = true;
    this.wake?.();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SDKUserMessage> {
    while (true) {
      const next = this.ready.shift();
      if (next) {
        yield next;
      } else if (this.closed) {
        return;
      } else {
        await new Promise<void>((resolve) => (this.wake = resolve));
      }
    }
  }
}
