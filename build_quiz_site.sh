#!/usr/bin/env bash
# =============================================================================
# build_quiz_site.sh
# Converts a JSON quiz file into a self-contained HTML quiz app.
#
# USAGE:
#   ./build_quiz_site.sh <quiz.json> <output.html>
#
# Expects input path in the form: quizzes/W7/neuro/v1.json
# Derives week, topic, version from the path automatically.
# Requires template.html in the same directory as this script.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

INPUT="${1:-}"
OUTPUT="${2:-quiz.html}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/template.html"

[[ -z "$INPUT" ]]      && error "Usage: $0 <quiz.json> <output.html>"
[[ ! -f "$INPUT" ]]    && error "File not found: $INPUT"
[[ ! -f "$TEMPLATE" ]] && error "template.html not found in $SCRIPT_DIR"
command -v python3 >/dev/null 2>&1 || error "python3 is required."

info "Building: $INPUT → $OUTPUT"

python3 - "$INPUT" "$OUTPUT" "$TEMPLATE" << 'PYEOF'
import sys, json, os

md_path       = sys.argv[1]
out_path      = sys.argv[2]
template_path = sys.argv[3]

# ── Derive week / topic / version from path ───────────────────────────────────
# Expects something like: quizzes/W7/neuro/v1.json
# Falls back gracefully if path doesn't match the convention.
parts = md_path.replace('\\', '/').split('/')
# Strip 'quizzes/' prefix if present
if parts[0] == 'quizzes':
    parts = parts[1:]

version = os.path.splitext(parts[-1])[0] if parts else 'v1'
topic   = parts[-2].capitalize()         if len(parts) >= 2 else 'Quiz'
week    = parts[-3].upper()              if len(parts) >= 3 else ''

# Display title: "W7 · Neuro · v1"
if week:
    display_title = f"{week} · {topic} · {version}"
else:
    display_title = f"{topic} · {version}"

# Firestore quiz_id: unique path-based key e.g. "W7/neuro/v1"
# Using the last 3 path segments (without extension) joined by /
raw_parts = [p for p in parts if p]
quiz_id_parts = [os.path.splitext(p)[0] if p == raw_parts[-1] else p for p in raw_parts[-3:]]
quiz_id = '/'.join(quiz_id_parts)

# ── Parse quiz JSON ────────────────────────────────────────────────────────────
try:
    with open(md_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"  [ERROR] Invalid JSON: {e}")
    sys.exit(1)

all_questions = []

if 'interactive_quiz' in data:
    for q in data['interactive_quiz']:
        options_dict    = {}
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
    print("  [ERROR] No questions found in 'interactive_quiz'.")
    sys.exit(1)

print(f"  Quiz ID      : {quiz_id}")
print(f"  Title        : {display_title}")
print(f"  Questions    : {len(all_questions)}")

# ── Inject into template ──────────────────────────────────────────────────────
quiz_json = json.dumps(all_questions, ensure_ascii=False).replace("</", "<\\/")
total     = str(len(all_questions))

with open(template_path, 'r', encoding='utf-8') as f:
    html = f.read()

html = html.replace('__QUIZ_TITLE__',    display_title)
html = html.replace('__QUIZ_ID__',       quiz_id)
html = html.replace('__QUIZ_TOTAL__',    total)
html = html.replace('__QUESTIONS_JSON__', quiz_json)

os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(html)

print(f"  Output       : {out_path}")
print(f"  Size         : {os.path.getsize(out_path):,} bytes")
PYEOF

ok "Done → $OUTPUT"
