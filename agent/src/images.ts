import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

export type PromptImage = { mediaType: string; data: string };

const mediaTypes = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/// One user message for the SDK: the pictures ahead of the text when there are any.
export function userMessage(text: string, images: unknown): SDKUserMessage {
  const blocks = validImages(images).map(({ mediaType, data }) => ({
    type: "image" as const,
    source: { type: "base64" as const, media_type: mediaType as "image/png", data },
  }));
  return {
    type: "user",
    message: { role: "user", content: blocks.length === 0 ? text : [...blocks, { type: "text", text }] },
    parent_tool_use_id: null,
  };
}

export function validImages(images: unknown): PromptImage[] {
  if (!Array.isArray(images)) return [];
  return images.filter(
    (image): image is PromptImage =>
      typeof image?.mediaType === "string" && mediaTypes.has(image.mediaType) && typeof image.data === "string" && image.data.length > 0,
  );
}
