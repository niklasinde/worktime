import assert from "node:assert/strict";
import { test } from "node:test";
import { usageFrom } from "./usage.js";

const result = {
  type: "result",
  subtype: "success",
  result: "a long answer that must not travel",
  total_cost_usd: 0.4321,
  duration_ms: 18_500,
  duration_api_ms: 15_000,
  num_turns: 3,
  usage: { input_tokens: 120, output_tokens: 900, cache_read_input_tokens: 40_000, cache_creation_input_tokens: 2_000, service_tier: "standard" },
  modelUsage: {
    "claude-sonnet-5-5": { inputTokens: 100, outputTokens: 800, cacheReadInputTokens: 30_000, cacheCreationInputTokens: 1_500, costUSD: 0.3, contextWindow: 200_000 },
    "claude-haiku-5-5": { inputTokens: 20, outputTokens: 100, cacheReadInputTokens: 10_000, cacheCreationInputTokens: 500, costUSD: 0.1321, webSearchRequests: 0 },
  },
};

test("the usage of a result is the cost, the per-model totals, the main loop and the turn's size, without the answer", () => {
  const usage = usageFrom(result) as Record<string, any>;
  assert.equal(usage.total_cost_usd, 0.4321);
  assert.equal(usage.duration_ms, 18_500);
  assert.equal(usage.num_turns, 3);
  assert.deepEqual(Object.keys(usage.modelUsage), ["claude-sonnet-5-5", "claude-haiku-5-5"]);
  assert.deepEqual(usage.modelUsage["claude-haiku-5-5"], { inputTokens: 20, outputTokens: 100, cacheReadInputTokens: 10_000, cacheCreationInputTokens: 500, costUSD: 0.1321 });
  assert.deepEqual(usage.usage, { input_tokens: 120, output_tokens: 900, cache_read_input_tokens: 40_000, cache_creation_input_tokens: 2_000 });
  assert.ok(!JSON.stringify(usage).includes("answer"), "nothing of the text is forwarded");
});

test("a result without model usage keeps the main loop's tokens and the cost", () => {
  const usage = usageFrom({ total_cost_usd: 0.02, usage: { input_tokens: 5, output_tokens: 7 } }) as Record<string, any>;
  assert.equal(usage.total_cost_usd, 0.02);
  assert.equal(usage.modelUsage, undefined);
  assert.deepEqual(usage.usage, { input_tokens: 5, output_tokens: 7 });
});

test("numbers that are missing or not finite are left out, and a message with none gives nothing", () => {
  const usage = usageFrom({ total_cost_usd: Number.NaN, num_turns: 2, modelUsage: { m: { inputTokens: "9", costUSD: Infinity }, n: { outputTokens: 4 } } }) as Record<string, any>;
  assert.deepEqual(usage, { num_turns: 2, modelUsage: { n: { outputTokens: 4 } } });
  assert.equal(usageFrom({ type: "result", result: "text" }), undefined);
  assert.equal(usageFrom({ modelUsage: null, usage: 3 }), undefined);
});

import { planFrom } from "./usage.js";

const answer = {
  session: { total_cost_usd: 9 },
  subscription_type: "team",
  rate_limits_available: true,
  rate_limits: {
    five_hour: { utilization: 24, resets_at: "2026-01-01T10:00:00+00:00" },
    seven_day: { utilization: 67, resets_at: "2026-01-04T10:00:00+00:00" },
    seven_day_opus: null,
    model_scoped: [{ display_name: "Orchid", utilization: 30, resets_at: "2026-01-04T10:00:00+00:00" }, { utilization: 5, resets_at: null }],
    extra_usage: { is_enabled: true, monthly_limit: 100, used_credits: 4.04, utilization: 4.04, currency: "EUR" },
  },
  behaviors: { day: { request_count: 4 } },
};

test("the plan limits keep the windows, the per-model windows and extra usage, and drop the session totals and the transcript scan", () => {
  const plan = planFrom(answer) as Record<string, any>;
  assert.equal(plan.subscription, "team");
  assert.deepEqual(plan.limits.five_hour, { utilization: 24, resets_at: "2026-01-01T10:00:00+00:00" });
  assert.equal(plan.limits.seven_day.utilization, 67);
  assert.equal(plan.limits.seven_day_opus, undefined, "an empty window is left out");
  assert.deepEqual(plan.limits.model_scoped, [{ display_name: "Orchid", utilization: 30, resets_at: "2026-01-04T10:00:00+00:00" }]);
  assert.deepEqual(plan.limits.extra_usage, { is_enabled: true, monthly_limit: 100, used_credits: 4.04, utilization: 4.04, currency: "EUR" });
  const text = JSON.stringify(plan);
  assert.ok(!text.includes("behaviors") && !text.includes("total_cost_usd"), "nothing else is forwarded");
});

test("plan limits that do not apply give nothing", () => {
  assert.equal(planFrom({ rate_limits_available: false, rate_limits: null }), undefined);
  assert.equal(planFrom({ rate_limits_available: true, rate_limits: null }), undefined);
  const off = planFrom({ rate_limits_available: true, rate_limits: { extra_usage: { is_enabled: false } } }) as Record<string, any>;
  assert.deepEqual(off.limits, {}, "extra usage that is off is not shown");
});
