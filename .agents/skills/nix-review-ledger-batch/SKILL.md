---
name: nix-review-ledger-batch
description: Use for processing review findings or backlog items in small validated batches while keeping status artifacts accurate.
---

# Nix Review Ledger Batch

Use this workflow when working through review findings, audits, local backlog
items, or status ledgers in this repository.

## Workflow

1. Read the current source-of-truth file before editing.
2. Count or classify the current open items if progress state matters.
3. Pick a narrow batch with a clear validation path.
4. Implement only that batch.
5. Update the matching status/ledger/doc marker in the same batch when requested
   or when the file is the source of truth for the task.
6. Validate with the smallest relevant command first:
   - `bash scripts/validate.sh flake-eval`
   - `bash scripts/validate.sh light`
   - `bash scripts/validate.sh docs`
   - targeted host/package/profile checks as needed.

## Guardrails

- Do not prune or rewrite planning docs casually.
- If a finding looks stale or false-positive, verify against the repo before marking it done.
- Keep unrelated refactors out of the batch.
- Leave a clear stop point if remaining items need broader design or live deployment.

