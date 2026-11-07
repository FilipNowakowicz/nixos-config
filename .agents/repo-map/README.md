# Repo Map

An on-demand repository discovery helper for agents. It is not persistent
memory and it is not loaded into normal context. Scripts generate compact
metadata from tracked files when queried, then return only the highest-scoring
file paths.

Use it before broad exploration when the target file is not already obvious:

```sh
bash .agents/repo-map/scripts/query.sh merge-gate lint
bash .agents/repo-map/scripts/query.sh homeserver-gcp sops bootstrap
bash .agents/repo-map/scripts/query.sh shell theme switch
```

The query output is a routing hint. Open only the likely files it returns, then
verify against the real source.
