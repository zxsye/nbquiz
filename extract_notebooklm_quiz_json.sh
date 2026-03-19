#!/usr/bin/env bash
# =============================================================================
# extract_notebooklm_quiz_json.sh
# Extracts quiz questions & answers from a NotebookLM saved webpage.
#
# USAGE:
#   ./extract_notebooklm_quiz_json.sh <path/to/saved_page.html> [output.json]
#
# SUPPORTS:
#   - Single .htm/.html file saved from the NotebookLM quiz page
#     (browser "Save Page As > Webpage, Complete" or "Single File")
#   - Also handles the older folder+shim.html layout as a fallback
#
# OUTPUT:
#   A JSON file with all extracted questions, answer options, correct answers,
#   per-option rationales, and hints.
# =============================================================================

set -euo pipefail

# --- Colours ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Args ---
INPUT="${1:-}"
OUTPUT="${2:-notebooklm_quiz.json}"

[[ -z "$INPUT" ]]   && error "Usage: $0 <saved_page.html> [output.json]"
[[ ! -e "$INPUT" ]] && error "Input not found: $INPUT"

command -v python3 >/dev/null 2>&1 || error "python3 is required but not found."

info "Input:  $INPUT"
info "Output: $OUTPUT"
echo ""

# --- Python extraction ---
python3 - "$INPUT" "$OUTPUT" << 'PYEOF'
import sys, os, re, html, json, glob

input_path = sys.argv[1]
output_path = sys.argv[2]

# ── Helpers ──────────────────────────────────────────────────────────────────

def clean_math(text):
    """Remove or normalise common LaTeX/KaTeX fragments found in NotebookLM exports."""
    replacements = [
        (r'\$GCS\$',    'GCS'),   (r'\$CT\$',     'CT'),
        (r'\$MRI\$',    'MRI'),   (r'\$SpO_2\$',  'SpO2'),
        (r'\$PaO_2\$',  'PaO2'),  (r'\$PaCO_2\$', 'PaCO2'),
        (r'\$FiO_2\$',  'FiO2'),  (r'\$Na\^\+\$', 'Na+'),
        (r'\$K\^\+\$',  'K+'),    (r'\\\%',        '%'),
    ]
    for pat, rep in replacements:
        text = re.sub(pat, rep, text)
    text = re.sub(r'\\text\{([^}]+)\}', r'\1', text)
    text = re.sub(r'\$([^$]+)\$', r'\1', text)   # strip remaining $ wrappers
    text = text.replace('\\u0027', "'")
    return text

def read_file(path):
    with open(path, 'r', errors='replace') as f:
        return f.read()

# ── Locate the HTML that contains data-app-data ───────────────────────────────

candidate_files = []

if os.path.isfile(input_path):
    candidate_files.append(input_path)
    # Also look for a shim.html next to or inside a companion _files folder
    base = re.sub(r'\.(htm|html)$', '', input_path, flags=re.IGNORECASE)
    for suffix in ['_files', ' Files', '_Files']:
        shim = os.path.join(base + suffix, 'shim.html')
        if os.path.exists(shim):
            candidate_files.append(shim)
elif os.path.isdir(input_path):
    for pat in ['**/*.html', '**/*.htm']:
        candidate_files.extend(glob.glob(os.path.join(input_path, pat), recursive=True))

source_file = None
for f in candidate_files:
    content = read_file(f)
    if 'data-app-data=' in content and 'answerOptions' in content:
        source_file = f
        print(f"  Source file    : {source_file}")
        break

if source_file is None:
    print("  [ERROR] Could not find a file containing quiz data (data-app-data attribute).")
    print("          Make sure you saved the NotebookLM quiz page correctly.")
    sys.exit(1)

# ── Parse the data-app-data attribute ────────────────────────────────────────

def extract_app_data(content):
    """
    The quiz data lives in:
      <app-root data-app-data="...HTML-entity-encoded JSON...">

    The attribute value uses &quot; for " and &#39; for ', so we scan
    character-by-character until we hit an unescaped closing quote.
    """
    marker = 'data-app-data="'
    idx = content.find(marker)
    if idx == -1:
        return None

    raw_start = idx + len(marker)
    pos = raw_start
    while pos < len(content):
        chunk = content[pos:]
        # HTML entity for a double-quote — keep going
        if chunk.startswith('&quot;'):
            pos += 6
        elif chunk.startswith('&#34;'):
            pos += 5
        # Actual closing quote — end of attribute
        elif content[pos] == '"':
            break
        else:
            pos += 1

    raw_attr = content[raw_start:pos]
    decoded  = html.unescape(raw_attr)
    return decoded

raw_content = read_file(source_file)
decoded_json = extract_app_data(raw_content)

if decoded_json is None:
    print("  [ERROR] data-app-data attribute not found in the HTML.")
    sys.exit(1)

try:
    data = json.loads(decoded_json)
except json.JSONDecodeError as e:
    print(f"  [ERROR] Failed to parse JSON from data-app-data: {e}")
    sys.exit(1)

quiz_raw = data.get('quiz', [])
print(f"  Questions found: {len(quiz_raw)}")

if not quiz_raw:
    print("  [ERROR] JSON parsed successfully but no 'quiz' array found.")
    sys.exit(1)

# ── Build structured output ───────────────────────────────────────────────────

questions = []

for i, q in enumerate(quiz_raw, 1):
    stem    = clean_math(q.get('question', ''))
    hint    = clean_math(q.get('hint', ''))
    options = q.get('answerOptions', [])

    correct_letter = None
    built_options  = []

    for j, opt in enumerate(options):
        letter   = chr(65 + j)   # A, B, C, …
        opt_text = clean_math(opt.get('text', ''))
        rat      = clean_math(opt.get('rationale', ''))
        is_right = bool(opt.get('isCorrect', False))

        if is_right:
            correct_letter = letter

        built_options.append({
            "letter":     letter,
            "text":       opt_text,
            "is_correct": is_right,
            "rationale":  rat,
        })

    questions.append({
        "number":         i,
        "stem":           stem,
        "options":        built_options,
        "correct_answer": correct_letter,
        "hint":           hint,
    })

output = {
    "total_questions": len(questions),
    "questions":       questions,
}

# ── Write JSON ────────────────────────────────────────────────────────────────

with open(output_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)

print(f"\n  Written to : {output_path}")
print(f"  File size  : {os.path.getsize(output_path):,} bytes")
print()

# Quick preview of first question
q0 = questions[0]
print(f"  ── Preview: Question 1 ──")
print(f"  {q0['stem'][:100]}{'...' if len(q0['stem']) > 100 else ''}")
for opt in q0['options']:
    tick = "✓" if opt['is_correct'] else " "
    print(f"    [{tick}] {opt['letter']}. {opt['text'][:70]}")
print(f"  Hint: {q0['hint'][:80]}")

PYEOF

echo ""
success "Done! Quiz JSON saved to: $OUTPUT"
