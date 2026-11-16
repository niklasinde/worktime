import assert from "node:assert/strict";
import { test } from "node:test";
import { promptInput, validImages } from "./images.js";

test("a prompt without images stays a string", () => {
  assert.equal(promptInput("hi", undefined), "hi");
  assert.equal(promptInput("hi", []), "hi");
});

test("images go ahead of the text in one user message", async () => {
  const input = promptInput("what is this?", [{ mediaType: "image/png", data: "AAAA" }]);
  assert.notEqual(typeof input, "string");
  const messages = [];
  for await (const message of input as AsyncIterable<unknown>) messages.push(message);
  assert.equal(messages.length, 1);
  const { message } = messages[0] as { message: { role: string; content: unknown[] } };
  assert.equal(message.role, "user");
  assert.deepEqual(message.content, [
    { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
    { type: "text", text: "what is this?" },
  ]);
});

test("entries that are not supported images are dropped", () => {
  const good = { mediaType: "image/jpeg", data: "BBBB" };
  assert.deepEqual(validImages([good, { mediaType: "image/svg+xml", data: "x" }, { mediaType: "image/png", data: "" }, null, "x", { data: "y" }]), [good]);
  assert.equal(promptInput("hi", [{ mediaType: "application/pdf", data: "x" }]), "hi");
  assert.deepEqual(validImages("nope"), []);
});
