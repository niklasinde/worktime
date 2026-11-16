import assert from "node:assert/strict";
import { test } from "node:test";
import { TextStream } from "./stream.js";

const delta = (text: string, extra: Record<string, unknown> = {}) =>
  ({ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }, ...extra });

function setup(interval = 40) {
  const sent: Record<string, unknown>[] = [];
  let clock = 1000;
  const stream = new TextStream((message) => sent.push(message), interval, () => clock);
  return { sent, stream, advance: (ms: number) => (clock += ms) };
}

test("the first delta goes out at once and later ones are coalesced into one message", async () => {
  const { sent, stream, advance } = setup(20);
  stream.receive(delta("Hel"));
  assert.deepEqual(sent, [{ type: "text_delta", text: "Hel" }]);
  advance(5);
  stream.receive(delta("lo "));
  stream.receive(delta("world"));
  assert.equal(sent.length, 1, "held back inside the interval");
  advance(20);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.deepEqual(sent.at(-1), { type: "text_delta", text: "lo world" });
  assert.equal(sent.length, 2);
});

test("flush sends what is waiting so it precedes the next message, and only once", () => {
  const { sent, stream, advance } = setup();
  stream.receive(delta("a"));
  advance(1);
  stream.receive(delta("b"));
  stream.flush();
  stream.flush();
  assert.deepEqual(sent.map((message) => message.text), ["a", "b"]);
});

test("only the main agent's text deltas are streamed", () => {
  const { sent, stream } = setup();
  stream.receive(delta("sub-agent", { parent_tool_use_id: "toolu_1" }));
  stream.receive({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "thinking_delta", thinking: "hm" } } });
  stream.receive({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: "{" } } });
  stream.receive({ type: "stream_event", event: { type: "message_start" } });
  stream.receive(delta(""));
  stream.flush();
  assert.deepEqual(sent, []);
});
