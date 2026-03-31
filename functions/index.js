const fence = fenceRegex.exec(t);
  if (fence) t = fence[1].trim();
  
  try {
    // Attempt 1: Standard parse
    return JSON.parse(t);
  } catch (e) {
    logger.warn('Initial JSON parse failed, attempting local repair...', e.message);
    
    // Attempt 2: Local string repair (Zero API cost)
    try {
      let repairedText = t
        // Remove trailing commas in arrays/objects
        .replace(/,\s*([\]}])/g, '$1')
        // Fix unescaped newlines inside strings
        .replace(/\n/g, '\\n') 
        // Sometimes the model cuts off the final closing brackets
        .replace(/\]\}*$/, ']}') 
        .replace(/\}*$/, '}');

      // If the model abruptly stopped, forcefully close the JSON
      if (!repairedText.endsWith('}')) {
        repairedText += ']}';
      }

      return JSON.parse(repairedText);
    } catch (repairError) {
      // If we STILL can't parse it, throw so the API retry loop can catch it
      logger.error('Local JSON repair failed. Raw text:', t);
      throw new Error(`Unrecoverable JSON syntax: ${repairError.message}`);
    }
  }
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
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "topic_tags_schema",
          strict: true,
          schema: {
            type: "object",
            properties: {
              pills: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    label: { type: "string" },
                    indices: { type: "array", items: { type: "integer" } }
                  },
                  required: ["label", "indices"],
                  additionalProperties: false
                }
              }
            },
            required: ["pills"],
            additionalProperties: false
          }
        }
      },
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
      responseSchema: {
        type: "OBJECT",
        properties: {
          pills: {
            type: "ARRAY",
            items: {
              type: "OBJECT",
              properties: {
                label: { type: "STRING" },
                indices: { type: "ARRAY", items: { type: "INTEGER" } }
              },
              required: ["label", "indices"]
            }
          }
        },
        required: ["pills"]
      }
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

// ── Week parent pills (cluster child topic pills across quizzes in one week) ──
// Stable key: weekParentPills/{sectionId}__{weekId} (sectionId = slug, e.g. surgery).
// Legacy: {sectionDisplay}__{NORMALIZED_WEEK} without weekId, or {sectionDisplay}__{weekId} before migration.

function normalizeWeekKey(week) {
  return (
    String(week || 'Unknown')
      .trim()
      .replace(/\//g, '_')
      .toUpperCase() || 'UNKNOWN'
  );
}

/** Slug for known sections; otherwise a safe slug from the label. */
function canonicalSectionIdFromLabel(sectionDisplay) {
  const s = String(sectionDisplay || 'Surgery')
    .trim()
    .toLowerCase();
  if (s === 'surgery') return 'surgery';
  if (s === 'gp') return 'gp';
  if (s === 'medicine') return 'medicine';
  return (
    s
      .replace(/[^a-z0-9_-]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 48) || 'unknown'
  );
}

function weekParentPillsDocIdLegacy(sectionDisplay, week) {
  const sec = String(sectionDisplay || 'Surgery').trim() || 'Surgery';
  return `${sec}__${normalizeWeekKey(week)}`;
}

/** Current format: sectionId + weekId (both stable). */
function weekParentPillsDocId(sectionId, weekId) {
  const sid = String(sectionId || '').trim();
  const wid = String(weekId || '').trim();
  if (!sid || !wid) return weekParentPillsDocIdLegacy('Surgery', 'Unknown');
  return `${sid}__${wid}`;
}

function topicCanonLabel(s) {
  return String(s || '').replace(/\./g, '·');
}

function indicesForPillLabel(label, pillsMap) {
  const rawMap =
    pillsMap && typeof pillsMap === 'object' && !Array.isArray(pillsMap) ? pillsMap : {};
  const L = String(label);
  const tries = [L, L.replace(/·/g, '.'), L.replace(/\./g, '·')];
  for (const t of tries) {
    const arr = rawMap[t];
    if (Array.isArray(arr)) {
      return arr
        .map((x) => (typeof x === 'number' ? x : parseInt(x, 10)))
        .filter((n) => Number.isFinite(n) && n >= 0);
    }
  }
  const want = topicCanonLabel(L);
  for (const k of Object.keys(rawMap)) {
    if (topicCanonLabel(k) === want && Array.isArray(rawMap[k])) {
      return rawMap[k]
        .map((x) => (typeof x === 'number' ? x : parseInt(x, 10)))
        .filter((n) => Number.isFinite(n) && n >= 0);
    }
  }
  return [];
}

function collectWeekChildEntries(quizId, quizName, topicData) {
  const pills = Array.isArray(topicData.pills) ? topicData.pills.map(String).filter(Boolean) : [];
  const pillsMap =
    topicData.pillsMap && typeof topicData.pillsMap === 'object' ? topicData.pillsMap : {};
  const ordered = [...pills];
  for (const k of Object.keys(pillsMap)) {
    const ck = topicCanonLabel(k);
    if (!ordered.some((p) => topicCanonLabel(p) === ck)) ordered.push(ck);
  }
  const seen = new Set();
  const entries = [];
  for (const label of ordered) {
    const canon = topicCanonLabel(label);
    const key = `${quizId}::${canon}`;
    if (seen.has(key)) continue;
    const rawIdx = indicesForPillLabel(label, pillsMap);
    const indices = [...new Set(rawIdx)].sort((a, b) => a - b);
    if (!indices.length) continue;
    seen.add(key);
    const display = pills.find((p) => topicCanonLabel(p) === canon) || label;
    entries.push({
      key,
      quizId,
      quizName: String(quizName || '').trim() || quizId,
      pillLabel: String(display).replace(/\./g, '·'),
      indices,
    });
  }
  return entries;
}

function slugifyParentLabel(label) {
  const s = String(label)
    .toLowerCase()
    .trim()
    .replace(/\s+/g, '-')
    .replace(/[^a-z0-9_-]/g, '');
  return s.slice(0, 48) || 'parent';
}

/**
 * Map model-returned `quizId::label` strings to canonical keys in validKeysSet.
 * Handles · vs . in the label and stray whitespace without dropping keys.
 */
function resolveCanonicalChildKey(raw, validKeysSet) {
  const s = String(raw || '').trim();
  if (!s) return null;
  if (validKeysSet.has(s)) return s;
  const sep = '::';
  const idx = s.indexOf(sep);
  if (idx === -1) return null;
  const qid = s.slice(0, idx).trim();
  const labelPart = s.slice(idx + sep.length);
  if (!qid) return null;
  const canonFromModel = topicCanonLabel(labelPart.trim());
  const candidate = `${qid}::${canonFromModel}`;
  if (validKeysSet.has(candidate)) return candidate;
  for (const k of validKeysSet) {
    if (!k.startsWith(qid + sep)) continue;
    const rest = k.slice(qid.length + sep.length);
    if (topicCanonLabel(rest) === canonFromModel) return k;
  }
  return null;
}

function parseWeekGroupsFromModel(parsed, validKeysSet) {
  const raw = Array.isArray(parsed.groups)
    ? parsed.groups
    : Array.isArray(parsed.parents)
      ? parsed.parents
      : [];
  const groups = [];
  for (const g of raw) {
    if (!g || typeof g !== 'object') continue;
    const label = String(g.label || g.name || g.title || '').trim();
    const keys = Array.isArray(g.childKeys)
      ? g.childKeys
      : Array.isArray(g.keys)
        ? g.keys
        : [];
    if (!label || label.length < 2 || label.length > 100) continue;
    const childKeys = [
      ...new Set(
        keys
          .map((k) => resolveCanonicalChildKey(k, validKeysSet))
          .filter(Boolean)
      ),
    ];
    if (!childKeys.length) continue;
    groups.push({ label, childKeys: [...new Set(childKeys)] });
  }
  return groups;
}

/**
 * Models often repeat the same child key in multiple parent groups. Keep first occurrence only
 * (order = model group order), then drop empty groups.
 */
function dedupeWeekGroupsFirstWins(groups) {
  const seen = new Set();
  const out = [];
  for (const g of groups) {
    const childKeys = g.childKeys.filter((k) => {
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
    if (childKeys.length) out.push({ label: g.label, childKeys });
  }
  return out;
}

function validateWeekGroups(groups, allKeysSet) {
  const assigned = new Set();
  for (const g of groups) {
    for (const k of g.childKeys) {
      if (assigned.has(k)) return { ok: false, reason: `duplicate key ${k}` };
      assigned.add(k);
    }
  }
  for (const k of allKeysSet) {
    if (!assigned.has(k)) return { ok: false, reason: `missing key ${k}` };
  }
  return { ok: true };
}

/** If the model omitted child keys, attach them to the first parent so validation can pass. */
function repairMissingChildKeys(groups, validSet) {
  const assigned = new Set();
  for (const g of groups) {
    for (const k of g.childKeys) assigned.add(k);
  }
  const missing = [...validSet].filter((k) => !assigned.has(k));
  if (!missing.length) return groups;
  const out = groups.map((g) => ({ label: g.label, childKeys: [...g.childKeys] }));
  if (out.length) {
    out[0].childKeys.push(...missing);
    return out;
  }
  return [{ label: 'Topics', childKeys: missing }];
}

function buildMembersFromGroups(groups, keyToEntry) {
  const parents = [];
  const slugUsed = new Set();
  for (const g of groups) {
    const byQuiz = new Map();
    for (const key of g.childKeys) {
      const ent = keyToEntry.get(key);
      if (!ent) continue;
      const qid = ent.quizId;
      if (!byQuiz.has(qid)) byQuiz.set(qid, new Set());
      const set = byQuiz.get(qid);
      ent.indices.forEach((i) => set.add(i));
    }
    const members = [];
    for (const [quizId, idxSet] of byQuiz) {
      members.push({
        quizId,
        indices: [...idxSet].sort((a, b) => a - b),
      });
    }
    members.sort((a, b) => a.quizId.localeCompare(b.quizId));
    let baseSlug = slugifyParentLabel(g.label);
    let slug = baseSlug;
    let n = 0;
    while (slugUsed.has(slug)) {
      n += 1;
      slug = `${baseSlug}-${n}`;
    }
    slugUsed.add(slug);
    parents.push({ label: g.label, slug, members });
  }
  return parents;
}

async function callModelWeekParents(provider, userPrompt) {
  if (provider === 'gemini') {
    const key = readSecretTrimmed(geminiApiKey, 'GEMINI_API_KEY');
    if (!key) throw callableError('GEMINI_API_KEY secret is empty.');
    return callGemini(key, userPrompt);
  }
  const key = readSecretTrimmed(openaiApiKey, 'OPENAI_API_KEY');
  if (!key) throw callableError('OPENAI_API_KEY secret is empty.');
  return callOpenAI(key, userPrompt);
}

function buildWeekParentPrompt(childRows, c) {
  const payload = JSON.stringify(childRows);
  let constraint;
  if (c < 2) {
    constraint =
      'There is only one child pill. Output exactly one parent group containing that single child key.';
  } else {
    constraint = `You MUST output between 1 and ${c - 1} parent groups (strictly fewer than ${c}, since there are ${c} child pills). Merge semantically related child pills under one short parent label (2–7 words, Title Case, clinical themes). Every child key must appear in exactly one group.`;
  }
  return `You group medical quiz "topic pills" from several subquizzes in the same teaching week into a smaller set of PARENT themes (parent pills).

Each child row has: key (unique id), quizName, pillLabel (the learner-facing child pill name).

${constraint}

Rules:
- Parent labels must be distinct and clinically meaningful.
- Do not drop or invent keys; only use keys from the input (copy each \`key\` field exactly).
- Each child key must appear in exactly one group — never list the same key in more than one group.
- Respond with JSON only of this shape:
{"groups":[{"label":"string","childKeys":["quizId::Label",...]}]}

Child rows (JSON array):
${payload}`;
}

/**
 * Rebuild weekParentPills for one teaching week. Uses sectionId + weekId for doc id when weekId set.
 * Otherwise matches quizzes by normalized week label (legacy) and legacy doc id.
 * Deletes the doc if no child pills exist.
 */
async function regenerateWeekParentPillsInternal(
  sectionDisplay,
  week,
  provider,
  weekIdOpt,
  sectionIdOpt
) {
  const db = admin.firestore();
  const secDisplay = String(sectionDisplay || 'Surgery').trim() || 'Surgery';
  const weekId = weekIdOpt && String(weekIdOpt).trim();
  let sectionId = sectionIdOpt && String(sectionIdOpt).trim();

  let snap;
  if (sectionId) {
    snap = await db.collection('quizzes').where('sectionId', '==', sectionId).get();
  }
  if (!sectionId || snap.empty) {
    snap = await db.collection('quizzes').where('section', '==', secDisplay).get();
  }

  if (snap.docs.length && !sectionId) {
    const sid0 = snap.docs[0].data().sectionId;
    if (sid0 && String(sid0).trim()) sectionId = String(sid0).trim();
  }
  if (!sectionId) sectionId = canonicalSectionIdFromLabel(secDisplay);

  let docs = snap.docs;
  let wk;
  if (weekId) {
    docs = docs.filter((d) => String(d.data().weekId || '').trim() === weekId);
    wk =
      docs.length > 0
        ? normalizeWeekKey(docs[0].data().week)
        : normalizeWeekKey(week);
  } else {
    wk = normalizeWeekKey(week);
    docs = docs.filter((d) => normalizeWeekKey(d.data().week) === wk);
  }

  const allEntries = [];
  for (const doc of docs) {
    const qid = doc.id;
    const m = doc.data();
    const ttSnap = await db
      .collection('quizzes')
      .doc(qid)
      .collection('data')
      .doc('topicTags')
      .get();
    if (!ttSnap.exists) continue;
    const entries = collectWeekChildEntries(qid, m.name || m.title, ttSnap.data());
    allEntries.push(...entries);
  }

  const docRef = db.collection('weekParentPills').doc(
    weekId
      ? weekParentPillsDocId(sectionId, weekId)
      : weekParentPillsDocIdLegacy(secDisplay, week)
  );

  if (!allEntries.length) {
    await docRef.delete().catch(() => {});
    return { ok: true, parentCount: 0, childCount: 0, deleted: true };
  }

  const keyToEntry = new Map(allEntries.map((e) => [e.key, e]));
  const childKeys = [...keyToEntry.keys()];
  const c = childKeys.length;
  const childRows = allEntries.map(({ key, quizName, pillLabel }) => ({
    key,
    quizName,
    pillLabel,
  }));

  let userPrompt = buildWeekParentPrompt(childRows, c);
  let lastError = 'Invalid model output';

  for (let attempt = 0; attempt < 2; attempt++) {
    let rawText;
    try {
      rawText = await callModelWeekParents(provider, userPrompt);
    } catch (e) {
      rethrowIfHttpsError(e);
      throw e;
    }
    let parsed;
    try {
      parsed = parseJsonFromModel(rawText);
    } catch (e) {
      lastError = `Invalid JSON: ${e.message}`;
      userPrompt = `${buildWeekParentPrompt(childRows, c)}\n\nYour previous output was not valid JSON. Output only one JSON object.`;
      continue;
    }
    const validSet = new Set(childKeys);
    let groups = dedupeWeekGroupsFirstWins(parseWeekGroupsFromModel(parsed, validSet));
    groups = repairMissingChildKeys(groups, validSet);
    const p = groups.length;
    if (c >= 2 && (p < 1 || p >= c)) {
      lastError = `Need between 1 and ${c - 1} parent groups; got ${p}`;
      userPrompt = `${buildWeekParentPrompt(childRows, c)}\n\nFix: you must output strictly fewer than ${c} groups and at least 1. You returned ${p} groups.`;
      continue;
    }
    if (c === 1 && p !== 1) {
      lastError = 'Need exactly 1 parent group for a single child pill';
      userPrompt = `${buildWeekParentPrompt(childRows, c)}\n\nFix: with one child key, output exactly one group containing it.`;
      continue;
    }
    const v = validateWeekGroups(groups, validSet);
    if (!v.ok) {
      lastError = v.reason;
      userPrompt = `${buildWeekParentPrompt(childRows, c)}\n\nFix validation error: ${v.reason}`;
      continue;
    }
    const parents = buildMembersFromGroups(groups, keyToEntry);
    const modelId = provider === 'gemini' ? GEMINI_MODEL : OPENAI_MODEL;
    const labelSection =
      docs.length > 0 ? String(docs[0].data().section || secDisplay).trim() || secDisplay : secDisplay;
    const payload = {
      section: labelSection,
      sectionId,
      week: wk,
      parents,
      childKeys,
      childCount: c,
      provider,
      model: modelId,
      generatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    if (weekId) payload.weekId = weekId;
    await docRef.set(payload);
    return { ok: true, parentCount: parents.length, childCount: c };
  }
  throw callableError(lastError);
}

async function regenerateWeekParentPillsCore(request, provider) {
  if (!request.auth?.token?.email) {
    throw new HttpsError('unauthenticated', 'Sign in required.');
  }
  const email = request.auth.token.email;
  const adminSnap = await admin.firestore().collection('admins').doc(email).get();
  if (!adminSnap.exists) {
    throw new HttpsError('permission-denied', 'Not an admin.');
  }
  const section = request.data?.section;
  const week = request.data?.week;
  const weekId = request.data?.weekId && String(request.data.weekId).trim();
  const sectionId = request.data?.sectionId && String(request.data.sectionId).trim();
  const sectionStr =
    section && typeof section === 'string' ? section.trim() : '';
  if (!sectionStr && !sectionId) {
    throw new HttpsError('invalid-argument', 'section or sectionId is required.');
  }
  if (weekId) {
    return regenerateWeekParentPillsInternal(
      sectionStr || 'Surgery',
      week && typeof week === 'string' ? week.trim() : 'Unknown',
      provider,
      weekId,
      sectionId || null
    );
  }
  if (!week || typeof week !== 'string') {
    throw new HttpsError('invalid-argument', 'week or weekId is required.');
  }
  return regenerateWeekParentPillsInternal(
    sectionStr || 'Surgery',
    week.trim(),
    provider,
    null,
    sectionId || null
  );
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

    let userPrompt = `You partition a medical quiz into subquizzes using topic "pills". Each pill is a filterable subquiz: the learner selects one pill to study that slice of questions.

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
    let parsed;
    let success = false;
    let lastError = null;

    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        if (provider === 'gemini') {
          const key = readSecretTrimmed(geminiApiKey, 'GEMINI_API_KEY');
          if (!key) throw new HttpsError('failed-precondition', 'GEMINI_API_KEY secret is empty.');
          rawText = await callGemini(key, userPrompt);
          modelId = GEMINI_MODEL;
        } else {
          const key = readSecretTrimmed(openaiApiKey, 'OPENAI_API_KEY');
          if (!key) throw new HttpsError('failed-precondition', 'OPENAI_API_KEY secret is empty.');
          rawText = await callOpenAI(key, userPrompt);
          modelId = OPENAI_MODEL;
        }

        parsed = parseJsonFromModel(rawText);
        success = true;
        break; // Exit loop if successful!
      } catch (e) {
        lastError = e;
        logger.warn(`Attempt ${attempt + 1} failed:`, e.message);
        // Warn the model if we have to retry
        userPrompt += `\n\nCRITICAL ERROR in previous attempt: You provided invalid JSON syntax. Ensure all brackets are closed and commas are correct.`;
      }
    }

    if (!success) {
      throw callableError(`Failed to generate valid tags after retries. Last error: ${lastError.message}`);
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

    const meta = metaSnap.data() || {};
    const weekSection = meta.section || 'Surgery';
    const weekLabel = meta.week || 'Unknown';
    const metaWeekId = meta.weekId && String(meta.weekId).trim();
    const metaSectionId = meta.sectionId && String(meta.sectionId).trim();
    try {
      await regenerateWeekParentPillsInternal(
        weekSection,
        weekLabel,
        provider,
        metaWeekId || null,
        metaSectionId || null
      );
    } catch (e) {
      logger.warn('regenerateWeekParentPillsInternal after topicTags', e);
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

exports.regenerateWeekParentPillsOpenAI = onCall(
  { ...CALL_OPTS, secrets: [openaiApiKey] },
  wrapCallableHandler(async (request) => regenerateWeekParentPillsCore(request, 'openai'))
);

exports.regenerateWeekParentPillsGemini = onCall(
  { ...CALL_OPTS, secrets: [geminiApiKey] },
  wrapCallableHandler(async (request) => regenerateWeekParentPillsCore(request, 'gemini'))
);