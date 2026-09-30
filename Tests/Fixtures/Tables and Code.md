# Tables and code

A reading paragraph sits between each case so the text column and the wide blocks can be compared. Tables, code blocks and diagrams may grow past this column into the margin, while prose keeps its measure.

## Small table

| Key | Value |
| --- | --- |
| Status | Active |
| Owner | Hatim |

## Aligned columns

| Item | Qty | Unit price | Total |
| :--- | :---: | ---: | ---: |
| Sandbox minutes | 1,240 | 0.004 | 4.96 |
| Model calls | 38 | 0.21 | 7.98 |
| Storage | 1 | 12.00 | 12.00 |

## Many columns and long text

| Run | Prompt | Route | Result | What the events show | Input tokens | Output tokens | Cost | Notes |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `7ac4d2bc` | go on (first build) | Auto chose Fast; usage on Balanced and Fast | failed on the palette check in five files | thirty minutes, three implementer subagents with long prescriptive briefs, consulted two skills, curled its own chat endpoint | 20,200,000 | 131,000 | 8.46 | no repair attempt visible |
| `448e3ae0` | build an agent companion | Thorough and Balanced | failed: source assurance | no subagents, consulted both skills, typecheck and Vite build passed | 6,600,000 | 48,000 | 5.69 | the companion works |

## Unbreakable content in cells

| Field | Example |
| --- | --- |
| Long identifier | `resolveAiModeWithDepthSourceForPromptExecutionDepthAndChangeRequestKind` |
| Long link | https://github.com/openai/codex-plugin-cc/blob/main/docs/reference/configuration-and-environment-variables.md |
| Normal sentence | This cell holds an ordinary sentence that should wrap at spaces and never break inside a word. |

## Arabic table

| البند | الحالة | الملاحظات |
| --- | --- | --- |
| تسجيل الدخول | مكتمل | يعمل مع حساب الشركة |
| التقارير | قيد العمل | ننتظر بيانات المالية لشهر أغسطس |

## Code

Short block:

```ts
const total = items.reduce((sum, item) => sum + item.price, 0);
```

Long lines:

```bash
codex exec --json --model gpt-5.6-sol --sandbox workspace-write -c sandbox_workspace_write.network_access=true --output-schema judge-schema.json --skip-git-repo-check < checklist.md > judge.jsonl
```

## Table inside a list

1. First step, with a table:

   | Step | Owner |
   | --- | --- |
   | Review | Hatim |

2. Second step.

A closing paragraph after every case.
