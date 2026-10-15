---
type: assessment
updated: 2026-10-14
linen:
  eyebrow: Readiness · October
  lead: Where the requests service stands, box by box, with the evidence behind each state.
---
# Requests service: where it stands

The service takes a request from the form to an approver's queue. It cannot record a decision yet[^1], so nothing reaches billing. :note[The approval check]{#n-approve} reads the wrong role.

```tiles
size: stat
cols: 4
items:
  - {label: boxes on the map, value: "170"}
  - {label: work end to end, value: "76", word: Works}
  - {label: Broken, value: "10", word: Broken, note: n-broken}
  - {label: Missing, value: "14", word: Missing}
```

## By state

```bar
items:
  - {word: Works, count: 76}
  - {word: Partial, count: 52}
  - {word: Broken, count: 10}
  - {word: Missing, count: 14}
  - {word: Planned, count: 18}
```

Two of the 10 broken boxes share one cause[^2]. The approval check reads the wrong role.

## Facts

```tiles
size: fact
cols: 3
items:
  - {label: Owner, value: Requests team}
  - {label: State, value: Partial, word: Partial}
  - {label: Next review, value: 21 October}
```

## The path of a request

```steps
kind: steps
items: [Draft, Review, Approve, Publish]
current: 2
```

```steps
kind: level
value: 3
of: 6
label: threads of the path work today
```

```steps
kind: count
value: 12
of: 37
label: use cases work
```

```cards
cols: 3
items:
  - {eyebrow: Step 1, title: Intake, body: "Validates and stores a **request**.", tone: paper, word: Works}
  - {eyebrow: Step 2, title: Review, body: "Reads the reviewer's role.", tone: tint, word: Partial, note: n-review}
  - {eyebrow: Next, title: Approve, body: "The hub everything waits on.", tone: ink}
  - {number: 4, title: Billing, body: "Not written yet.", tone: dashed, word: Missing}
  - {title: Ask finance about the batch window, tone: sticky}
  - {eyebrow: Plan, title: Intake plan, body: "Three goals and what each needs.", link: "[[Linked Note]]"}
```

| Box {#t-head} | State | Verdict |
|---|---|---|
| Request form {#r-form} | :w[Works] | {good} |
| Approval flow {#r-approve} | :w[Broken] | refuses every decision [^1] {bad} |
| Batch backup check | :w[Partial] | read in code only |
| Partner ledger export | :w[Missing] | |
| Audit log | :w[Planned] | |

- An English item.
- بند عربي في قائمة إنجليزية.
- Another English item.

A word in prose reads as its pill: the night run is :w[Broken], and the quiet word :w[Works] reads as plain text.

[^1]: Approve and Return both answer 403. Source: `server/approvals.py:118`.
[^2]: Both read `role` from the reviewer's token instead of the approver's.
