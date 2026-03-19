#!/usr/bin/env bash
# =============================================================================
# extract_notebooklm_quiz.sh
# Extracts quiz questions & answers from a NotebookLM saved webpage folder.
#
# USAGE:
#   ./extract_notebooklm_quiz_json.sh <path/to/saved_page_folder_or_file> [output.md]
#
# SUPPORTS:
#   - Single .htm/.html file (browser "Save Page As > Webpage, Complete")
#   - .mhtml file (browser "Save Page As > Webpage, Single File")
#   - A folder containing the saved page files (looks for shim.html + main .htm)
#
# OUTPUT:
#   A markdown file with all extracted questions, answers, rationales, and hints.
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

[[ -z "$INPUT" ]] && error "Usage: $0 <saved_page_folder_or_file> [output.md]"
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

def strip_tags(text):
    text = re.sub(r'<[^>]+>', ' ', text)
    text = re.sub(r'&lt;',  '<',  text)
    text = re.sub(r'&gt;',  '>',  text)
    text = re.sub(r'&amp;', '&',  text)
    text = re.sub(r'&nbsp;',' ',  text)
    return re.sub(r'\s+', ' ', text).strip()

def clean_math(text):
    """Remove LaTeX/KaTeX wrappers common in NotebookLM quiz exports."""
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
    text = re.sub(r'\$([^$]+)\$', r'\1', text)  # strip remaining $ wrappers
    text = text.replace('\\u0027', "'")
    return text

def read_file(path):
    with open(path, 'r', errors='replace') as f:
        return f.read()

# ── Locate source files ───────────────────────────────────────────────────────

shim_file  = None   # interactive quiz (30 Qs JSON)
main_file  = None   # chat Q&As (10 Qs text)
mhtml_file = None

if os.path.isdir(input_path):
    # "Save Page As > Webpage, Complete" produces a folder + .htm file
    for f in glob.glob(os.path.join(input_path, '**', 'shim.html'), recursive=True):
        shim_file = f; break
    for f in glob.glob(os.path.join(input_path, '**', '*.htm'), recursive=True) + \
              glob.glob(os.path.join(input_path, '**', '*.html'), recursive=True):
        if 'shim' not in os.path.basename(f).lower() and \
           'app' not in os.path.basename(f).lower() and \
           'rotate' not in os.path.basename(f).lower() and \
           'saved' not in os.path.basename(f).lower():
            main_file = f; break
    # Also check parent dir for .htm
    parent = os.path.dirname(input_path.rstrip('/'))
    for f in glob.glob(os.path.join(parent, '*.htm')):
        main_file = f; break
elif input_path.endswith('.mhtml'):
    mhtml_file = input_path
elif input_path.endswith(('.htm', '.html')):
    # Check if this file IS a shim (contains data-app-data= signature)
    with open(input_path, 'r', errors='replace') as _f:
        _sample = _f.read(8192)
    if 'data-app-data=' in _sample:
        shim_file = input_path
    else:
        main_file = input_path
    # Also look for accompanying _files folder
    base = re.sub(r'\.(htm|html)$', '', input_path)
    for suffix in ['_files', ' Files', '_Files']:
        folder = base + suffix
        if os.path.isdir(folder):
            candidate = os.path.join(folder, 'shim.html')
            if os.path.exists(candidate):
                shim_file = candidate
                break

# If given a folder directly, also check for shim.html inside it
if os.path.isdir(input_path):
    candidate = os.path.join(input_path, 'shim.html')
    if os.path.exists(candidate) and shim_file is None:
        shim_file = candidate

print(f"  Main page file : {main_file or '(not found)'}")
print(f"  Quiz shim file : {shim_file or '(not found)'}")
print(f"  MHTML file     : {mhtml_file or '(not found)'}")
print()

quiz_questions   = []  # from shim.html JSON
chat_questions   = []  # from main .htm text
total_found      = 0

# ── PART A: Extract interactive quiz from shim.html ───────────────────────────

def extract_shim_quiz(path):
    content = read_file(path)
    idx = content.find('data-app-data="')
    if idx == -1:
        print("  [WARN] No data-app-data attribute found in shim.html")
        return []
    raw_start = idx + len('data-app-data="')
    pos = raw_start
    while pos < len(content):
        if content[pos:pos+6] == '&quot;':
            pos += 6
        elif content[pos] == '"':
            break
        else:
            pos += 1
    raw_attr = content[raw_start:pos]
    decoded  = html.unescape(raw_attr)
    try:
        data = json.loads(decoded)
        return data.get('quiz', [])
    except json.JSONDecodeError as e:
        print(f"  [WARN] JSON parse error in shim.html: {e}")
        return []

if shim_file:
    quiz_questions = extract_shim_quiz(shim_file)
    print(f"  Interactive quiz questions found : {len(quiz_questions)}")

# ── PART B: Extract chat Q&As from main .htm or .mhtml ───────────────────────

def extract_chat_questions(raw_content, is_mhtml=False):
    if is_mhtml:
        import quopri
        try:
            raw_content = quopri.decodestring(raw_content.encode('latin-1')).decode('utf-8', errors='replace')
        except Exception:
            pass
    text = strip_tags(raw_content)
    start = text.find('Question 1: Clinical Vignette')
    if start == -1:
        start = text.find('Question 1:')
    end = text.find('Note: Due to system response length', start if start != -1 else 0)
    if start == -1:
        return []
    chunk = text[start: end if end != -1 else start + 300000]
    blocks = re.split(r'-{10,}', chunk)
    return [b.strip() for b in blocks if b.strip() and 'Question' in b]

if mhtml_file:
    raw = read_file(mhtml_file)
    chat_questions = extract_chat_questions(raw, is_mhtml=True)
elif main_file:
    raw = read_file(main_file)
    chat_questions = extract_chat_questions(raw, is_mhtml=False)

print(f"  Chat Q&A questions found         : {len(chat_questions)}")

total_found = len(quiz_questions) + len(chat_questions)
if total_found == 0:
    print("\n  [ERROR] No questions found. Check that you saved the page correctly.")
    sys.exit(1)

# ── PART C: Build JSON output ──────────────────────────────────────────────────

output = {
    "total_questions": total_found,
    "interactive_quiz": [],
    "chat_questions": [],
}

# Interactive quiz questions
for i, q in enumerate(quiz_questions, 1):
    question = clean_math(q.get('question', ''))
    hint     = clean_math(q.get('hint', ''))
    options  = q.get('answerOptions', [])

    correct_letter = None
    built_options  = []

    for j, opt in enumerate(options):
        letter   = chr(65 + j)
        opt_text = clean_math(opt.get('text', ''))
        rat      = clean_math(opt.get('rationale', ''))
        is_right = opt.get('isCorrect', False)
        if is_right:
            correct_letter = letter
        built_options.append({
            "letter":     letter,
            "text":       opt_text,
            "is_correct": is_right,
            "rationale":  rat,
        })

    output["interactive_quiz"].append({
        "number":         i,
        "stem":           question,
        "options":        built_options,
        "correct_answer": correct_letter,
        "hint":           hint,
    })

# Chat questions (plain-text blocks)
for i, block in enumerate(chat_questions, 1):
    block = re.sub(r' {2,}', ' ', block).strip()
    output["chat_questions"].append({
        "number": i,
        "text":   block,
    })

# Write output
with open(output_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)

print(f"\n  Written to: {output_path}")
print(f"  File size : {os.path.getsize(output_path):,} bytes")

PYEOF

echo ""
success "Done! Quiz saved to: $OUTPUT"
echo ""
echo -e "  ${CYAN}Preview first question:${NC}"
head -30 "$OUTPUT"
