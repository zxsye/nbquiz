const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');

const openaiApiKey = defineSecret('OPENAI_API_KEY');
const geminiApiKey = defineSecret('GEMINI_API_KEY');

if (!admin.apps.length) {
  admin.initializeApp();
}

const TOPIC_MAX_PILLS = 40;
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

    const userPrompt = `You label medical quiz questions with clinical topic tags (diseases, syndromes, anatomy, key themes).

For EACH tag below, the tag must be a short human-readable label (2–6 words max, Title Case). Tags must name specific medical topics (e.g. "Acute Appendicitis", "Diabetic Ketoacidosis"), NOT generic words like "patient" or "management".

Respond with a JSON object (only JSON, no markdown) with this exact shape:
{"pills":[{"label":"string","indices":[0,1]}]}

Rules:
- "indices" are 0-based indexes into the question list (field "i" in the input).
- Each question index should appear in at least one pill if possible; merge similar questions under one tag.
- Produce at most ${TOPIC_MAX_PILLS} pills; prefer broader clinical tags over duplicates.
- Omit tags that would only match one generic word.

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

    const { pills, pillsMap } = normalizePills(parsed, questions.length);
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

    return { ok: true, pillCount: pillsSafe.length };
  } catch (e) {
    rethrowIfHttpsError(e);
    console.error('generateTopicTagsCore', e);
    throw callableError(e.message || String(e));
  }
}

exports.generateTopicTagsOpenAI = onCall(
  { ...CALL_OPTS, secrets: [openaiApiKey] },
  async (request) => generateTopicTagsCore(request, 'openai')
);

exports.generateTopicTagsGemini = onCall(
  { ...CALL_OPTS, secrets: [geminiApiKey] },
  async (request) => generateTopicTagsCore(request, 'gemini')
);
