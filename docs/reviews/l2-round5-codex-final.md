### Finding status

- **R3-PAGE-REALMS — Not resolved.** PAGE-10 covers instance properties only on objects reachable without construction and only two levels deep; constructed/deeper instances remain outside the inventory, while the test mutates only `navigator` ([PAGE-10](/Users/hatim/Developer/Satr/docs/PRD-2.md:147), [test](/Users/hatim/Developer/Satr/docs/PRD-2.md:377)).
- **R4-TRUST-PARITY — Not resolved.** PAGE-7 requires effective policy, provenance, and trust revision, but the normative manifest/protocol schemas omit those fields ([PAGE-7](/Users/hatim/Developer/Satr/docs/PRD-2.md:144), [SYNC-4](/Users/hatim/Developer/Satr/docs/PRD-2.md:200), [protocol](/Users/hatim/Developer/Satr/docs/PRD-2.md:315)).
- **R4-SYNC-ROOTS — Not resolved.** SYNC-3 creates single-file pins with their own grants, but SYNC-2 and §9.3 still restrict the helper to pinned-folder grants and serving inside a pin’s folder ([SYNC-2/3](/Users/hatim/Developer/Satr/docs/PRD-2.md:198), [§9.3](/Users/hatim/Developer/Satr/docs/PRD-2.md:316)).
- **R4-BG-PINSET — Not resolved.** SYNC-4 declares a Mac-authored pin-set generation, but `hello` carries only manifest IDs/sequences and the protocol defines no pin-set or pin-removal frame ([SYNC-4](/Users/hatim/Developer/Satr/docs/PRD-2.md:200), [protocol](/Users/hatim/Developer/Satr/docs/PRD-2.md:315)).
- **R4-PHONE-FIRST-PAINT — Resolved.** Canvas first paint explicitly opens the first section at reading zoom, and List first paint has a separate 500-node target ([§4](/Users/hatim/Developer/Satr/docs/PRD-2.md:70)).
- **R4-BRD-MALFORMED — Resolved.** Every other malformed entry is skipped with its JSON path, and wrong-shape fixtures verify that the remainder renders ([BRD-1](/Users/hatim/Developer/Satr/docs/PRD-2.md:106), [test](/Users/hatim/Developer/Satr/docs/PRD-2.md:371)).

### Changed-row majors

- **Major — PAGE-10 inventory remains incomplete:** newly introduced instance-owned capabilities on constructed or deeper objects can evade both enumeration and the sole instance-property mutation test.
- **Major — Single-file pin authority contradicts helper authority:** implementation must either receive file-scoped grants and define a singleton-root descriptor walk, or it cannot serve these pins without widening access.
- **Major — Sync wire contract is incomplete:** the protocol cannot unambiguously transport trust policy/revisions or reconcile pin additions and removals, despite the requirements and tests demanding both.

Not approved — three security/sync contract majors remain: incomplete realm inventory, contradictory singleton-root authority, and missing trust/pin-set wire semantics.
