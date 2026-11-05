# Application and window navigation preview

The launcher has explicit `--apps` and `--windows` modes. The existing invocation
continues to open command mode; this preview does not reassign shortcuts.

Application search uses installed Desktop Entry metadata, including display names,
executables and keywords. Matching is case/accent insensitive and excludes hidden
entries. Arrow keys select a result; Enter or a click opens it through its desktop
launch information. Errors retain the query. Prefix `>` to run a literal command.

Window search shows titles, applications and workspaces with the previous window
first. Selection follows stable window identity, including while windows arrive or
close. Long lists scroll to keyboard selection; list updates retain native row
focus or move to a nearby result if the selected window disappears.

Activation releases the exclusive chooser layer before requesting focus. It looks
up the live stable identity in Lua and reads back focus before reporting success.
A closed target returns a recoverable error. It never falls back to a cached window
address or an implicit compositor instance, and uncertain dispatch is not repeated
automatically. Cross-workspace activation is covered by private runtime testing.

## Validation

```sh
nix build .#checks.x86_64-linux.control-center-capabilities --no-link
bash scripts/validate.sh flake-eval
bash scripts/validate.sh host main-ci
```

The focused check covers ranking, hidden entries, literal command behaviour,
stable-ID validation, explicit compositor targeting, overlay release and focus
readback. Local private desktop trials additionally covered keyboard/pointer app
selection, launch failures, the installed catalogue without personal app launches,
and a real controlled Desktop Entry launch with a quoted argument and mapped-window
readback. Eleven launcher cases passed, including native text-editing regressions.

A separate private Hyprland 0.57 compositor exercised real keyboard/pointer window
focus, workspace activation, stale-window recovery, eleven-window scrolling, and
focus retention/recovery during live list changes. These passed with GTK and
compositor animations enabled and disabled. The temporary harness and evidence are
retained in the persistent development worktree rather than shipped as runtime
configuration.

Physical GPU frame pacing, multi-monitor usability and everyday acceptance remain
unverified. This is an explicit chooser, not modifier-release Alt-Tab. Minimize,
restore, dock, overview and notification history remain separate follow-ups. Keep
the working generation; merge and production activation require a later review.
