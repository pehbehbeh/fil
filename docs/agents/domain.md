# Domain docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.

## File structure

```text
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-all-or-nothing-writes.md
│   └── NNNN-slug.md
└── lib/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the
term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary avoids.

If the concept you need isn't in the glossary yet, either you're inventing language the project doesn't use
(reconsider), or the glossary has a gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, say so instead of overriding it without a word:

> _Contradicts ADR-NNNN (its title), but should be reopened because..._
