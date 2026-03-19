#!/usr/bin/env bash
# =============================================================================
# build_quiz_site.sh
# Converts a JSON quiz file into a self-contained HTML quiz app.
#
# USAGE:
#   ./build_quiz_site.sh <quiz.json> [output.html]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

INPUT="${1:-}"
OUTPUT="${2:-quiz.html}"

[[ -z "$INPUT" ]]      && error "Usage: $0 <quiz.json> [output.html]"
[[ ! -f "$INPUT" ]]    && error "File not found: $INPUT"
command -v python3 >/dev/null 2>&1 || error "python3 is required."

info "Parsing JSON: $INPUT"

python3 - "$INPUT" "$OUTPUT" << 'PYEOF'
import sys, json, html, os

md_path  = sys.argv[1]
out_path = sys.argv[2]

# Load and parse the JSON file
try:
    with open(md_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"  [ERROR] Invalid JSON file: {e}")
    sys.exit(1)

all_questions = []

# Process the interactive_quiz array
if 'interactive_quiz' in data:
    for q in data['interactive_quiz']:
        options_dict = {}
        rationales_dict = {}
        
        for opt in q.get('options', []):
            letter = opt.get('letter')
            if not letter:
                continue
            options_dict[letter] = opt.get('text', '')
            if 'rationale' in opt:
                rationales_dict[letter] = opt.get('rationale', '')

        all_questions.append({
            'stem':       q.get('stem', ''),
            'options':    options_dict,
            'correct':    q.get('correct_answer', ''),
            'rationales': rationales_dict,
            'hint':       q.get('hint', ''),
            'part':       1
        })

if not all_questions:
    print("  [ERROR] No questions found in the 'interactive_quiz' array.")
    sys.exit(1)

print(f"  Total mapped                : {len(all_questions)} questions")

# ── Serialise to JSON for JS ──────────────────────────────────────────────────
# Added .replace() safety measure to ensure no inner HTML tags break the script wrapper
quiz_json = json.dumps(all_questions, ensure_ascii=False).replace("</", "<\\/")

# ── HTML template ─────────────────────────────────────────────────────────────

title = os.path.splitext(os.path.basename(md_path))[0].replace('_', ' ').title()

HTML = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{html.escape(title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Crimson+Pro:ital,wght@0,400;0,600;1,400&family=DM+Sans:wght@400;500;600&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
/* ── Reset & Base ── */
*, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}

:root {{
  --bg:           #f7f5f0;
  --surface:      #ffffff;
  --surface-2:    #f0ede6;
  --border:       #e2ddd5;
  --text:         #1a1714;
  --text-2:       #5a534a;
  --text-3:       #9a8f83;
  --accent:       #2563a8;
  --accent-light: #dbeafe;
  --correct:      #166534;
  --correct-bg:   #dcfce7;
  --correct-ring: #4ade80;
  --wrong:        #991b1b;
  --wrong-bg:     #fee2e2;
  --wrong-ring:   #f87171;
  --hint:         #92400e;
  --hint-bg:      #fef3c7;
  --radius:       10px;
  --radius-lg:    16px;
  --shadow:       0 1px 3px rgba(0,0,0,.07), 0 4px 16px rgba(0,0,0,.06);
  --shadow-lg:    0 4px 6px rgba(0,0,0,.07), 0 12px 32px rgba(0,0,0,.1);
  --font-serif:   'Crimson Pro', Georgia, serif;
  --font-sans:    'DM Sans', system-ui, sans-serif;
  --font-mono:    'DM Mono', monospace;
  --transition:   200ms cubic-bezier(.4,0,.2,1);
}}

body {{
  font-family: var(--font-sans);
  background: var(--bg);
  color: var(--text);
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 24px 16px 80px;
}}

/* ── Header ── */
.app-header {{
  width: 100%;
  max-width: 780px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 0 24px;
  border-bottom: 1.5px solid var(--border);
  margin-bottom: 32px;
}}
.app-title {{
  font-family: var(--font-serif);
  font-size: 1.5rem;
  font-weight: 600;
  color: var(--text);
  letter-spacing: -.01em;
}}
.app-title span {{
  color: var(--accent);
}}
.score-badge {{
  font-family: var(--font-mono);
  font-size: .8rem;
  font-weight: 500;
  background: var(--surface);
  border: 1.5px solid var(--border);
  border-radius: 99px;
  padding: 6px 14px;
  color: var(--text-2);
  display: flex;
  gap: 6px;
  align-items: center;
}}
.score-badge .score-num {{
  color: var(--text);
  font-weight: 600;
}}

/* ── Progress bar ── */
.progress-wrap {{
  width: 100%;
  max-width: 780px;
  margin-bottom: 28px;
}}
.progress-meta {{
  display: flex;
  justify-content: space-between;
  font-size: .78rem;
  color: var(--text-3);
  margin-bottom: 7px;
  font-family: var(--font-mono);
}}
.progress-track {{
  height: 5px;
  background: var(--border);
  border-radius: 99px;
  overflow: hidden;
}}
.progress-fill {{
  height: 100%;
  background: var(--accent);
  border-radius: 99px;
  transition: width 400ms cubic-bezier(.4,0,.2,1);
}}

/* ── Card ── */
.card {{
  width: 100%;
  max-width: 780px;
  background: var(--surface);
  border: 1.5px solid var(--border);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow);
  overflow: hidden;
  animation: fadeUp .3s ease both;
}}
@keyframes fadeUp {{
  from {{ opacity:0; transform:translateY(12px); }}
  to   {{ opacity:1; transform:translateY(0); }}
}}

.card-header {{
  padding: 20px 28px 0;
  display: flex;
  align-items: center;
  gap: 10px;
}}
.q-label {{
  font-family: var(--font-mono);
  font-size: .7rem;
  font-weight: 500;
  color: var(--text-3);
  text-transform: uppercase;
  letter-spacing: .08em;
}}
.part-tag {{
  font-family: var(--font-mono);
  font-size: .65rem;
  font-weight: 500;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 2px 7px;
  color: var(--text-3);
}}

.stem {{
  font-family: var(--font-serif);
  font-size: 1.25rem;
  line-height: 1.65;
  color: var(--text);
  padding: 16px 28px 24px;
  border-bottom: 1px solid var(--border);
}}

/* ── Hint ── */
.hint-wrap {{
  padding: 0 28px;
  margin-top: 20px;
}}
.hint-toggle {{
  display: inline-flex;
  align-items: center;
  gap: 7px;
  font-size: .8rem;
  font-weight: 500;
  color: var(--hint);
  cursor: pointer;
  background: none;
  border: 1.5px solid #d97706;
  border-radius: 99px;
  padding: 5px 14px;
  transition: background var(--transition);
}}
.hint-toggle:hover {{ background: var(--hint-bg); }}
.hint-body {{
  margin-top: 10px;
  padding: 12px 16px;
  background: var(--hint-bg);
  border-left: 3px solid #f59e0b;
  border-radius: 0 var(--radius) var(--radius) 0;
  font-size: .9rem;
  color: var(--hint);
  line-height: 1.55;
  display: none;
}}
.hint-body.open {{ display: block; animation: fadeIn .2s ease; }}
@keyframes fadeIn {{ from{{opacity:0}} to{{opacity:1}} }}

/* ── Options ── */
.options {{
  padding: 20px 28px 28px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}}

.option {{
  display: flex;
  align-items: flex-start;
  gap: 14px;
  padding: 14px 16px;
  border: 1.5px solid var(--border);
  border-radius: var(--radius);
  cursor: pointer;
  background: var(--surface);
  transition: border-color var(--transition), background var(--transition), box-shadow var(--transition);
  text-align: left;
  width: 100%;
  position: relative;
}}
.option:hover:not(.locked) {{
  border-color: var(--accent);
  background: var(--accent-light);
  box-shadow: 0 0 0 3px rgba(37,99,168,.1);
}}
.option.selected:not(.locked) {{
  border-color: var(--accent);
  background: var(--accent-light);
  box-shadow: 0 0 0 3px rgba(37,99,168,.15);
}}

.option.correct {{
  border-color: var(--correct-ring);
  background: var(--correct-bg);
  box-shadow: 0 0 0 3px rgba(74,222,128,.2);
}}
.option.wrong {{
  border-color: var(--wrong-ring);
  background: var(--wrong-bg);
  box-shadow: 0 0 0 3px rgba(248,113,113,.2);
}}
.option.dimmed {{
  opacity: .5;
}}

.opt-letter {{
  flex-shrink: 0;
  width: 28px;
  height: 28px;
  border-radius: 50%;
  background: var(--surface-2);
  border: 1.5px solid var(--border);
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: var(--font-mono);
  font-size: .78rem;
  font-weight: 500;
  color: var(--text-2);
  transition: background var(--transition), border-color var(--transition), color var(--transition);
}}
.option.correct .opt-letter {{ background:#4ade80; border-color:#4ade80; color:#14532d; }}
.option.wrong   .opt-letter {{ background:#f87171; border-color:#f87171; color:#7f1d1d; }}
.option.selected:not(.locked) .opt-letter {{ background:var(--accent); border-color:var(--accent); color:#fff; }}

.opt-body {{ flex: 1; }}
.opt-text {{
  font-size: .95rem;
  line-height: 1.5;
  color: var(--text);
}}
.opt-rationale {{
  margin-top: 8px;
  font-size: .83rem;
  color: var(--text-2);
  line-height: 1.5;
  padding-top: 8px;
  border-top: 1px solid rgba(0,0,0,.06);
  display: none;
}}
.opt-rationale.visible {{ display: block; animation: fadeIn .25s ease; }}

.opt-icon {{
  flex-shrink: 0;
  font-size: 1.1rem;
  margin-top: 2px;
  display: none;
}}
.option.correct .opt-icon, .option.wrong .opt-icon {{ display:block; }}

/* ── Actions ── */
.card-footer {{
  padding: 0 28px 28px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}}
.btn {{
  font-family: var(--font-sans);
  font-size: .9rem;
  font-weight: 600;
  border-radius: 99px;
  padding: 11px 26px;
  cursor: pointer;
  border: 1.5px solid transparent;
  transition: all var(--transition);
  display: inline-flex;
  align-items: center;
  gap: 8px;
}}
.btn-primary {{
  background: var(--accent);
  color: #fff;
  border-color: var(--accent);
}}
.btn-primary:hover {{ background: #1d4f8a; border-color: #1d4f8a; box-shadow: 0 4px 14px rgba(37,99,168,.3); }}
.btn-primary:disabled {{ opacity:.4; cursor:not-allowed; box-shadow:none; }}
.btn-ghost {{
  background: transparent;
  color: var(--text-2);
  border-color: var(--border);
}}
.btn-ghost:hover {{ background: var(--surface-2); color: var(--text); }}

.feedback-msg {{
  font-size: .88rem;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 6px;
}}
.feedback-msg.correct {{ color: var(--correct); }}
.feedback-msg.wrong   {{ color: var(--wrong); }}

/* ── Results screen ── */
.results-screen {{
  width: 100%;
  max-width: 780px;
  display: none;
  flex-direction: column;
  gap: 24px;
  animation: fadeUp .4s ease both;
}}
.results-screen.visible {{ display: flex; }}

.results-hero {{
  background: var(--surface);
  border: 1.5px solid var(--border);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-lg);
  padding: 48px 40px;
  text-align: center;
}}
.results-grade {{
  font-family: var(--font-serif);
  font-size: 5rem;
  font-weight: 600;
  line-height: 1;
  margin-bottom: 8px;
  background: linear-gradient(135deg, #1a1714 0%, #2563a8 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
}}
.results-label {{
  font-size: 1.05rem;
  color: var(--text-2);
  margin-bottom: 32px;
}}
.results-stats {{
  display: flex;
  justify-content: center;
  gap: 40px;
  flex-wrap: wrap;
}}
.stat {{
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}}
.stat-num {{
  font-family: var(--font-mono);
  font-size: 1.8rem;
  font-weight: 500;
  color: var(--text);
}}
.stat-num.green {{ color: var(--correct); }}
.stat-num.red   {{ color: var(--wrong); }}
.stat-label {{ font-size: .78rem; color: var(--text-3); text-transform: uppercase; letter-spacing: .06em; }}

.results-actions {{
  display: flex;
  justify-content: center;
  gap: 12px;
  margin-top: 32px;
  flex-wrap: wrap;
}}

/* Review list */
.review-list {{
  display: flex;
  flex-direction: column;
  gap: 12px;
}}
.review-item {{
  background: var(--surface);
  border: 1.5px solid var(--border);
  border-radius: var(--radius);
  padding: 16px 20px;
  cursor: pointer;
  display: flex;
  align-items: flex-start;
  gap: 14px;
  transition: box-shadow var(--transition);
}}
.review-item:hover {{ box-shadow: var(--shadow); }}
.review-dot {{
  flex-shrink: 0;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  margin-top: 6px;
}}
.review-dot.correct {{ background: var(--correct-ring); }}
.review-dot.wrong   {{ background: var(--wrong-ring); }}
.review-text {{
  flex: 1;
  font-size: .9rem;
  color: var(--text-2);
  line-height: 1.4;
}}
.review-answer {{
  font-size: .8rem;
  font-family: var(--font-mono);
  color: var(--text-3);
  flex-shrink: 0;
}}

/* ── Utility ── */
.hidden {{ display: none !important; }}

/* ── Responsive ── */
@media (max-width: 520px) {{
  .stem {{ font-size: 1.1rem; padding: 14px 20px 20px; }}
  .options {{ padding: 16px 20px 20px; }}
  .card-footer {{ padding: 0 20px 20px; flex-wrap: wrap; }}
  .card-header {{ padding: 16px 20px 0; }}
  .hint-wrap {{ padding: 0 20px; }}
  .results-grade {{ font-size: 3.5rem; }}
  .results-stats {{ gap: 24px; }}
}}
</style>
</head>
<body>

<header class="app-header">
  <div class="app-title">🧠 <span>Neuro</span>Quiz</div>
  <div class="score-badge">
    Score&nbsp;<span class="score-num" id="scoreDisplay">0 / 0</span>
  </div>
</header>

<div class="progress-wrap" id="progressWrap">
  <div class="progress-meta">
    <span id="progressLabel">Question 1 of {len(all_questions)}</span>
    <span id="progressPct">0%</span>
  </div>
  <div class="progress-track"><div class="progress-fill" id="progressFill" style="width:0%"></div></div>
</div>

<div class="card" id="quizCard">
  <div class="card-header">
    <span class="q-label" id="qLabel">Question 1</span>
    <span class="part-tag" id="partTag">Part 1</span>
  </div>
  <div class="stem" id="stem"></div>
  <div class="hint-wrap" id="hintWrap">
    <button class="hint-toggle" onclick="toggleHint()">💡 Show hint</button>
    <div class="hint-body" id="hintBody"></div>
  </div>
  <div class="options" id="options"></div>
  <div class="card-footer">
    <div id="feedbackMsg" class="feedback-msg" style="visibility:hidden">–</div>
    <div style="display:flex;gap:10px;margin-left:auto;">
      <button class="btn btn-ghost" id="skipBtn" onclick="nextQuestion()">Skip →</button>
      <button class="btn btn-primary" id="submitBtn" onclick="submitAnswer()" disabled>Check answer</button>
    </div>
  </div>
</div>

<div class="results-screen" id="resultsScreen">
  <div class="results-hero">
    <div class="results-grade" id="resultsGrade">—</div>
    <div class="results-label" id="resultsLabel">Calculating...</div>
    <div class="results-stats">
      <div class="stat">
        <div class="stat-num" id="totalQ">{len(all_questions)}</div>
        <div class="stat-label">Questions</div>
      </div>
      <div class="stat">
        <div class="stat-num green" id="correctCount">0</div>
        <div class="stat-label">Correct</div>
      </div>
      <div class="stat">
        <div class="stat-num red" id="wrongCount">0</div>
        <div class="stat-label">Incorrect</div>
      </div>
      <div class="stat">
        <div class="stat-num" id="skippedCount">0</div>
        <div class="stat-label">Skipped</div>
      </div>
    </div>
    <div class="results-actions">
      <button class="btn btn-ghost" onclick="restartQuiz()">↺ Restart</button>
      <button class="btn btn-primary" onclick="showReview()">Review answers</button>
    </div>
  </div>
  <div id="reviewSection" class="hidden">
    <h3 style="font-family:var(--font-serif);font-size:1.2rem;margin-bottom:16px;padding:0 4px;">Review</h3>
    <div class="review-list" id="reviewList"></div>
  </div>
</div>

<script>
// ── Quiz data ─────────────────────────────────────────────────────────────────
const QUESTIONS = {quiz_json};

// ── State ─────────────────────────────────────────────────────────────────────
let current    = 0;
let selected   = null;
let answered   = false;
let score      = 0;
let results    = [];   // {{q, chosen, correct, wasCorrect, skipped}}

// ── Init ──────────────────────────────────────────────────────────────────────
function renderQuestion(idx) {{
  const q   = QUESTIONS[idx];
  answered  = false;
  selected  = null;

  document.getElementById('qLabel').textContent = `Question ${{idx + 1}}`;
  document.getElementById('partTag').textContent = `Part ${{q.part}}`;
  document.getElementById('stem').textContent    = q.stem;

  // Hint
  const hw = document.getElementById('hintWrap');
  const hb = document.getElementById('hintBody');
  if (q.hint) {{
    hw.style.display = 'block';
    hb.textContent   = q.hint;
    hb.classList.remove('open');
  }} else {{
    hw.style.display = 'none';
  }}

  // Options
  const optContainer = document.getElementById('options');
  optContainer.innerHTML = '';
  const letters = Object.keys(q.options).sort();
  letters.forEach(letter => {{
    const btn = document.createElement('button');
    btn.className  = 'option';
    btn.dataset.letter = letter;
    btn.onclick    = () => selectOption(letter);

    const rat  = q.rationales[letter] || '';
    btn.innerHTML = `
      <div class="opt-letter">${{letter}}</div>
      <div class="opt-body">
        <div class="opt-text">${{escHtml(q.options[letter])}}</div>
        ${{rat ? `<div class="opt-rationale" id="rat-${{letter}}">${{escHtml(rat)}}</div>` : ''}}
      </div>
      <div class="opt-icon" id="icon-${{letter}}"></div>
    `;
    optContainer.appendChild(btn);
  }});

  // Footer
  document.getElementById('submitBtn').disabled  = true;
  document.getElementById('submitBtn').textContent = 'Check answer';
  document.getElementById('skipBtn').textContent = 'Skip →';
  document.getElementById('skipBtn').style.display = '';
  setFeedback('', '');

  updateProgress(idx);
  document.getElementById('quizCard').style.animation = 'none';
  requestAnimationFrame(() => {{
    document.getElementById('quizCard').style.animation = 'fadeUp .3s ease both';
  }});
}}

function selectOption(letter) {{
  if (answered) return;
  selected = letter;
  document.querySelectorAll('.option').forEach(el => {{
    el.classList.toggle('selected', el.dataset.letter === letter);
  }});
  document.getElementById('submitBtn').disabled = false;
}}

function submitAnswer() {{
  if (!selected || answered) return;
  answered = true;

  const q = QUESTIONS[current];
  const isCorrect = selected === q.correct;
  if (isCorrect) score++;

  results.push({{ q: current, chosen: selected, correct: q.correct, wasCorrect: isCorrect, skipped: false }});

  // Lock options & colour them
  document.querySelectorAll('.option').forEach(el => {{
    el.classList.add('locked');
    const l = el.dataset.letter;
    if (l === q.correct) {{
      el.classList.add('correct');
      document.getElementById(`icon-${{l}}`).textContent = '✅';
    }} else if (l === selected && !isCorrect) {{
      el.classList.add('wrong');
      document.getElementById(`icon-${{l}}`).textContent = '❌';
    }} else {{
      el.classList.add('dimmed');
    }}
    // Show rationale
    const rat = document.getElementById(`rat-${{l}}`);
    if (rat) rat.classList.add('visible');
  }});

  // Feedback
  if (isCorrect) setFeedback('✅ Correct!', 'correct');
  else setFeedback(`❌ The answer was ${{q.correct}}`, 'wrong');

  // Update buttons
  document.getElementById('submitBtn').textContent = current < QUESTIONS.length - 1 ? 'Next →' : 'See results';
  document.getElementById('submitBtn').onclick = nextQuestion;
  document.getElementById('submitBtn').disabled = false;
  document.getElementById('skipBtn').style.display = 'none';

  updateScore();
}}

function nextQuestion() {{
  if (!answered) {{
    // Skipped
    results.push({{ q: current, chosen: null, correct: QUESTIONS[current].correct, wasCorrect: false, skipped: true }});
  }}
  current++;
  if (current >= QUESTIONS.length) {{
    showResults();
  }} else {{
    renderQuestion(current);
    document.getElementById('submitBtn').onclick = submitAnswer;
  }}
}}

function toggleHint() {{
  document.getElementById('hintBody').classList.toggle('open');
}}

// ── Progress & score ──────────────────────────────────────────────────────────
function updateProgress(idx) {{
  const pct = Math.round((idx / QUESTIONS.length) * 100);
  document.getElementById('progressFill').style.width  = pct + '%';
  document.getElementById('progressLabel').textContent = `Question ${{idx + 1}} of ${{QUESTIONS.length}}`;
  document.getElementById('progressPct').textContent   = pct + '%';
}}

function updateScore() {{
  const answered = results.length;
  document.getElementById('scoreDisplay').textContent = `${{score}} / ${{answered}}`;
}}

function setFeedback(msg, cls) {{
  const el = document.getElementById('feedbackMsg');
  el.textContent  = msg;
  el.className    = 'feedback-msg' + (cls ? ' ' + cls : '');
  el.style.visibility = msg ? 'visible' : 'hidden';
}}

// ── Results ───────────────────────────────────────────────────────────────────
function showResults() {{
  document.getElementById('quizCard').classList.add('hidden');
  document.getElementById('progressWrap').classList.add('hidden');

  const total   = QUESTIONS.length;
  const correct = results.filter(r => r.wasCorrect).length;
  const wrong   = results.filter(r => !r.wasCorrect && !r.skipped).length;
  const skipped = results.filter(r => r.skipped).length;
  const pct     = Math.round((correct / total) * 100);

  document.getElementById('resultsGrade').textContent   = pct + '%';
  document.getElementById('correctCount').textContent   = correct;
  document.getElementById('wrongCount').textContent     = wrong;
  document.getElementById('skippedCount').textContent   = skipped;
  document.getElementById('totalQ').textContent         = total;

  let label = '';
  if (pct >= 90) label = '🏆 Outstanding performance!';
  else if (pct >= 75) label = '🎯 Great work — above pass mark!';
  else if (pct >= 60) label = '📚 Good effort — review the misses.';
  // The line below was crashing the script!
  else label = "💪 Keep studying — you'll get there!";
  
  document.getElementById('resultsLabel').textContent = label;

  document.getElementById('resultsScreen').classList.add('visible');
}}

function showReview() {{
  const section = document.getElementById('reviewSection');
  section.classList.toggle('hidden');
  if (!section.classList.contains('hidden')) {{
    const list = document.getElementById('reviewList');
    list.innerHTML = '';
    results.forEach((r, i) => {{
      const q   = QUESTIONS[r.q];
      const div = document.createElement('div');
      div.className = 'review-item';
      div.onclick   = () => jumpTo(r.q);
      const stemShort = q.stem.length > 100 ? q.stem.slice(0, 100) + '…' : q.stem;
      div.innerHTML = `
        <div class="review-dot ${{r.wasCorrect ? 'correct' : 'wrong'}}"></div>
        <div class="review-text">Q${{r.q + 1}}. ${{escHtml(stemShort)}}</div>
        <div class="review-answer">${{r.skipped ? 'skipped' : `${{r.chosen}} → ${{r.correct}}`}}</div>
      `;
      list.appendChild(div);
    }});
  }}
}}

function jumpTo(idx) {{
  // Show quiz card at this question in review mode
  document.getElementById('resultsScreen').classList.remove('visible');
  document.getElementById('quizCard').classList.remove('hidden');
  document.getElementById('progressWrap').classList.remove('hidden');
  current  = idx;
  answered = false;
  renderQuestion(idx);
  // Auto-replay the answer
  const r = results.find(res => res.q === idx);
  if (r && !r.skipped) {{
    selected = r.chosen;
    setTimeout(submitAnswer, 80);
  }}
}}

function restartQuiz() {{
  current  = 0;
  score    = 0;
  results  = [];
  answered = false;
  selected = null;
  document.getElementById('scoreDisplay').textContent = '0 / 0';
  document.getElementById('resultsScreen').classList.remove('visible');
  document.getElementById('reviewSection').classList.add('hidden');
  document.getElementById('quizCard').classList.remove('hidden');
  document.getElementById('progressWrap').classList.remove('hidden');
  document.getElementById('submitBtn').onclick = submitAnswer;
  renderQuestion(0);
}}

// ── Utils ─────────────────────────────────────────────────────────────────────
function escHtml(str) {{
  return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}}

// ── Boot ──────────────────────────────────────────────────────────────────────
renderQuestion(0);
</script>
</body>
</html>"""

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(HTML)

print(f"\n  Output file : {out_path}")
print(f"  File size   : {os.path.getsize(out_path):,} bytes")
PYEOF

ok "Done! Open in your browser: $OUTPUT"