const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const openaiApiKey = defineSecret('OPENAI_API_KEY');
const geminiApiKey = defineSecret('GEMINI_API_KEY');

if (!admin.apps.length) {
  admin.initializeApp();
}

const TOPIC_MAX_PILLS = 8;
/** Soft average questions per subquiz pill (used only in LLM prompt hints). */
const TARGET_AVG_QUESTIONS_PER_PILL = 5;
const OPENAI_MODEL = 'gpt-4o-mini';
const GEMINI_MODEL = 'gemini-2.5-flash';

/** Gen2 callables run on Cloud Run: without public invoker, OPTIONS preflight is rejected (no auth) → browser reports CORS. `invoker: 'public'` fixes that; Firebase Auth on the callable body still gates real calls. */
const CALL_OPTS = {
  region: 'us-central1',
  invoker: 'public',
  cors: true,
  timeoutSeconds: 300,
  memory: '512MiB',
};

/** Use codes whose messages are forwarded to clients (`internal` is not). */
function callableError(msg) {
  const s = String(msg || 'Unknown error').slice(0, 2000);
  return new HttpsError('failed-precondition', s);
}

function rethrowIfHttpsError(e) {
  if (e instanceof HttpsError) throw e;
}

/**
 * Firebase callable runtime only forwards HttpsError to clients; any other throw becomes
 * functions/internal. Use this at export boundaries so real errors surface as failed-precondition.
 */
function wrapCallableHandler(fn) {
  return async (request) => {
    try {
      return await fn(request);
    } catch (e) {
      if (e instanceof HttpsError) throw e;
      logger.error('Topic tags callable (non-HttpsError)', e);
      const msg =
        e instanceof Error ? e.message || e.name || String(e) : String(e);
      throw new HttpsError(
        'failed-precondition',
        msg.slice(0, 2000) || 'Unknown server error'
      );
    }
  };
}

function stripHtml(s) {
  if (!s || typeof s !== 'string') return '';
  return s
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function compactQuestions(questions) {
  return questions.map((q, i) => {
    const options = q.options || {};
    const letters = Object.keys(options).sort();
    const opts = {};
    letters.forEach((L) => {
      opts[L] = stripHtml(options[L]).slice(0, 800);
    });
    return {
      i,
      stem: stripHtml(q.stem || '').slice(0, 2000),
      correct: q.correct || '',
      options: opts,
      hint: stripHtml(q.hint || '').slice(0, 400),
    };
  });
}

function parseJsonFromModel(text) {
  let t = (text || '').trim();
  const fence = /^```(?:json)?\s*\n?([\s\S]*?)\n?```$/m.exec(t);
  if (fence) t = fence[1].trim();
  return JSON.parse(t);
}

function normalizePills(parsed, numQuestions) {
  const raw = Array.isArray(parsed.pills) ? parsed.pills : [];
  const pills = [];
  const pillsMap = {};

  for (const entry of raw) {
    if (pills.length >= TOPIC_MAX_PILLS) break;
    let label;
    let indices;
    if (typeof entry === 'string') {
      label = entry;
      indices = [];
    } else if (entry && typeof entry === 'object') {
      label = entry.label || entry.name || entry.topic;
      indices = entry.indices || entry.questionIndices || [];
    } else continue;
    if (!label || typeof label !== 'string') continue;
    label = label.trim().replace(/\s+/g, ' ');
    if (label.length < 2 || label.length > 80) continue;
    const set = new Set();
    if (Array.isArray(indices)) {
      for (const x of indices) {
        const n = typeof x === 'number' ? x : parseInt(x, 10);
        if (Number.isFinite(n) && n >= 0 && n < numQuestions) set.add(n);
      }
    }
    if (set.size === 0) continue;
    if (pills.includes(label)) {
      const existing = new Set(pillsMap[label] || []);
      set.forEach((v) => existing.add(v));
      pillsMap[label] = [...existing].sort((a, b) => a - b);
    } else {
      pills.push(label);
      pillsMap[label] = [...set].sort((a, b) => a - b);
    }
  }

  return { pills, pillsMap };
}

/** Hard cap after normalize (defense in depth; must stay aligned with TOPIC_MAX_PILLS). */
function capPillsMap(pills, pillsMap, max) {
  if (!Array.isArray(pills) || pills.length <= max) return { pills, pillsMap };
  const capped = pills.slice(0, max);
  const out = {};
  for (const p of capped) {
    if (pillsMap[p] != null) out[p] = pillsMap[p];
  }
  return { pills: capped, pillsMap: out };
}

/**
 * Every question index must appear in at least one pill. Orphans (e.g. after cap) merge into the largest pill.
 * Mutates pillsMap; pills array unchanged.
 */
function ensureFullCoverage(pills, pillsMap, numQuestions) {
  if (!numQuestions || numQuestions < 1) return { pills, pillsMap };
  const covered = new Set();
  for (const p of pills) {
    const arr = pillsMap[p];
    if (!Array.isArray(arr)) continue;
    for (const x of arr) {
      const i = typeof x === 'number' ? x : parseInt(x, 10);
      if (Number.isFinite(i) && i >= 0 && i < numQuestions) covered.add(i);
    }
  }
  const missing = [];
  for (let i = 0; i < numQuestions; i++) {
    if (!covered.has(i)) missing.push(i);
  }
  if (!missing.length) return { pills, pillsMap };

  if (!pills.length) {
    const label = 'Quiz Topics';
    return {
      pills: [label],
      pillsMap: { [label]: missing.sort((a, b) => a - b) },
    };
  }

  let bestLabel = pills[0];
  let bestSize = (pillsMap[bestLabel] && pillsMap[bestLabel].length) || 0;
  for (let k = 1; k < pills.length; k++) {
    const p = pills[k];
    const sz = (pillsMap[p] && pillsMap[p].length) || 0;
    if (sz > bestSize) {
      bestSize = sz;
      bestLabel = p;
    }
  }
  const set = new Set(pillsMap[bestLabel] || []);
  missing.forEach((i) => set.add(i));
  pillsMap[bestLabel] = [...set].sort((a, b) => a - b);
  return { pills, pillsMap };
}

async function callOpenAI(apiKey, userPrompt) {
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      temperature: 0.2,
      max_tokens: 8192,
      response_format: { type: 'json_object' },
      messages: [
        {
          role: 'system',
          content:
            'You output only valid JSON objects. No markdown, no explanation outside JSON.',
        },
        { role: 'user', content: userPrompt },
      ],
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`OpenAI HTTP ${res.status}: ${errText.slice(0, 500)}`);
  }
  const data = await res.json();
  const text = data.choices?.[0]?.message?.content || '';
  if (!text) throw new Error('Empty model response');
  return text;
}

async function callGemini(apiKey, userPrompt) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const body = {
    contents: [{ role: 'user', parts: [{ text: userPrompt }] }],
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: 8192,
      responseMimeType: 'application/json',
    },
  };
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Gemini HTTP ${res.status}: ${errText.slice(0, 500)}`);
  }
  const data = await res.json();
  const text =
    data.candidates?.[0]?.content?.parts?.map((p) => p.text).join('') || '';
  if (!text) throw new Error('Empty model response');
  return text;
}

function readSecretTrimmed(secretParam, name) {
  try {
    const v = secretParam.value();
    return String(v == null ? '' : v).trim();
  } catch (e) {
    console.error(`Secret ${name}`, e);
    throw callableError(
      `Could not read ${name}: ${e.message || e}. Redeploy after: firebase functions:secrets:set ${name}`
    );
  }
}

/** Sanitize map keys so Firestore never treats dots as nested paths. */
function safePillsMap(pillsMap) {
  const out = {};
  for (const [k, arr] of Object.entries(pillsMap)) {
    const key = String(k).replace(/\./g, '·');
    out[key] = arr;
  }
  return out;
}

async function generateTopicTagsCore(request, provider) {
  try {
    if (!request.auth?.token?.email) {
      throw new HttpsError('unauthenticated', 'Sign in required.');
    }
    const email = request.auth.token.email;
    const adminSnap = await admin.firestore().collection('admins').doc(email).get();
    if (!adminSnap.exists) {
      throw new HttpsError('permission-denied', 'Not an admin.');
    }

    const quizId = request.data?.quizId;
    if (!quizId || typeof quizId !== 'string') {
      throw new HttpsError('invalid-argument', 'quizId is required.');
    }

    const qRef = admin.firestore().collection('quizzes').doc(quizId);
    const metaSnap = await qRef.get();
    if (!metaSnap.exists) {
      throw new HttpsError('not-found', 'Quiz not found.');
    }

    const questionsSnap = await qRef.collection('data').doc('questions').get();
    if (!questionsSnap.exists) {
      throw new HttpsError('failed-precondition', 'No questions document.');
    }
    const questions = questionsSnap.data()?.questions;
    if (!Array.isArray(questions) || questions.length === 0) {
      throw new HttpsError('failed-precondition', 'Quiz has no questions.');
    }

    const compact = compactQuestions(questions);
    const payload = JSON.stringify(compact);
    const n = questions.length;
    let targetPillCount = Math.round(n / TARGET_AVG_QUESTIONS_PER_PILL);
    targetPillCount = Math.max(1, Math.min(TOPIC_MAX_PILLS, targetPillCount));
    if (n >= 16 && targetPillCount < 4) targetPillCount = 4;
    if (targetPillCount > n) targetPillCount = n;
    const approxPerPillLo = Math.max(1, Math.floor(n / targetPillCount));
    const approxPerPillHi = Math.max(approxPerPillLo, Math.ceil(n / targetPillCount));

    const userPrompt = `You partition a medical quiz into subquizzes using topic "pills". Each pill is a filterable subquiz: the learner selects one pill to study that slice of questions.

This quiz has ${n} questions (indexes 0 through ${n - 1}).

Each pill must have a short human-readable label (2–6 words, Title Case) naming a specific clinical theme (e.g. "Acute Appendicitis", "Diabetic Ketoacidosis"). Avoid useless labels that are only generic words like "patient" or "management".

COVERAGE (required): Every question index from 0 to ${n - 1} MUST appear in exactly one pill's "indices" array (a partition). Assign each question to exactly one subquiz unless a question truly spans two themes—only then may an index appear in two pills.

BALANCE: Aim for about ${targetPillCount} pills for this quiz size—roughly ${approxPerPillLo}–${approxPerPillHi} questions per pill on average. When ${n} is large enough, avoid a result where most pills contain only 1–2 questions; merge clinically related questions under broader theme labels instead. A few small pills are acceptable; do not fragment everything into pairs.

The "pills" array MUST contain at most ${TOPIC_MAX_PILLS} objects.

Respond with JSON only (no markdown) with this exact shape:
{"pills":[{"label":"string","indices":[0,1]}]}

Rules:
- "indices" are 0-based indexes into the question list (field "i" in the input).
- Together, the pills must cover every index 0..${n - 1} exactly once (partition), except for rare intentional overlap as noted above.

Question list (JSON):
${payload}`;

    let rawText;
    let modelId;
    if (provider === 'gemini') {
      const key = readSecretTrimmed(geminiApiKey, 'GEMINI_API_KEY');
      if (!key) {
        throw new HttpsError('failed-precondition', 'GEMINI_API_KEY secret is empty.');
      }
      try {
        rawText = await callGemini(key, userPrompt);
      } catch (e) {
        rethrowIfHttpsError(e);
        console.error('Gemini error', e);
        throw callableError(e.message || 'Gemini request failed');
      }
      modelId = GEMINI_MODEL;
    } else {
      const key = readSecretTrimmed(openaiApiKey, 'OPENAI_API_KEY');
      if (!key) {
        throw new HttpsError('failed-precondition', 'OPENAI_API_KEY secret is empty.');
      }
      try {
        rawText = await callOpenAI(key, userPrompt);
      } catch (e) {
        rethrowIfHttpsError(e);
        console.error('OpenAI error', e);
        throw callableError(e.message || 'OpenAI request failed');
      }
      modelId = OPENAI_MODEL;
    }

    let parsed;
    try {
      parsed = parseJsonFromModel(rawText);
    } catch (e) {
      rethrowIfHttpsError(e);
      console.error('JSON parse error', e);
      throw callableError(`Model returned invalid JSON: ${e.message || e}`);
    }
    let { pills, pillsMap } = normalizePills(parsed, questions.length);
    ({ pills, pillsMap } = capPillsMap(pills, pillsMap, TOPIC_MAX_PILLS));
    ({ pills, pillsMap } = ensureFullCoverage(pills, pillsMap, questions.length));
    if (!pills.length) {
      throw callableError('Model returned no usable tags (empty or invalid indices).');
    }

    const pillsMapSafe = safePillsMap(pillsMap);
    const pillsSafe = pills.map((p) => String(p).replace(/\./g, '·'));

    try {
      await qRef.collection('data').doc('topicTags').set({
        pills: pillsSafe,
        pillsMap: pillsMapSafe,
        provider,
        generatedAt: admin.firestore.FieldValue.serverTimestamp(),
        model: modelId,
      });
    } catch (e) {
      console.error('Firestore topicTags set', e);
      throw callableError(`Saving tags failed: ${e.message || e}`);
    }

    return { ok: true, pillCount: pillsSafe.length | 0 };
  } catch (e) {
    rethrowIfHttpsError(e);
    logger.error('generateTopicTagsCore', e);
    throw callableError(e.message || String(e));
  }
}

exports.generateTopicTagsOpenAI = onCall(
  { ...CALL_OPTS, secrets: [openaiApiKey] },
  wrapCallableHandler(async (request) => generateTopicTagsCore(request, 'openai'))
);

exports.generateTopicTagsGemini = onCall(
  { ...CALL_OPTS, secrets: [geminiApiKey] },
  wrapCallableHandler(async (request) => generateTopicTagsCore(request, 'gemini'))
);
