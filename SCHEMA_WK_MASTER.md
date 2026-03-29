# Week Master Reference Schema (SCHEMA_WK_MASTER)

## Overview

This document defines a **generic, rotation-agnostic schema** for representing weekly medical curriculum data in both JSON and Markdown formats. The schema supports any clinical rotation (Surgery, Medicine, GP, Psychiatry, Paediatrics, etc.) while allowing rotation-specific fields where needed.

## Schema Version

- **Version**: 1.1.0
- **Last Updated**: 2026-03-29
- **Breaking Changes**: None from v1.0.0 (backward compatible)

---

## Design Principles

1. **Rotation Agnostic**: Core fields work for any medical rotation
2. **Extensible**: Rotation-specific data goes in flexible arrays/objects
3. **Backward Compatible**: Existing Surgery data remains valid
4. **Self-Documenting**: Schema version and metadata included in exports

---

## JSON Schema

### Root Object

```typescript
interface WeekData {
  schemaVersion: string;        // Schema version (e.g., "1.1.0")
  exportDate: string;           // ISO 8601 timestamp
  section: string;              // Rotation identifier: "surgery", "medicine", "gp", etc.
  week: Week;
}
```

### Week Object

```typescript
interface Week {
  id: string;                   // Week identifier (e.g., "wk1", "wk2", "m1", "gp3")
  number: number;               // Week number within rotation
  title: string;                // Week title/specialty focus
  rotation: string;             // Clinical rotation context (e.g., "Neurosurgery rotation")
  handbookWeek?: string;        // Optional: Handbook week reference
  totalLectureMinutes: number;  // Total lecture/tutorial duration in minutes

  // Core content (all rotations)
  lectures: Lecture[];
  learningResources: LearningResource[];  // Tutorials, podcasts, cases, etc.
  curriculum: Curriculum;
  clinicalCompetencies: string[];         // Ward/clinical skills (renamed from wardCompetencies)
  effortAllocation: EffortAllocation;

  // Optional rotation-specific fields
  crossCuttingThemes?: string[];          // e.g., "Overarching Principles" for surgery
  assessmentFocus?: string[];             // Exam/clinical assessment priorities
  patientPopulations?: string[];          // e.g., "Adults", "Paediatrics", "Geriatrics"
  integrationNotes?: string;              // How this week connects to others
}
```

### Lecture Object

```typescript
interface Lecture {
  number: number;               // Sequence number
  title: string;                // Lecture/resource title
  tag: string;                  // Classification (see Valid Tags below)
  durationMinutes: number;      // Duration in minutes
  format?: string;              // Optional: "video", "audio", "reading", "case"
}
```

### Learning Resource Object (Generalized Tutorials/Podcasts)

```typescript
interface LearningResource {
  type: "tutorial" | "podcast" | "case" | "reading" | "simulation" | "workshop";
  title: string;
  durationMinutes?: number;   // Optional duration
  format?: string;            // e.g., "audio", "video", "pdf", "interactive"
  source?: string;            // e.g., "Unscrubbed", "Handbook", "Canvas"
}
```

### Curriculum Object

```typescript
interface Curriculum {
  // Optional: For rotations with acute/emergency focus
  acuteConditions?: string[];

  // Optional: For rotations with urgent but not emergency content
  urgentConditions?: string[];

  // Optional: Common/important conditions for the week
  commonConditions?: string[];

  // Main specialty topics (flexible for any rotation)
  specialtyTopics: SpecialtyTopic[];

  // Additional topic groups for complex weeks
  supplementaryTopics?: SpecialtyTopic[];
}

interface SpecialtyTopic {
  category: string;             // Category name (e.g., "Cardiology", "Neurosurgery")
  topics: string[];             // Topics in this category
  priority?: "high" | "medium" | "low";  // Optional priority indicator
}
```

### Effort Allocation Object

```typescript
interface EffortAllocation {
  examWeightPercent?: number;   // Optional: Exam weight (if applicable)
  examWeightLabel?: string;     // Human-readable exam weight
  recommendedEffortPercent: number;  // Recommended study effort
  priorityLevel?: "critical" | "high" | "medium" | "low";
  note: string;                  // Guidance note
}
```

---

## Rotation-Specific Adaptations

### Surgery Rotation

| Generic Field | Surgery-Specific Usage |
|--------------|----------------------|
| `crossCuttingThemes` | "Overarching Principles of Surgery" |
| `acuteConditions` | ⚡ Acute surgical conditions |
| `learningResources[].type` | "tutorial", "podcast" |
| `section` | "surgery" |

### Medicine Rotation

| Generic Field | Medicine-Specific Usage |
|--------------|----------------------|
| `crossCuttingThemes` | "Core Medical Principles", "Diagnostic Frameworks" |
| `acuteConditions` | ⚡ Medical emergencies |
| `urgentConditions` | Urgent presentations requiring same-day review |
| `commonConditions` | Common ward presentations |
| `patientPopulations` | ["Adults", "Geriatrics"] |
| `learningResources[].type` | "case", "reading", "tutorial" |
| `section` | "medicine" |

### GP Rotation

| Generic Field | GP-Specific Usage |
|--------------|------------------|
| `crossCuttingThemes` | "Primary Care Principles", "Holistic Care" |
| `commonConditions` | Common presentations in general practice |
| `patientPopulations` | ["All ages", "Paediatrics", "Women's health", "Mental health"] |
| `learningResources[].type` | "case", "workshop", "simulation" |
| `section` | "gp" |

---

## Markdown Schema

### Week Header

```markdown
# Week {number}: {title}

- **ID**: {id}
- **Rotation**: {rotation}
- **Schema Version**: {schemaVersion}
- **Exported**: {exportDate}
```

### Lectures Section

```markdown
## Lectures

| # | Title | Tag | Duration |
|---|-------|-----|----------|
| {number} | {title} | {tag} | {durationMinutes} min |
```

### Learning Resources Section

```markdown
## Learning Resources

**Tutorials:**
- {tutorial title}

**Podcasts:**
- {podcast title}

**Cases:**
- {case title}
```

### Cross-Cutting Themes Section (Optional)

```markdown
## Cross-Cutting Themes

- {theme}
- {theme}
```

### Curriculum Section

```markdown
## Curriculum

### ⚡ Acute Conditions
- {condition}

### Common Conditions
- {condition}

### {Category Name}
- {topic}

### Clinical Competencies
- {competency}
```

### Effort Allocation Section

```markdown
## Effort Allocation

- **Priority**: {priorityLevel}
- **Recommended Effort**: {recommendedEffortPercent}%

### Guidance
{note}
```

---

## Field Specifications

### Valid Section Values

- `surgery` - Surgery rotation
- `medicine` - Internal Medicine rotation
- `gp` - General Practice rotation
- `psychiatry` - Psychiatry rotation
- `paediatrics` - Paediatrics rotation
- `obgyn` - Obstetrics & Gynaecology rotation
- `emergency` - Emergency Medicine rotation
- `anaesthesia` - Anaesthesia rotation
- `radiology` - Radiology rotation
- `pathology` - Pathology rotation
- Custom values allowed (lowercase, no spaces)

### Valid Tag Values for Lectures/Resources

#### Universal Tags (All Rotations)
- `CORE` - Core curriculum material
- `FOUNDATION` - Foundational concepts
- `RECOMMENDED` - Recommended but not core
- `SUPPLEMENTARY` - Optional supplementary material
- `REVISION` - Revision/review material
- `HANDBOOK` - Maps to handbook content
- `CLINICAL` - Clinical skills focus
- `THEORY` - Theoretical/academic focus

#### Surgery-Specific Tags
- `RELATED` - Related/ancillary surgical content
- `ACUTE` - Acute surgical conditions
- `ELECTIVE` - Elective surgery content
- `PERIOPERATIVE` - Perioperative care

#### Medicine-Specific Tags
- `EMERGENCY` - Emergency medicine content
- `WARD` - Ward-based management
- `CLINICAL-REASONING` - Diagnostic reasoning
- `THERAPEUTICS` - Treatment/management focus

#### GP-Specific Tags
- `CHRONIC` - Chronic disease management
- `PREVENTIVE` - Preventive care/screening
- `COMMUNITY` - Community health focus
- `HOLISTIC` - Holistic/biopsychosocial care

### Week ID Format

- **Surgery**: `wk{n}` where n is 1-7 (e.g., `wk1`, `wk2`)
- **Medicine**: `m{n}` or `med{n}` where n is 1-12 (e.g., `m1`, `m2`)
- **GP**: `gp{n}` where n is 1-6 (e.g., `gp1`, `gp2`)
- **Custom**: Any alphanumeric, lowercase, using underscores or hyphens (e.g., `psych_wk1`, `emergency-1`)

### Date/Time Format

- All dates use ISO 8601 format: `YYYY-MM-DDTHH:mm:ssZ`
- Example: `2026-03-29T14:30:00Z`

---

## Example: Surgery Rotation (JSON)

```json
{
  "schemaVersion": "1.1.0",
  "exportDate": "2026-03-29T10:00:00Z",
  "section": "surgery",
  "week": {
    "id": "wk1",
    "number": 1,
    "title": "Trauma & Neurosurgery",
    "rotation": "Neurosurgery rotation",
    "handbookWeek": "Handbook Week 7",
    "totalLectureMinutes": 47,
    "lectures": [
      {
        "number": 1,
        "title": "Brain Tumour",
        "tag": "CORE",
        "durationMinutes": 14,
        "format": "video"
      }
    ],
    "learningResources": [
      {
        "type": "tutorial",
        "title": "Tutorial: Surgical Emergencies (Wk 7)"
      },
      {
        "type": "podcast",
        "title": "Podcast: Neurosurgery emergencies",
        "source": "Unscrubbed"
      }
    ],
    "crossCuttingThemes": [
      "Surgical emergencies — recognition and immediate management",
      "Theatre etiquette and safety"
    ],
    "curriculum": {
      "acuteConditions": [
        "Subarachnoid haemorrhage",
        "Traumatic brain injury"
      ],
      "specialtyTopics": [
        {
          "category": "Neurosurgery",
          "topics": ["Cerebral aneurysms", "Brain tumours"],
          "priority": "high"
        }
      ]
    },
    "clinicalCompetencies": [
      "Assessment of a trauma patient: primary, secondary and tertiary surveys"
    ],
    "effortAllocation": {
      "examWeightPercent": 5,
      "examWeightLabel": "5% (Neuro/Ophthalmology)",
      "recommendedEffortPercent": 5,
      "priorityLevel": "medium",
      "note": "Brain Tumour is the only lecture..."
    }
  }
}
```

## Example: Medicine Rotation (JSON)

```json
{
  "schemaVersion": "1.1.0",
  "exportDate": "2026-03-29T10:00:00Z",
  "section": "medicine",
  "week": {
    "id": "m1",
    "number": 1,
    "title": "Cardiology — Heart Failure & Arrhythmias",
    "rotation": "Cardiology rotation",
    "handbookWeek": "Week 1",
    "totalLectureMinutes": 75,
    "lectures": [
      {
        "number": 1,
        "title": "Heart Failure — Diagnosis & Management",
        "tag": "CORE",
        "durationMinutes": 25,
        "format": "video"
      },
      {
        "number": 2,
        "title": "Atrial Fibrillation",
        "tag": "CORE",
        "durationMinutes": 20,
        "format": "video"
      }
    ],
    "learningResources": [
      {
        "type": "case",
        "title": "Case: Acute Pulmonary Oedema",
        "durationMinutes": 30,
        "format": "interactive"
      },
      {
        "type": "reading",
        "title": "ESC Heart Failure Guidelines Summary",
        "source": "Handbook"
      }
    ],
    "crossCuttingThemes": [
      "Diagnostic reasoning in breathlessness",
      "Interpreting cardiac investigations"
    ],
    "patientPopulations": ["Adults", "Geriatrics"],
    "curriculum": {
      "acuteConditions": [
        "Acute pulmonary oedema",
        "Cardiogenic shock",
        "Acute coronary syndrome"
      ],
      "commonConditions": [
        "Chronic heart failure",
        "Atrial fibrillation",
        "Hypertension"
      ],
      "specialtyTopics": [
        {
          "category": "Heart Failure",
          "topics": [
            "HFrEF vs HFpEF",
            "NYHA classification",
            "GDMT (Guideline-Directed Medical Therapy)"
          ],
          "priority": "high"
        },
        {
          "category": "Arrhythmias",
          "topics": [
            "AF management — rate vs rhythm control",
            "Anticoagulation in AF (CHA2DS2-VASc)"
          ],
          "priority": "high"
        }
      ]
    },
    "clinicalCompetencies": [
      "Interpret ECG — recognise AF, heart blocks, ischaemia",
      "Interpret echocardiogram report — EF, valve pathology, diastolic function",
      "Clinical assessment of heart failure — JVP, oedema, lung crepitations",
      "Manage acute pulmonary oedema — LMNOP, diuretics, nitrates"
    ],
    "effortAllocation": {
      "examWeightPercent": 15,
      "examWeightLabel": "15% (Cardiology)",
      "recommendedEffortPercent": 18,
      "priorityLevel": "high",
      "note": "Heart failure and AF are high-yield for both written and OSCE. Focus on ECG interpretation and GDMT. The interactive case is excellent preparation for acute scenarios."
    }
  }
}
```

## Example: GP Rotation (JSON)

```json
{
  "schemaVersion": "1.1.0",
  "exportDate": "2026-03-29T10:00:00Z",
  "section": "gp",
  "week": {
    "id": "gp1",
    "number": 1,
    "title": "Common Presentations — Respiratory & ENT",
    "rotation": "General Practice rotation",
    "totalLectureMinutes": 45,
    "lectures": [
      {
        "number": 1,
        "title": "Cough in Primary Care",
        "tag": "CORE",
        "durationMinutes": 20,
        "format": "video"
      }
    ],
    "learningResources": [
      {
        "type": "case",
        "title": "Simulated Consultation: Persistent Cough",
        "durationMinutes": 15,
        "format": "interactive"
      },
      {
        "type": "workshop",
        "title": "Respiratory Examination Skills"
      }
    ],
    "crossCuttingThemes": [
      "Whole-person care in chronic respiratory disease",
      "Appropriate investigation and referral in primary care"
    ],
    "patientPopulations": ["All ages", "Paediatrics", "Smokers"],
    "curriculum": {
      "commonConditions": [
        "Acute viral respiratory infection",
        "Asthma",
        "COPD",
        "Allergic rhinitis",
        "Acute otitis media"
      ],
      "specialtyTopics": [
        {
          "category": "Respiratory",
          "topics": [
            "Cough — acute vs chronic, red flags",
            "Asthma review and inhaler technique",
            "COPD diagnosis and management",
            "Smoking cessation"
          ],
          "priority": "high"
        },
        {
          "category": "ENT",
          "topics": [
            "Sore throat — centor criteria, antibiotic stewardship",
            "Acute otitis media in children"
          ],
          "priority": "medium"
        }
      ]
    },
    "clinicalCompetencies": [
      "Take focused respiratory history including smoking history and occupational exposures",
      "Perform respiratory examination and interpret findings",
      "Interpret spirometry — obstructive vs restrictive patterns",
      "Manage asthma exacerbation in GP setting",
      "Counsel patient on smoking cessation"
    ],
    "effortAllocation": {
      "recommendedEffortPercent": 12,
      "priorityLevel": "medium",
      "note": "Respiratory is one of the most common presenting complaints in GP. Focus on differentiating serious from benign, and on patient education (inhaler technique, action plans). COPD and asthma management are examinable."
    }
  }
}
```

---

## Usage Notes

1. **Copy Functionality**: HTML pages can implement copy buttons that generate JSON/Markdown conforming to this schema for each week.

2. **Extensibility**: When adding new rotations, use the generic field structure. Add rotation-specific data in `crossCuttingThemes`, `specialtyTopics`, or custom fields within `curriculum`.

3. **Optional Fields**: Fields marked with `?` are optional. Minimal valid week requires:
   - `id`, `number`, `title`, `rotation`
   - `totalLectureMinutes`
   - `lectures` (can be empty array)
   - `learningResources` (can be empty array)
   - `curriculum.specialtyTopics` (at least one category recommended)
   - `clinicalCompetencies` (can be empty array)
   - `effortAllocation.recommendedEffortPercent` and `effortAllocation.note`

4. **Validation**: JSON output should validate against the TypeScript interfaces defined above. Use tools like [JSON Schema Validator](https://www.jsonschemavalidator.net/) if needed.

5. **Character Encoding**: All text is UTF-8 encoded. Special characters (emojis, medical symbols) are preserved in both formats.

6. **Backward Compatibility**: Schema v1.1.0 is backward compatible with v1.0.0. Surgery rotation data using `overarchingPrinciples` can map to `crossCuttingThemes`.

---

## Changelog

### v1.1.0 (2026-03-29)
- **Generalized schema** for all medical rotations (not just surgery)
- Added `section` field with multiple rotation options
- Renamed `overarchingPrinciples` → `crossCuttingThemes` (more generic)
- Renamed `wardCompetencies` → `clinicalCompetencies` (broader applicability)
- Renamed `tutorialsAndPodcasts` → `learningResources` (supports cases, readings, simulations)
- Added optional fields: `patientPopulations`, `urgentConditions`, `commonConditions`, `assessmentFocus`, `integrationNotes`
- Added `priority` field to specialty topics
- Added `format` field to lectures and resources
- Added `source` field to resources
- Added `priorityLevel` to effort allocation
- Added comprehensive examples for Medicine and GP rotations
- Expanded tag values for different rotation types

### v1.0.0 (2026-03-29)
- Initial schema definition
- Surgery-specific focus
- JSON and Markdown export formats
- Complete field specifications and examples
