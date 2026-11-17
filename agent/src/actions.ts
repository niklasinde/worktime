const fence = "```";

/// What every agent is told about offering a next step as buttons; the app reads these blocks in `AgentActionLogic.swift`.
export const actionInstructions = [
  "When you offer a next step that you or another agent could carry out (for example \"I can have the Reviewer check this\"), write it as a block the app shows as buttons instead of asking in prose:",
  "",
  `${fence}worktime-action`,
  "title: <a short label, under 120 characters>",
  "assistant: <an assistant's role name from your list, only when one fits>",
  "prompt: |",
  "  <the complete instructions: what to do, which pull request, ticket or files, what to report back. Whoever runs it has not seen this conversation.>",
  fence,
  "",
  "Keep the sentence before the block short. The user clicks Do it here (you get the prompt as their next message) or Ask an assistant (the assistant gets it); nothing runs until they click. " +
    "Never ask anyone in the prompt to approve, merge, post or send on the user's behalf: ask for a draft instead. Write a block only for a step worth taking, at most three.",
].join("\n");
