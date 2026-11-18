# Personal agent skills that apply in any repository (GitHub repo setup,
# release cleanup, ...). Each directory under home/files/agents/skills/ is
# linked into the user-level skill directory of both Claude Code and Codex,
# so the two agents share one versioned source.
#
# Only the individual skill directories are managed: ~/.claude/skills and
# ~/.codex/skills stay ordinary writable directories, because Claude Code
# syncs its own skills into ~/.claude/skills/synced and Codex keeps its
# bundled skills in ~/.codex/skills/.system.
#
# Project-specific skills stay in their own repository (.claude/skills or
# .agents/skills there), next to the code they drive.
{ lib, ... }:
let
  skillsDir = ../files/agents/skills;
  skillNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir skillsDir)
  );
  agentSkillDirs = [
    ".claude/skills"
    ".codex/skills"
  ];
in
{
  home.file = lib.listToAttrs (
    lib.concatMap (
      dir: map (name: lib.nameValuePair "${dir}/${name}" { source = skillsDir + "/${name}"; }) skillNames
    ) agentSkillDirs
  );
}
