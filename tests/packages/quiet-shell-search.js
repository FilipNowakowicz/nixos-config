// Check Spotlight's sums, conversions and learning, which are plain JavaScript.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs
  .readFileSync(process.argv[2], "utf8")
  .replace(/^\.pragma library\s*$/m, "");
const S = vm.runInNewContext(
  source +
    "\n({ score, wordsMatch, calculate, convert, frecency, remember, topHit })",
);

// Sums
assert.equal(S.calculate("2+3*4"), "14");
assert.equal(S.calculate("20% * 50"), "10");
assert.equal(S.calculate("2^10"), "1024");
assert.equal(S.calculate("0.1+0.2"), "0.3");
assert.equal(S.calculate("-5"), null, "a lone number isn't a sum");
assert.equal(S.calculate("firefox"), null);
assert.equal(S.calculate("1/0"), null);

// Units
const c = (text) => (S.convert(text, rates) || {}).title;
const rates = {
  date: "2026-11-06",
  rates: { EUR: 1, USD: 1.1, PLN: 4.3, GBP: 0.85 },
};
assert.equal(c("5 km in mi"), "3.1069 mi");
assert.equal(c("5km"), "3.1069 mi", "a bare unit has a default target");
assert.equal(c("100 c to f"), "212 °F");
assert.equal(c("-40 °f in celsius"), "-40 °C");
assert.equal(c("2 lbs to kg"), "0.9072 kg");
assert.equal(c("180 cm to ft"), "5.9055 ft");
assert.equal(c("1 fl oz to ml"), "29.5735 mL");
assert.equal(c("1 gib in mb"), "1073.7418 MB");
assert.equal(c("90 km/h to mph"), "55.9234 mph");
assert.equal(c("2 hours in min"), "120 min");
assert.equal(c("1,5 kilometers in m"), "1500 m");
assert.equal(c("5 km in kg"), undefined, "different dimensions don't convert");
assert.equal(c("3 apples"), undefined);
assert.equal(c("1password"), undefined);
assert.equal(c("report 2024"), undefined);

// Currency
assert.equal(c("100 usd to pln"), "390.91 PLN");
assert.equal(c("$100 in eur"), "90.91 EUR");
assert.equal(c("100$ to pln"), "390.91 PLN");
assert.equal(c("50 eur to gbp"), "42.5 GBP");
assert.equal(
  S.convert("100 usd to pln", rates).note,
  "100 USD · rates 2026-11-06",
);
assert.equal(c("100 usd"), undefined, "currency needs a target");
assert.equal(S.convert("100 usd to pln", null), null, "no rates, no answer");

// Matching
assert.equal(S.score("Firefox", "fire"), 1);
assert.equal(S.score("Visual Studio Code", "code"), 2);
assert.equal(S.score("Thunar", "una"), 3);
assert.ok(S.wordsMatch("Firefox New Private Window", "fire priv"));
assert.ok(!S.wordsMatch("Firefox New Private Window", "fire xyz"));

// Learning
const now = Date.parse("2026-11-07T12:00:00Z");
let memory = { picks: {}, typed: {} };
memory = S.remember(memory, "sm", "app:signal", now);
memory = S.remember(memory, "sm", "app:signal", now);
assert.equal(
  JSON.stringify(memory.picks["app:signal"]),
  JSON.stringify({ n: 2, t: now }),
);
assert.equal(memory.typed.sm.key, "app:signal");
assert.ok(
  Math.abs(S.frecency({ n: 4, t: now - 2 * 604800000 }, now) - 2) < 1e-9,
  "halves in two weeks",
);

const results = [
  { key: "app:spotify", match: 1 },
  { key: "app:signal", match: 2 },
  { key: "file:/x", match: 0 },
];
assert.equal(
  S.topHit(results, memory, "sm", now),
  1,
  "what this query picked last wins",
);
assert.equal(
  S.topHit(results, memory, "s", now),
  -1,
  "a weak or loose match isn't promoted",
);
memory = S.remember(memory, "", "app:spotify", now);
memory = S.remember(memory, "", "app:spotify", now);
assert.equal(
  S.topHit(results, memory, "s", now),
  0,
  "a well-used prefix match is",
);

// The memory stays bounded.
let big = { picks: {}, typed: {} };
for (let i = 0; i < 450; i++) big = S.remember(big, "q" + i, "k" + i, now + i);
assert.equal(Object.keys(big.picks).length, 400);
assert.ok("k449" in big.picks && !("k0" in big.picks), "the stalest go first");

console.log("quiet-shell search: ok");
