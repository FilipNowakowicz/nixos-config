#!/usr/bin/env bash
set -euo pipefail

repo_root="$(
  git rev-parse --show-toplevel 2>/dev/null || pwd
)"
cd "$repo_root"

event_name="${GITHUB_EVENT_NAME:-}"
base_sha="${BASE_SHA:-}"

ci_core_change='^(\.github/workflows/nix\.yml|\.github/actions/setup-nix/|scripts/(ci-plan|validate|check-doc-links|doctor)\.sh)'
flake_or_lib_change='^(flake\.nix|flake\.lock|lib/)'
closure_script_change='^scripts/closure-diff\.sh'
tests_change='^tests/nixos/'
docs_change='^(README\.md|docs/|.*\.md$|.*/CLAUDE\.md$|AGENTS\.md$)'
package_change='^packages/'
main_change='^hosts/main/'
homeserver_change='^hosts/homeserver-gcp/'
installer_change='^hosts/installer/'
module_all_hosts='^modules/nixos/(default\.nix|services/|profiles/(base|backup|security|sops-base|user)\.nix)'
module_desktop_hosts='^modules/nixos/(profiles/(desktop|observability-client)\.nix|hardware/nvidia-prime\.nix)'
module_server_hosts='^modules/nixos/profiles/observability/'
module_machine_hosts='^modules/nixos/profiles/(impermanence-base|machine-common)\.nix'
module_microvm_guest='^modules/nixos/profiles/microvm-guest\.nix'
home_all_hosts='^home/(profiles/base\.nix|users/user/common\.nix)'
home_desktop_hosts='^home/(neovim/|profiles/(desktop|workstation)\.nix|profiles/workflow-packs/|users/user/home\.nix|theme/|files/(nvim/|firefox|hypr|kitty|waybar|scripts/(theme-switch|waybar-weather|clipboard-pick)\.sh))'
home_server_hosts='^home/users/user/server\.nix'
home_wsl='^home/users/user/wsl\.nix'

docs_only=false
run_eval=false
run_lint=false
run_light=false
run_packages=false
main_ci=false
installer_build=false
profile_tests=false
homeserver_gcp_smoke=false
closure_main=false

select_all_hosts() {
  main_ci=true
  installer_build=true
  closure_main=true
}

select_all_tests() {
  profile_tests=true
  homeserver_gcp_smoke=true
}

select_desktop_hosts() {
  main_ci=true
  closure_main=true
}

changed_files="${CI_CHANGED_FILES:-}"
if [[ $event_name == "pull_request" ]]; then
  docs_only=true
  if [[ -z $changed_files ]]; then
    if [[ -z $base_sha ]] || ! git cat-file -e "$base_sha^{commit}" 2>/dev/null; then
      base_sha="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
    fi
    changed_files="$(git diff --name-only "$base_sha" HEAD)"
  fi
else
  docs_only=false
  run_eval=true
  run_lint=true
  run_light=true
  run_packages=true
  select_all_hosts
  select_all_tests
fi

if [[ -n $changed_files ]]; then
  unknown_module_changed=false
  unknown_home_changed=false

  while IFS= read -r path; do
    [[ -z $path ]] && continue

    if ! grep -qE "${docs_change}" <<<"$path"; then
      docs_only=false
      run_eval=true
      run_lint=true
      run_light=true
    fi

    if
      [[ $path =~ ^modules/nixos/ ]] &&
        ! grep -qE "${module_all_hosts}|${module_desktop_hosts}|${module_server_hosts}|${module_machine_hosts}|${module_microvm_guest}" <<<"$path"
    then
      unknown_module_changed=true
    fi

    if
      [[ $path =~ ^home/ ]] &&
        ! grep -qE "${home_all_hosts}|${home_desktop_hosts}|${home_server_hosts}|${home_wsl}" <<<"$path"
    then
      unknown_home_changed=true
    fi
  done <<<"$changed_files"

  if grep -qE "${ci_core_change}|${flake_or_lib_change}" <<<"$changed_files"; then
    run_packages=true
    select_all_hosts
    select_all_tests
  fi

  if grep -qE "${package_change}" <<<"$changed_files"; then
    run_packages=true
  fi

  if grep -qE "${tests_change}" <<<"$changed_files"; then
    select_all_tests
  fi

  if grep -qE "${closure_script_change}" <<<"$changed_files"; then
    closure_main=true
  fi

  if grep -qE "${main_change}" <<<"$changed_files"; then
    main_ci=true
    closure_main=true
  fi

  if grep -qE "${homeserver_change}" <<<"$changed_files"; then
    homeserver_gcp_smoke=true
  fi

  if grep -qE "${installer_change}" <<<"$changed_files"; then
    installer_build=true
  fi

  if grep -qE "${module_all_hosts}" <<<"$changed_files"; then
    select_all_hosts
    select_all_tests
  fi

  if grep -qE "${module_desktop_hosts}" <<<"$changed_files"; then
    select_desktop_hosts
    profile_tests=true
  fi

  if grep -qE "${module_server_hosts}" <<<"$changed_files"; then
    profile_tests=true
    homeserver_gcp_smoke=true
  fi

  if grep -qE "${module_machine_hosts}" <<<"$changed_files"; then
    select_all_hosts
  fi

  if [[ $unknown_module_changed == "true" ]]; then
    run_packages=true
    select_all_hosts
    select_all_tests
  fi

  if grep -qE "${home_all_hosts}" <<<"$changed_files"; then
    select_all_hosts
  fi

  if grep -qE "${home_desktop_hosts}" <<<"$changed_files"; then
    select_desktop_hosts
  fi

  if [[ $unknown_home_changed == "true" ]]; then
    run_packages=true
    select_all_hosts
  fi
fi

emit_bool() {
  local name=$1
  local value=$2
  echo "$name=$value" >>"$GITHUB_OUTPUT"
}

if [[ $docs_only == "true" ]]; then
  run_eval=false
  run_lint=true
  run_light=false
  run_packages=false
fi

hosts_matrix='{"include":['
sep=""
if [[ $main_ci == "true" ]]; then
  hosts_matrix+="${sep}"'{"name":"main-ci"}'
  sep=","
fi
if [[ $installer_build == "true" ]]; then
  hosts_matrix+="${sep}"'{"name":"installer"}'
  sep=","
fi
hosts_matrix+=']}'

tests_matrix='{"include":['
sep=""
if [[ $homeserver_gcp_smoke == "true" ]]; then
  tests_matrix+="${sep}"'{"name":"homeserver-gcp-smoke","command":"smoke-homeserver-gcp","target":""}'
  sep=","
fi
if [[ $profile_tests == "true" ]]; then
  for profile in profile-security profile-observability profile-hardening; do
    tests_matrix+="${sep}"'{"name":"'"$profile"'","command":"profile-test","target":"'"$profile"'"}'
    sep=","
  done
fi
tests_matrix+=']}'

if [[ $main_ci == "true" || $installer_build == "true" ]]; then
  emit_bool hosts true
else
  emit_bool hosts false
fi

if [[ $homeserver_gcp_smoke == "true" || $profile_tests == "true" ]]; then
  emit_bool tests true
else
  emit_bool tests false
fi

if [[ $closure_main == "true" ]]; then
  emit_bool closure true
else
  emit_bool closure false
fi

emit_bool docs_only "$docs_only"
emit_bool run_eval "$run_eval"
emit_bool run_lint "$run_lint"
emit_bool run_light "$run_light"
emit_bool run_packages "$run_packages"
emit_bool closure_main "$closure_main"

{
  echo "hosts_matrix<<EOF"
  echo "$hosts_matrix"
  echo "EOF"
  echo "tests_matrix<<EOF"
  echo "$tests_matrix"
  echo "EOF"
} >>"$GITHUB_OUTPUT"

echo "Selected hosts: $hosts_matrix"
echo "Selected tests: $tests_matrix"
echo "Job selectors: docs_only=$docs_only eval=$run_eval lint=$run_lint light=$run_light packages=$run_packages"
echo "Closure selectors: main=$closure_main"
