const modelFields = ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "costUSD"] as const;
const mainLoopFields = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] as const;

const number = (value: unknown): number | undefined => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

function pick<T extends string>(source: unknown, fields: readonly T[]): Partial<Record<T, number>> {
  const object = source && typeof source === "object" ? (source as Record<string, unknown>) : {};
  const picked: Partial<Record<T, number>> = {};
  for (const field of fields) {
    const value = number(object[field]);
    if (value !== undefined) picked[field] = value;
  }
  return picked;
}

/// What a result message says about the cost of the turn, reduced to numbers the app reads. `modelUsage` is the SDK's field for cost and
/// tokens: every model call of the query, subagents and compaction included, cumulative across the turns of one query. `usage` is the
/// main loop only and is kept for a result that carries no `modelUsage`. Undefined when the message holds no number at all.
export function usageFrom(message: Record<string, unknown>): Record<string, unknown> | undefined {
  const models: Record<string, unknown> = {};
  const reported = message.modelUsage && typeof message.modelUsage === "object" ? (message.modelUsage as Record<string, unknown>) : {};
  for (const [name, entry] of Object.entries(reported)) {
    const fields = pick(entry, modelFields);
    if (Object.keys(fields).length > 0) models[name] = fields;
  }
  const usage = pick(message.usage, mainLoopFields);
  const found = {
    total_cost_usd: number(message.total_cost_usd),
    duration_ms: number(message.duration_ms),
    num_turns: number(message.num_turns),
    ...(Object.keys(models).length > 0 ? { modelUsage: models } : {}),
    ...(Object.keys(usage).length > 0 ? { usage } : {}),
  };
  const defined = Object.fromEntries(Object.entries(found).filter(([, value]) => value !== undefined));
  return Object.keys(defined).length > 0 ? defined : undefined;
}

const windows = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] as const;
const text = (value: unknown): string | undefined => (typeof value === "string" && value.length > 0 ? value : undefined);

function window(source: unknown): Record<string, unknown> | undefined {
  if (!source || typeof source !== "object") return undefined;
  const object = source as Record<string, unknown>;
  const picked = { utilization: number(object.utilization), resets_at: text(object.resets_at) };
  const defined = Object.fromEntries(Object.entries(picked).filter(([, value]) => value !== undefined));
  return Object.keys(defined).length > 0 ? defined : undefined;
}

/// The plan's limits from the SDK's `/usage` answer: the subscription, how full each window is and when it resets, per-model windows and
/// extra usage. The answer's session totals and its scan of local transcripts are left out. Undefined when plan limits do not apply.
export function planFrom(answer: Record<string, unknown>): Record<string, unknown> | undefined {
  const limits = answer.rate_limits;
  if (answer.rate_limits_available !== true || !limits || typeof limits !== "object") return undefined;
  const source = limits as Record<string, unknown>;
  const picked: Record<string, unknown> = {};
  for (const name of windows) {
    const found = window(source[name]);
    if (found) picked[name] = found;
  }
  const scoped = Array.isArray(source.model_scoped) ? source.model_scoped : [];
  const models = scoped.flatMap((entry) => {
    const found = window(entry);
    const name = entry && typeof entry === "object" ? text((entry as Record<string, unknown>).display_name) : undefined;
    return name && found ? [{ display_name: name, ...found }] : [];
  });
  if (models.length > 0) picked.model_scoped = models;
  const extra = source.extra_usage && typeof source.extra_usage === "object" ? (source.extra_usage as Record<string, unknown>) : undefined;
  if (extra && extra.is_enabled === true) {
    const fields = { monthly_limit: number(extra.monthly_limit), used_credits: number(extra.used_credits), utilization: number(extra.utilization), currency: text(extra.currency) };
    picked.extra_usage = { is_enabled: true, ...Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined)) };
  }
  return { subscription: text(answer.subscription_type), limits: picked };
}
