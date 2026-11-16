/// Streams the model's text to the app as it is generated: the SDK's text deltas, coalesced so the app gets at most one
/// `text_delta` per interval. The first delta goes out at once; the complete `assistant` message still arrives as `text`
/// and replaces what was streamed.
export class TextStream {
  private pending = "";
  private lastSent = 0;
  private timer: NodeJS.Timeout | undefined;

  constructor(private readonly emit: (message: Record<string, unknown>) => void, private readonly interval = 40, private readonly now = Date.now) {}

  /// Takes a `stream_event` message; only the main agent's text deltas are streamed.
  receive(message: any) {
    const event = message?.event;
    if (message?.parent_tool_use_id || event?.type !== "content_block_delta" || event.delta?.type !== "text_delta" || !event.delta.text) return;
    this.pending += event.delta.text;
    const wait = this.lastSent + this.interval - this.now();
    if (wait <= 0) return this.flush();
    this.timer ??= setTimeout(() => this.flush(), wait);
  }

  /// Sends what is waiting; called before any other message is forwarded so the order is kept.
  flush() {
    clearTimeout(this.timer);
    this.timer = undefined;
    if (!this.pending) return;
    const text = this.pending;
    this.pending = "";
    this.lastSent = this.now();
    this.emit({ type: "text_delta", text });
  }
}
