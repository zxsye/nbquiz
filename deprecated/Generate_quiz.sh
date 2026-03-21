#!/usr/bin/env bash
# =============================================================================
# generate_quiz.sh
# Wraps the extraction, joining, batching, and build scripts into a single streamlined process.
#
# -----------------------------------------------------------------------------
# SETUP INSTRUCTIONS:
# -----------------------------------------------------------------------------
# Before running this script for the first time, you must make the scripts executable:
#
# * chmod +x generate_quiz.sh
# * chmod +x extract_notebooklm_quiz_json.sh
# * chmod +x build_quiz_site.sh
#
# -----------------------------------------------------------------------------
# USAGE MODES:
# -----------------------------------------------------------------------------
# 1. Standard Extraction (Default Interactive Mode)
#    ./generate_quiz.sh
#
# 2. Standard Extraction (Fast Mode)
#    ./generate_quiz.sh [input_path] [json_output] [html_output]
#
# 3. Join Two JSONs
#    ./generate_quiz.sh --join [json1] [json2] [json_out] [html_out]
#
# 4. Batch Extract & Combine (Comma-separated folders/files)
#    ./generate_quiz.sh --batch [folder1,folder2,...] [json_out] [html_out]
#
# =============================================================================

set -euo pipefail

# --- Colours ---
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Script Paths ---
EXTRACT_SCRIPT="./extract_notebooklm_quiz_json.sh"
BUILD_SCRIPT="./build_quiz_site.sh"

# --- Determine Mode ---
MODE="extract"
if [[ "${1:-}" == "--join" ]]; then
    MODE="join"
    shift
elif [[ "${1:-}" == "--batch" ]]; then
    MODE="batch"
    shift
fi

# Ensure build script is executable (required for all modes)
if [[ ! -x "$BUILD_SCRIPT" ]]; then
    error "Cannot execute $BUILD_SCRIPT. Ensure it exists and has execute permissions."
fi

# Dependency check for jq (needed for join and batch modes)
if [[ "$MODE" == "join" || "$MODE" == "batch" ]]; then
    if ! command -v jq &> /dev/null; then
        error "'jq' is required for merging JSON files. Please install it (e.g., 'brew install jq' or 'sudo apt install jq')."
    fi
fi

# =========================================================================
# MODE: BATCH
# =========================================================================
if [[ "$MODE" == "batch" ]]; then
    echo -e "${CYAN}=== NeuroQuiz Generator Pipeline (Batch Mode) ===${NC}\n"

    if [[ ! -x "$EXTRACT_SCRIPT" ]]; then
        error "Cannot execute $EXTRACT_SCRIPT. Ensure it exists and has execute permissions."
    fi

    INPUT_LIST="${1:-}"
    JSON_OUT="${2:-}"
    HTML_OUT="${3:-}"

    if [[ -z "$INPUT_LIST" ]]; then
        read -p "1. Enter comma-separated paths to folders/files (e.g., folder1,folder2): " INPUT_LIST
    fi
    [[ -z "$INPUT_LIST" ]] && error "Input list is required to proceed."

    DEFAULT_JSON="batch_combined_quiz.json"
    DEFAULT_HTML="batch_combined_quiz.html"

    if [[ -z "$JSON_OUT" ]]; then
        read -p "2. Enter name for combined JSON file [default: $DEFAULT_JSON]: " JSON_OUT
        JSON_OUT=${JSON_OUT:-$DEFAULT_JSON}
    fi

    if [[ -z "$HTML_OUT" ]]; then
        read -p "3. Enter name for final HTML website file [default: $DEFAULT_HTML]: " HTML_OUT
        HTML_OUT=${HTML_OUT:-$DEFAULT_HTML}
    fi

    echo ""
    info "Starting BATCH pipeline..."
    
    # Parse comma-separated list into an array
    IFS=',' read -r -a INPUT_ARRAY <<< "$INPUT_LIST"
    
    TEMP_FILES=()
    
    # Extract JSON for each input
    info "STEP 1: Extracting JSON from ${#INPUT_ARRAY[@]} sources..."
    for input_item in "${INPUT_ARRAY[@]}"; do
        # Trim whitespace
        input_item=$(echo "$input_item" | xargs)
        
        if [[ ! -e "$input_item" ]]; then
            error "Input not found: $input_item"
        fi
        
        info "  -> Extracting: $input_item"
        TEMP_JSON=$(mktemp)
        TEMP_FILES+=("$TEMP_JSON")
        
        "$EXTRACT_SCRIPT" "$input_item" "$TEMP_JSON" > /dev/null
    done
    
    echo "------------------------------------------------------------"
    info "STEP 2: Merging extracted JSONs and renumbering questions..."
    
    # Dynamically merge all temporary files
    jq -s '
      (map(.interactive_quiz) | flatten | to_entries | map(.value + {number: (.key + 1)})) as $merged_quiz |
      {
        total_questions: ($merged_quiz | length),
        interactive_quiz: $merged_quiz,
        chat_questions: (map(.chat_questions) | flatten | unique)
      }
    ' "${TEMP_FILES[@]}" > "$JSON_OUT"

    # Clean up temporary files
    rm -f "${TEMP_FILES[@]}"

    if [[ ! -s "$JSON_OUT" ]]; then
        error "Merge step failed or resulted in empty JSON. $JSON_OUT was not created properly."
    fi

    echo "------------------------------------------------------------"
    info "STEP 3: Building HTML site..."
    "$BUILD_SCRIPT" "$JSON_OUT" "$HTML_OUT"

    if [[ -f "$HTML_OUT" ]]; then
        echo "------------------------------------------------------------"
        success "Batch pipeline complete! Your combined interactive quiz is ready."
        info "You can open it in your browser: file://$(pwd)/$HTML_OUT"
    else
        error "Build step failed. $HTML_OUT was not created."
    fi

# =========================================================================
# MODE: JOIN
# =========================================================================
elif [[ "$MODE" == "join" ]]; then
    echo -e "${CYAN}=== NeuroQuiz Generator Pipeline (Join Mode) ===${NC}\n"

    FILE1="${1:-}"
    FILE2="${2:-}"
    JSON_OUT="${3:-}"
    HTML_OUT="${4:-}"

    if [[ -z "$FILE1" ]]; then
        read -p "1. Enter path to the FIRST JSON file: " FILE1
    fi
    [[ ! -f "$FILE1" ]] && error "File not found: $FILE1"

    if [[ -z "$FILE2" ]]; then
        read -p "2. Enter path to the SECOND JSON file: " FILE2
    fi
    [[ ! -f "$FILE2" ]] && error "File not found: $FILE2"

    DEFAULT_JSON="combined_quiz.json"
    DEFAULT_HTML="combined_quiz.html"

    if [[ -z "$JSON_OUT" ]]; then
        read -p "3. Enter name for combined JSON file [default: $DEFAULT_JSON]: " JSON_OUT
        JSON_OUT=${JSON_OUT:-$DEFAULT_JSON}
    fi

    if [[ -z "$HTML_OUT" ]]; then
        read -p "4. Enter name for final HTML website file [default: $DEFAULT_HTML]: " HTML_OUT
        HTML_OUT=${HTML_OUT:-$DEFAULT_HTML}
    fi

    echo ""
    info "Starting JOIN pipeline with:"
    info "  File 1 : $FILE1"
    info "  File 2 : $FILE2"
    echo "------------------------------------------------------------"

    info "STEP 1: Merging JSON files and renumbering questions..."
    
    jq -s '
      (map(.interactive_quiz) | flatten | to_entries | map(.value + {number: (.key + 1)})) as $merged_quiz |
      {
        total_questions: ($merged_quiz | length),
        interactive_quiz: $merged_quiz,
        chat_questions: (map(.chat_questions) | flatten | unique)
      }
    ' "$FILE1" "$FILE2" > "$JSON_OUT"

    if [[ ! -s "$JSON_OUT" ]]; then
        error "Merge step failed. $JSON_OUT was not created properly."
    fi

    echo "------------------------------------------------------------"
    info "STEP 2: Building HTML site..."
    "$BUILD_SCRIPT" "$JSON_OUT" "$HTML_OUT"

    if [[ -f "$HTML_OUT" ]]; then
        echo "------------------------------------------------------------"
        success "Pipeline complete! Your combined interactive quiz is ready."
        info "You can open it in your browser: file://$(pwd)/$HTML_OUT"
    else
        error "Build step failed. $HTML_OUT was not created."
    fi

# =========================================================================
# MODE: EXTRACT (Standard/Default)
# =========================================================================
else
    if [[ ! -x "$EXTRACT_SCRIPT" ]]; then
        error "Cannot execute $EXTRACT_SCRIPT. Ensure it exists and has execute permissions."
    fi

    echo -e "${CYAN}=== NeuroQuiz Generator Pipeline ===${NC}\n"

    INPUT="${1:-}"
    JSON_OUT="${2:-}"
    HTML_OUT="${3:-}"

    # 1. Ask for file or folder
    if [[ -z "$INPUT" ]]; then
        read -p "1. Enter path to a file or folder: " INPUT
    fi
    [[ -z "$INPUT" ]] && error "Input path is required to proceed."
    [[ ! -e "$INPUT" ]] && error "Input not found: $INPUT"

    # --- Extract Base Name for Defaults ---
    # `basename` safely grabs the last segment (ignoring trailing slashes)
    BASE_NAME="$(basename "$INPUT")"
    
    # Strip common file extensions if the user pointed to a file instead of a folder
    BASE_NAME="${BASE_NAME%.mhtml}"
    BASE_NAME="${BASE_NAME%.html}"
    BASE_NAME="${BASE_NAME%.htm}"
    BASE_NAME="${BASE_NAME%.txt}"
    
    # Fallback in the rare event the name ends up empty
    BASE_NAME="${BASE_NAME:-quiz_data}"

    DEFAULT_JSON="${BASE_NAME}.json"
    DEFAULT_HTML="${BASE_NAME}.html"

    # 2. Ask for JSON name using the dynamically generated default
    if [[ -z "$JSON_OUT" ]]; then
        read -p "2. Enter name for intermediate JSON file [default: $DEFAULT_JSON]: " JSON_OUT
        JSON_OUT=${JSON_OUT:-$DEFAULT_JSON}
    fi

    # 3. Ask for HTML name using the dynamically generated default
    if [[ -z "$HTML_OUT" ]]; then
        read -p "3. Enter name for final HTML website file [default: $DEFAULT_HTML]: " HTML_OUT
        HTML_OUT=${HTML_OUT:-$DEFAULT_HTML}
    fi

    echo ""
    info "Starting pipeline with:"
    info "  Input : $INPUT"
    info "  JSON  : $JSON_OUT"
    info "  HTML  : $HTML_OUT"
    echo "------------------------------------------------------------"

    info "STEP 1: Extracting data..."
    "$EXTRACT_SCRIPT" "$INPUT" "$JSON_OUT"

    if [[ ! -s "$JSON_OUT" ]]; then
        error "Extraction step failed. $JSON_OUT was not created."
    fi

    echo "------------------------------------------------------------"
    info "STEP 2: Building HTML site..."
    "$BUILD_SCRIPT" "$JSON_OUT" "$HTML_OUT"

    if [[ -f "$HTML_OUT" ]]; then
        echo "------------------------------------------------------------"
        success "Pipeline complete! Your interactive quiz is ready."
        info "You can open it in your browser: file://$(pwd)/$HTML_OUT"
    else
        error "Build step failed. $HTML_OUT was not created."
    fi
fi