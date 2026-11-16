import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

export type PromptImage = { mediaType: string; data: string };

const mediaTypes = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/// The prompt for the SDK: the text itself, or one user message with the pictures ahead of the text when there are any.
export function promptInput(text: string, images: unknown): string | AsyncIterable<SDKUserMessage> {
  const blocks = validImages(images).map(({ mediaType, data }) => ({
    type: "image" as const,
    source: { type: "base64" as const, media_type: mediaType as "image/png", data },
  }));
  if (blocks.length === 0) return text;
  const message: SDKUserMessage = {
    type: "user",
    message: { role: "user", content: [...blocks, { type: "text", text }] },
    parent_tool_use_id: null,
  };
  return (async function* () {
    yield message;
  })();
}

export function validImages(images: unknown): PromptImage[] {
  if (!Array.isArray(images)) return [];
  return images.filter(
    (image): image is PromptImage =>
      typeof image?.mediaType === "string" && mediaTypes.has(image.mediaType) && typeof image.data === "string" && image.data.length > 0,
  );
}
