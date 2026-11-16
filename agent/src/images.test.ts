import assert from "node:assert/strict";
import { test } from "node:test";
import { userMessage, validImages } from "./images.js";

test("a message without images is its text", () => {
  assert.equal(userMessage("hi", undefined).message.content, "hi");
  assert.equal(userMessage("hi", []).message.content, "hi");
});

test("images go ahead of the text in one user message", () => {
  const { message } = userMessage("what is this?", [{ mediaType: "image/png", data: "AAAA" }]);
  assert.equal(message.role, "user");
  assert.deepEqual(message.content, [
    { type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } },
    { type: "text", text: "what is this?" },
  ]);
});

test("entries that are not supported images are dropped", () => {
  const good = { mediaType: "image/jpeg", data: "BBBB" };
  assert.deepEqual(validImages([good, { mediaType: "image/svg+xml", data: "x" }, { mediaType: "image/png", data: "" }, null, "x", { data: "y" }]), [good]);
  assert.equal(userMessage("hi", [{ mediaType: "application/pdf", data: "x" }]).message.content, "hi");
  assert.deepEqual(validImages("nope"), []);
});
