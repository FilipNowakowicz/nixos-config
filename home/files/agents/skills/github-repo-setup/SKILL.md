---
name: github-repo-setup
description: Use when setting up or auditing a GitHub repository for a solo/portfolio project — git init and first push if it isn't on GitHub yet, a short README if one doesn't exist, description and topics, branch protection (PR required, admin-bypassable), and hiding unused tabs (Wiki/Projects/Discussions) while keeping Issues on.
---

# GitHub Repo Setup

Bring a local project to a fully-configured GitHub repo in one pass: get it
onto GitHub if it isn't there yet, then apply the description/topics/tabs/
branch-protection baseline this user wants on every solo repo. Designed for
early-stage personal/portfolio projects, not for team repos that may already
have their own conventions — if the repo already has non-default settings
(existing branch protection, a CONTRIBUTING.md with a different workflow,
etc.), ask before overwriting them rather than assuming this baseline applies.

## Workflow

### 1. Establish local git state

- `git status` (this also confirms whether the directory is a git repo).
  If it isn't, `git init`.
- `git remote -v`. If there's no `origin`:
  - If the user gave a GitHub URL, `git remote add origin <url>`.
  - If not, ask whether to create a new repo (`gh repo create <name>
--private|--public --source=. --remote=origin`) or whether one already
    exists remotely to link to — don't guess a repo name or visibility.

### 2. Make sure there's something to commit

- If there's no README, write a short one from what's actually in the repo
  (existing docs, CLAUDE.md, pyproject/package metadata, code structure) —
  what the project is, its current status, how to use it if that's already
  true. Don't invent features or an install story that doesn't exist yet;
  say "early development" plainly if that's the state.
- Before staging, review `git status` output (and read any file that looks
  like it might hold secrets — `.env`, credentials, keys) rather than
  blindly `git add -A`.

### 3. First commit and push

- Stage explicitly, write a plain commit message (no Claude/Anthropic
  mention, no co-author trailer — this user's global CLAUDE.md rule applies
  here same as everywhere else), then `git push -u origin <default-branch>`.

### 4. Description and topics

- `gh repo edit --description "..."` — one line, what it does.
- `gh repo edit --add-topic ...` — infer 5-8 relevant topics from the
  project's domain/stack; apply them without asking unless genuinely
  unclear, but list them in the final report so the user can amend.
- Visibility: ask if it isn't already obvious from context which one the
  user wants (default suggestion for a brand-new repo with little content
  yet: private until there's something worth showing, public once it is).
  Don't flip an existing repo's visibility without asking — it has
  real consequences (stars/watchers, detached forks, Actions log
  visibility — `gh repo edit --visibility` surfaces the same warning).

### 5. Tabs

Standing preference, apply without asking:

```
gh repo edit --enable-wiki=false --enable-projects=false \
             --enable-discussions=false --enable-issues=true
```

Wiki/Projects/Discussions off, Issues stays on (bug/TODO tracking against a
roadmap is worth keeping even for a solo repo).

### 6. Cheap hygiene extras (apply by default)

- `gh repo edit --delete-branch-on-merge` — auto-clean merged PR branches.
- `gh repo edit --enable-secret-scanning --enable-secret-scanning-push-protection`
  (free on public repos; will simply fail on private repos without GHAS —
  fine to attempt and ignore that specific failure).
- Only narrow existing merge-method options (squash-only, etc.) if the repo
  is new enough that it has no PR history yet — don't silently change merge
  conventions on a repo that's already in active use.

### 7. Branch protection on the default branch

First check what's already there — `gh api
repos/{owner}/{repo}/branches/{branch}/protection` — and if it returns
something non-default, ask before replacing it. Otherwise apply the
baseline (PR required, one approval, admin-bypassable, no force-push/delete):

```
cat > /tmp/branch_protection.json <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
gh api repos/{owner}/{repo}/branches/{branch}/protection -X PUT \
  -H "Accept: application/vnd.github+json" --input /tmp/branch_protection.json
```

`enforce_admins: false` is what makes it admin-bypassable — PRs are required
for everyone else, but the repo owner can still push straight to the default
branch when they choose to.

### 8. Known limitation: sidebar widgets (Releases / Packages / Deployments)

There is **no supported API for this** — hiding these from the repo
homepage sidebar is a per-viewer toggle behind the gear icon next to
"About" on the repo's main page, saved through GitHub's internal,
session-cookie-authenticated `settings/update_meta` endpoint, not the
public REST/GraphQL API that `gh` uses. GitHub's own community reports also
note the Packages/Environments checkboxes don't reliably persist even when
toggled by hand. Don't attempt to script this and don't claim to have done
it — tell the user it's a one-time manual click if they still want it
hidden, and that Releases/Packages typically don't render at all on a repo
with zero releases/packages anyway, so it's often moot until the repo
actually has one.

## Guardrails

- Never `git add -A`/`git add .` blind — check `git status` first, and read
  anything that looks like it could hold a secret before staging it.
- Don't silently change visibility on an existing repo — ask.
- Don't overwrite existing branch protection, merge-method settings, or tab
  configuration that differs from this baseline without asking first —
  this skill is for bringing a repo _to_ the baseline, not for forcing it
  on a repo that already made different, deliberate choices.
- Don't fabricate a claim of having hidden the Releases/Packages/Deployments
  sidebar — it isn't scriptable; say so.
- Respect the user's global git-commit rule (no Claude/Anthropic mentions or
  co-author trailers) on the first commit same as any other.

## Output Expectations

Report back concisely: the repo URL, whether git init/first push happened,
description and topics applied, which tabs are on/off, which hygiene extras
were applied (and any that failed, e.g. secret scanning on a private repo),
a summary of the branch protection rule now in effect, and an explicit
reminder about the manual sidebar-widget step if the user cares about it.
