.pragma library

// Spotlight's answers that don't need the system: sums, conversions and ranking.
// Plain JavaScript with no QML, so tests can run it under node.

function score(text, q) {
    const t = text.toLowerCase();
    if (t === q) return 0;
    if (t.startsWith(q)) return 1;
    // A later word counts as a start too: "code" finds "Visual Studio Code".
    if (t.split(/[\s\-_.]+/).some(w => w.startsWith(q))) return 2;
    return t.includes(q) ? 3 : -1;
}

// Every typed word must start a word in the text, so "fire priv" finds
// "Firefox: New private window" but "re" doesn't find every "Restart".
function wordsMatch(text, q) {
    const words = text.toLowerCase().split(/[\s\-_.:]+/);
    return q.split(/\s+/).every(part => words.some(w => w.startsWith(part)));
}

function number(value, places) {
    if (!Number.isFinite(value)) return null;
    const rounded = +value.toFixed(places);
    // Tiny or huge values keep their digits rather than rounding to 0 or 1e+21.
    if (rounded === 0 && value !== 0) return String(+value.toPrecision(4));
    return String(rounded);
}

function calculate(text) {
    if (!/^[\d\s+\-*\/().,%^]+$/.test(text) || !/\d/.test(text) || !/[+\-*\/%^(]/.test(text))
        return null;
    // A lone negative number isn't a sum.
    if (/^\s*-?\s*[\d.,]+\s*$/.test(text))
        return null;
    const source = text.replace(/,/g, ".").replace(/\^/g, "**").replace(/([\d.]+)%/g, "($1/100)");
    try {
        return number(new Function("return (" + source + ");")(), 10);
    } catch (e) {
        return null;
    }
}

// Each unit is a factor to the dimension's base unit. Temperature has offsets instead.
const UNITS = {
    length: {
        mm: 0.001, cm: 0.01, m: 1, km: 1000,
        in: 0.0254, ft: 0.3048, yd: 0.9144, mi: 1609.344, nmi: 1852
    },
    mass: {
        mg: 0.000001, g: 0.001, kg: 1, t: 1000,
        oz: 0.028349523125, lb: 0.45359237, st: 6.35029318
    },
    volume: {
        ml: 0.001, cl: 0.01, dl: 0.1, l: 1, m3: 1000,
        tsp: 0.00492892159375, tbsp: 0.01478676478125, cup: 0.2365882365,
        floz: 0.0295735295625, pt: 0.473176473, qt: 0.946352946, gal: 3.785411784
    },
    area: {
        mm2: 0.000001, cm2: 0.0001, m2: 1, ha: 10000, km2: 1000000,
        ft2: 0.09290304, acre: 4046.8564224, mi2: 2589988.110336
    },
    speed: { "m/s": 1, "km/h": 1 / 3.6, mph: 0.44704, kn: 0.514444 },
    time: { ms: 0.001, s: 1, min: 60, h: 3600, d: 86400, wk: 604800, yr: 31557600 },
    data: {
        b: 1, kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12,
        kib: 1024, mib: 1024 ** 2, gib: 1024 ** 3, tib: 1024 ** 4
    },
    energy: { j: 1, kj: 1000, cal: 4.184, kcal: 4184, wh: 3600, kwh: 3600000 },
    temperature: { c: null, f: null, k: null }
};

const ALIASES = {
    millimeter: "mm", millimetre: "mm", centimeter: "cm", centimetre: "cm",
    meter: "m", metre: "m", kilometer: "km", kilometre: "km",
    inch: "in", inches: "in", '"': "in", foot: "ft", feet: "ft", "'": "ft",
    yard: "yd", mile: "mi", miles: "mi",
    gram: "g", gramme: "g", kilo: "kg", kilogram: "kg", kilogramme: "kg", tonne: "t", ton: "t",
    ounce: "oz", pound: "lb", lbs: "lb", stone: "st",
    milliliter: "ml", millilitre: "ml", liter: "l", litre: "l", gallon: "gal", pint: "pt", quart: "qt",
    teaspoon: "tsp", tablespoon: "tbsp", "fl oz": "floz",
    "sq m": "m2", "m²": "m2", "sq km": "km2", "km²": "km2", hectare: "ha",
    "sq ft": "ft2", "ft²": "ft2", "sq mi": "mi2", "mi²": "mi2", "cm²": "cm2", "mm²": "mm2",
    kmh: "km/h", kph: "km/h", mps: "m/s", knot: "kn", knots: "kn",
    sec: "s", second: "s", minute: "min", mins: "min", hr: "h", hour: "h", hours: "h", hrs: "h",
    day: "d", days: "d", week: "wk", weeks: "wk", year: "yr", years: "yr",
    byte: "b", bytes: "b", kilobyte: "kb", megabyte: "mb", gigabyte: "gb", terabyte: "tb",
    joule: "j", calorie: "cal", calories: "cal", kcals: "kcal",
    "°c": "c", celsius: "c", "°f": "f", fahrenheit: "f", kelvin: "k"
};

// What a bare "5 km" converts to.
const DEFAULT_TARGET = {
    mm: "in", cm: "in", m: "ft", km: "mi", in: "cm", ft: "m", yd: "m", mi: "km", nmi: "km",
    g: "oz", kg: "lb", oz: "g", lb: "kg", st: "kg",
    ml: "floz", l: "gal", floz: "ml", cup: "ml", gal: "l", pt: "ml",
    m2: "ft2", ft2: "m2", ha: "acre", acre: "ha", km2: "mi2", mi2: "km2",
    "km/h": "mph", mph: "km/h", c: "f", f: "c", kcal: "kj", kj: "kcal", kwh: "j"
};

const CURRENCY_SYMBOLS = { "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "zł": "PLN", "zl": "PLN", "₹": "INR", "₩": "KRW", "₺": "TRY" };

function unitOf(word) {
    let w = word.toLowerCase().trim().replace(/\s+/g, " ");
    if (ALIASES[w]) return ALIASES[w];
    for (const dim in UNITS)
        if (w in UNITS[dim]) return w;
    // Plurals: "kilometers", "pounds", "cups".
    if (w.endsWith("s")) {
        const one = w.slice(0, -1);
        if (ALIASES[one]) return ALIASES[one];
        for (const dim in UNITS)
            if (one in UNITS[dim] && one.length > 1) return one;
    }
    return null;
}

function dimensionOf(unit) {
    for (const dim in UNITS)
        if (unit in UNITS[dim]) return dim;
    return null;
}

function toKelvin(v, u) {
    return u === "c" ? v + 273.15 : u === "f" ? (v - 32) * 5 / 9 + 273.15 : v;
}
function fromKelvin(v, u) {
    return u === "c" ? v - 273.15 : u === "f" ? (v - 273.15) * 9 / 5 + 32 : v;
}

const LABELS = { c: "°C", f: "°F", k: "K", l: "L", ml: "mL", cl: "cL", dl: "dL", floz: "fl oz", b: "B", kb: "kB", mb: "MB", gb: "GB", tb: "TB", kib: "KiB", mib: "MiB", gib: "GiB", tib: "TiB", kwh: "kWh", wh: "Wh", kj: "kJ", j: "J", m2: "m²", km2: "km²", cm2: "cm²", mm2: "mm²", ft2: "ft²", mi2: "mi²", m3: "m³" };
function label(unit) {
    return LABELS[unit] || unit;
}

function amount(text) {
    const v = Number(text.replace(/,/g, "."));
    return Number.isFinite(v) ? v : null;
}

// "5 km", "5km in mi", "100 usd to pln", "$20 in eur", "72 °f".
const PATTERN = /^(-?[\d.,]+)\s*([^\d\s][^\d]*?)(?:\s+(?:in|to|as|into|=|->)\s+([^\d]+?))?\s*$/i;
const SYMBOL_FIRST = /^([$€£¥₹₩₺])\s*([\d.,]+)(?:\s+(?:in|to|as|into|=|->)\s+([^\d]+?))?\s*$/i;

function parse(text) {
    let m = text.match(SYMBOL_FIRST);
    if (m) return { value: amount(m[2]), from: m[1], to: m[3] || null };
    m = text.match(PATTERN);
    if (m) return { value: amount(m[1]), from: m[2], to: m[3] || null };
    return null;
}

function currencyOf(word, rates) {
    if (!rates) return null;
    const w = word.trim();
    const code = (CURRENCY_SYMBOLS[w.toLowerCase()] || w).toUpperCase();
    return /^[A-Z]{3}$/.test(code) && code in rates.rates ? code : null;
}

// Returns { title, value, note } or null. `rates` is { date, rates: { EUR: 1, USD: … } }.
function convert(text, rates) {
    const p = parse(text.trim());
    if (!p || p.value === null) return null;

    const fromCurrency = currencyOf(p.from, rates);
    if (fromCurrency) {
        // Currency needs a named target; there's no sensible default.
        const to = p.to ? currencyOf(p.to, rates) : null;
        if (!to || to === fromCurrency) return null;
        const result = p.value / rates.rates[fromCurrency] * rates.rates[to];
        const value = number(result, 2);
        return value === null ? null : {
            title: value + " " + to,
            value,
            note: p.value + " " + fromCurrency + " · rates " + rates.date
        };
    }

    const from = unitOf(p.from);
    if (!from) return null;
    const dim = dimensionOf(from);
    const to = p.to ? unitOf(p.to) : DEFAULT_TARGET[from];
    if (!to || to === from || dimensionOf(to) !== dim) return null;
    const result = dim === "temperature"
        ? fromKelvin(toKelvin(p.value, from), to)
        : p.value * UNITS[dim][from] / UNITS[dim][to];
    const value = number(result, 4);
    return value === null ? null : {
        title: value + " " + label(to),
        value,
        note: p.value + " " + label(from)
    };
}

// Learning: how often and how recently each result was picked. Halves every two weeks.
function frecency(pick, now) {
    if (!pick) return 0;
    const weeks = (now - pick.t) / 604800000;
    return pick.n * Math.pow(0.5, weeks / 2);
}

// Records a pick, returning the new memory. `typed` remembers the result chosen
// for each exact query, so "sm" + Enter becomes a quick key for whatever it picked.
function remember(memory, query, key, now) {
    const picks = Object.assign({}, memory.picks);
    const typed = Object.assign({}, memory.typed);
    const old = picks[key];
    picks[key] = { n: (old ? old.n : 0) + 1, t: now };
    if (query) typed[query] = { key, t: now };
    // Keep the files small: forget the stalest entries past a cap.
    const trim = (map, cap) => {
        const keys = Object.keys(map);
        if (keys.length <= cap) return map;
        keys.sort((a, b) => map[b].t - map[a].t);
        const out = {};
        for (const k of keys.slice(0, cap)) out[k] = map[k];
        return out;
    };
    return { picks: trim(picks, 400), typed: trim(typed, 400) };
}

// The result to promote to Top Hit: what this exact query picked last, or else a
// well-used result whose name starts with the query.
function topHit(results, memory, query, now) {
    const learned = memory.typed[query];
    if (learned) {
        const at = results.findIndex(r => r.key === learned.key);
        if (at >= 0) return at;
    }
    let best = -1, bestScore = 1.5;
    results.forEach((r, i) => {
        if (!r.key || r.match === undefined || r.match > 1) return;
        const f = frecency(memory.picks[r.key], now);
        if (f > bestScore) { best = i; bestScore = f; }
    });
    return best;
}
