#!/usr/bin/env bash
# =============================================================================
# build_quiz_site.sh
# Converts a JSON quiz file into a self-contained HTML quiz app.
#
# USAGE:
#   ./build_quiz_site.sh <quiz.json> [output.html]
#
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

[[ -z "$INPUT" ]]        && error "Usage: $0 <quiz.json> [output.html]"
[[ ! -f "$INPUT" ]]      && error "File not found: $INPUT"
[[ ! -f "$TEMPLATE" ]]   && error "template.html not found in $SCRIPT_DIR"
command -v python3 >/dev/null 2>&1 || error "python3 is required."

info "Parsing JSON: $INPUT"

python3 - "$INPUT" "$OUTPUT" "$TEMPLATE" << 'PYEOF'
import sys, json, os

md_path       = sys.argv[1]
out_path      = sys.argv[2]
template_path = sys.argv[3]

# ── Parse quiz JSON ────────────────────────────────────────────────────────────
try:
    with open(md_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"  [ERROR] Invalid JSON file: {e}")
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
    print("  [ERROR] No questions found in the 'interactive_quiz' array.")
    sys.exit(1)

print(f"  Total mapped : {len(all_questions)} questions")

# ── Build substitution values ─────────────────────────────────────────────────
quiz_json = json.dumps(all_questions, ensure_ascii=False).replace("</", "<\\/")
title     = os.path.splitext(os.path.basename(md_path))[0].replace('_', ' ').title()
total     = str(len(all_questions))

# ── Read template and inject ──────────────────────────────────────────────────
with open(template_path, 'r', encoding='utf-8') as f:
    html = f.read()

html = html.replace('__QUIZ_TITLE__', title)
html = html.replace('__QUIZ_TOTAL__', total)
html = html.replace('__QUESTIONS_JSON__', quiz_json)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(html)

print(f"  Output file  : {out_path}")
print(f"  File size    : {os.path.getsize(out_path):,} bytes")
PYEOF

ok "Done! Open in your browser: $OUTPUT"
