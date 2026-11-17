/// What the user answered to a question about a tool the assistant's list leaves out; `timedOut` when nobody answered in time.
export type RoleAnswer = { allow: boolean; add: boolean; session: boolean; message?: string; timedOut?: boolean };

export type Timers = { set(run: () => void, ms: number): unknown; clear(timer: unknown): void };

const realTimers: Timers = { set: (run, ms) => setTimeout(run, ms), clear: (timer) => clearTimeout(timer as NodeJS.Timeout) };

export const timeoutMessage = (tool: string) =>
  `${tool} is not one of this assistant's tools, and nobody answered the question about adding it in time. Carry on without it, or say what could not be done.`;

/// The questions about missing tools that wait for the user. An interactive turn waits for as long as the user takes; an unattended
/// run waits for a bounded time, then goes on as if the user had denied the call.
export class RoleWaits {
  private waiting = new Map<string, { resolve: (answer: RoleAnswer) => void; timer?: unknown }>();

  constructor(private readonly timers: Timers = realTimers) {}

  get size() { return this.waiting.size; }

  has(id: string) { return this.waiting.has(id); }

  ask(id: string, tool: string, limitMs: number | undefined, onTimeout: () => void = () => {}): Promise<RoleAnswer> {
    return new Promise((resolve) => {
      const timer = limitMs && limitMs > 0 ? this.timers.set(() => {
        if (this.waiting.delete(id)) {
          onTimeout();
          resolve({ allow: false, add: false, session: false, message: timeoutMessage(tool), timedOut: true });
        }
      }, limitMs) : undefined;
      this.waiting.set(id, { resolve, timer });
    });
  }

  answer(id: string, answer: RoleAnswer): boolean {
    const entry = this.waiting.get(id);
    if (!entry) return false;
    this.waiting.delete(id);
    if (entry.timer !== undefined) this.timers.clear(entry.timer);
    entry.resolve(answer);
    return true;
  }

  /// Ends every question, as when the prompt ends or the user stops the agent.
  denyAll(message: string) {
    for (const id of [...this.waiting.keys()]) this.answer(id, { allow: false, add: false, session: false, message });
  }
}
