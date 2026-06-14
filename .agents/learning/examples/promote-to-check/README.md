# Promote To Check Example

This fixture shows the intended off-ramp for a promoted learning that should
become an executable assertion:

```bash
bash .agents/learning/scripts/scaffold-promotion-check.sh \
  --candidate .agents/learning/examples/promote-to-check/example-promoted-candidate.yml \
  --check-name example-promoted-check \
  --validate-target docs \
  --output-dir /tmp/example-review-branch
```

The generated `.agents/learning/promotions/example-promoted-check.sh` is
intentionally failing and is wired into `scripts/validate.sh docs`. Replace the
TODO body with the real assertion before opening the promotion PR.
