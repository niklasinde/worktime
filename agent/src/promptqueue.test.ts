import assert from "node:assert/strict";
import { test } from "node:test";
import { PromptQueue } from "./promptqueue.js";
import { userMessage } from "./images.js";

const message = (text: string) => userMessage(text, undefined);
const text = (item: unknown) => (item as { message: { content: string } }).message.content;

test("held messages wait until they are released, in order, and then the queue can end", async () => {
  const queue = new PromptQueue(message("first"));
  const seen: string[] = [];
  const reading = (async () => {
    for await (const item of queue) seen.push(text(item));
  })();
  queue.hold("a", message("second"));
  queue.hold("b", message("third"));
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(seen, ["first"]);
  assert.equal(queue.hasHeld, true);
  assert.deepEqual(queue.release(), ["a", "b"]);
  queue.end();
  await reading;
  assert.deepEqual(seen, ["first", "second", "third"]);
  assert.equal(queue.hasHeld, false);
});

test("a held message can be cancelled until it is released", () => {
  const queue = new PromptQueue(message("first"));
  queue.hold("a", message("second"));
  assert.equal(queue.cancel("a"), true);
  assert.equal(queue.cancel("a"), false);
  queue.hold("b", message("third"));
  assert.deepEqual(queue.drop(), ["b"]);
  assert.deepEqual(queue.release(), []);
});

test("messages ready before the end are still read", async () => {
  const queue = new PromptQueue(message("first"));
  queue.hold("a", message("second"));
  queue.release();
  queue.end();
  const seen: string[] = [];
  for await (const item of queue) seen.push(text(item));
  assert.deepEqual(seen, ["first", "second"]);
  assert.equal(queue.ended, true);
});
