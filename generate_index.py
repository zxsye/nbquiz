#!/usr/bin/env python3
"""
generate_index.py
Scans the gh-pages output directory for quiz HTML files and generates index.html.

Usage:
    python3 generate_index.py <output_dir>

Expects HTML files at: <output_dir>/<week>/<topic>/<name>.html
Reads sidecar <name>.meta.json for question count if available.
"""

import sys, os, re, json
from collections import defaultdict

out_dir = sys.argv[1] if len(sys.argv) > 1 else '.'

# ── Scan for quiz HTML files ──────────────────────────────────────────────────
quizzes = defaultdict(lambda: defaultdict(list))

for root, dirs, files in os.walk(out_dir):
    dirs[:] = [d for d in dirs if not d.startswith('.')]
    for fname in sorted(files):
        if not fname.endswith('.html') or fname == 'index.html':
            continue
        full = os.path.join(root, fname)
        rel  = os.path.relpath(full, out_dir).replace('\\', '/')
        parts = rel.split('/')
        if len(parts) != 3:
            continue
        week, topic, vfile = parts
        name = os.path.splitext(vfile)[0]

        # Read sidecar meta if available
        meta_path = os.path.join(root, name + '.meta.json')
        q_count = None
        if os.path.exists(meta_path):
            try:
                with open(meta_path) as f:
                    q_count = json.load(f).get('questions')
            except Exception:
                pass

        quizzes[week][topic].append((name, rel, q_count))

if not quizzes:
    print("  No quizzes found — generating empty index.")

def week_sort_key(w):
    m = re.match(r'^W(\d+)$', w, re.IGNORECASE)
    return (0, int(m.group(1))) if m else (1, w)

sorted_weeks = sorted(quizzes.keys(), key=week_sort_key)

# ── Build cards HTML ──────────────────────────────────────────────────────────
cards_html = ''
for week in sorted_weeks:
    topics = quizzes[week]
    rows = ''
    for topic in sorted(topics.keys()):
        versions = sorted(topics[topic], key=lambda x: x[0])
        links = ''
        for name, path, q_count in versions:
            count_badge = f'<span class="q-count">{q_count}q</span>' if q_count else ''
            links += f'<a href="{path}" class="ver-link">{name}{count_badge}</a>'
        rows += f'''
        <div class="topic-row">
          <span class="topic-name">{topic.capitalize()}</span>
          <div class="ver-links">{links}</div>
        </div>'''
    cards_html += f'''
    <div class="week-card">
      <div class="week-label">{week.upper()}</div>
      <div class="topic-list">{rows}
      </div>
    </div>'''

if not cards_html:
    cards_html = '<p class="empty">No quizzes yet. Push an HTML file to get started.</p>'

# ── Full index.html ───────────────────────────────────────────────────────────
html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NB Quiz</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Crimson+Pro:wght@400;600&family=DM+Sans:wght@400;500;600&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
*, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
:root {{
  --bg:      #f7f5f0;
  --surface: #ffffff;
  --border:  #e2ddd5;
  --text:    #1a1714;
  --text-2:  #5a534a;
  --text-3:  #9a8f83;
  --accent:  #2563a8;
  --accent-light: #dbeafe;
  --radius:  10px;
  --radius-lg: 16px;
  --shadow:  0 1px 3px rgba(0,0,0,.07), 0 4px 16px rgba(0,0,0,.06);
  --font-serif: 'Crimson Pro', Georgia, serif;
  --font-sans:  'DM Sans', system-ui, sans-serif;
  --font-mono:  'DM Mono', monospace;
}}
body {{
  font-family: var(--font-sans);
  background: var(--bg);
  color: var(--text);
  min-height: 100vh;
  padding: 48px 24px 80px;
}}
.page-header {{
  max-width: 720px;
  margin: 0 auto 48px;
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  padding-bottom: 20px;
  border-bottom: 1.5px solid var(--border);
}}
.logo {{
  font-family: var(--font-serif);
  font-size: 2rem;
  font-weight: 600;
  color: var(--text);
}}
.logo span {{ color: var(--accent); }}
.credit {{
  font-size: .72rem;
  color: var(--text-3);
  font-family: var(--font-mono);
}}
.grid {{
  max-width: 720px;
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  gap: 16px;
}}
.week-card {{
  background: var(--surface);
  border: 1.5px solid var(--border);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow);
  overflow: hidden;
}}
.week-label {{
  font-family: var(--font-mono);
  font-size: .7rem;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: .1em;
  color: var(--text-3);
  padding: 14px 20px 10px;
  border-bottom: 1px solid var(--border);
  background: var(--bg);
}}
.topic-list {{ padding: 8px 0; }}
.topic-row {{
  display: flex;
  align-items: center;
  padding: 10px 20px;
  gap: 16px;
  border-bottom: 1px solid var(--border);
}}
.topic-row:last-child {{ border-bottom: none; }}
.topic-name {{
  font-size: .95rem;
  font-weight: 500;
  color: var(--text);
  min-width: 120px;
}}
.ver-links {{
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}}
.ver-link {{
  font-family: var(--font-mono);
  font-size: .78rem;
  font-weight: 500;
  padding: 4px 12px;
  border: 1.5px solid var(--border);
  border-radius: 99px;
  color: var(--accent);
  text-decoration: none;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  transition: background .15s, border-color .15s;
}}
.ver-link:hover {{
  background: var(--accent-light);
  border-color: var(--accent);
}}
.q-count {{
  font-size: .68rem;
  color: var(--text-3);
  background: var(--bg);
  border-radius: 99px;
  padding: 1px 6px;
  border: 1px solid var(--border);
}}
.ver-link:hover .q-count {{
  background: var(--accent-light);
  border-color: var(--accent);
}}
.empty {{
  text-align: center;
  color: var(--text-3);
  font-size: .9rem;
  padding: 48px;
}}
@media (max-width: 520px) {{
  .topic-row {{ flex-direction: column; align-items: flex-start; gap: 8px; }}
  .topic-name {{ min-width: unset; }}
}}
</style>
</head>
<body>
<header class="page-header">
  <div class="logo">NB <span>Quiz</span></div>
  <div class="credit">made by Zi Lin</div>
</header>
<main class="grid">
{cards_html}
</main>
</body>
</html>'''

index_path = os.path.join(out_dir, 'index.html')
with open(index_path, 'w', encoding='utf-8') as f:
    f.write(html)

total_quizzes = sum(len(v) for w in quizzes.values() for v in w.values())
print(f"  index.html → {index_path}  ({len(sorted_weeks)} weeks, {total_quizzes} quizzes)")
