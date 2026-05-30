# E2E test for the security profile (fail2ban functionality).
{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
in
(import "${nixpkgs}/nixos/lib/testing-python.nix" {
  inherit system pkgs;
}).runTest
  {
    name = "profile-security-fail2ban";

    nodes = {
      target =
        { lib, ... }:
        {
          imports = [ ../../modules/nixos/profiles/security.nix ];

          # Override SSH defaults — test needs a live sshd
          services.openssh = {
            enable = true;
            settings.PasswordAuthentication = lib.mkForce true;
          };

          # Low threshold so the test runs fast
          services.fail2ban = {
            maxretry = lib.mkForce 3;
          };

          users.users.testuser = {
            isNormalUser = true;
            hashedPassword = "$6$YG6XnXb5i.MSo68k$klF26cyun4jDf7qwSfUMouDehJigpDx0VkGG0SUfSkJna8BIQ13Z1QhMBcHtKEbXrcUJurW1yPs512R45Y27p0";
          };

          environment.systemPackages = [ pkgs.fail2ban ];
        };

      hardened = _: {
        imports = [ ../../modules/nixos/profiles/security.nix ];

        services.openssh.enable = true;
      };

      attacker = _: {
        environment.systemPackages = [ pkgs.sshpass ];
      };
    };

    testScript = ''
      start_all()
      target.wait_for_unit("fail2ban.service")
      target.wait_for_unit("sshd.service")
      hardened.wait_for_unit("sshd.service")

      expected_sysctls = {
          "kernel.unprivileged_bpf_disabled": "1",
          "kernel.kptr_restrict": "2",
          "kernel.dmesg_restrict": "1",
          "kernel.yama.ptrace_scope": "1",
          "net.core.bpf_jit_harden": "2",
          "kernel.kexec_load_disabled": "1",
          "net.ipv4.icmp_echo_ignore_broadcasts": "1",
          "net.ipv4.conf.all.accept_redirects": "0",
          "net.ipv4.conf.default.accept_redirects": "0",
          "net.ipv4.conf.all.send_redirects": "0",
          "net.ipv4.conf.default.send_redirects": "0",
          "net.ipv4.conf.all.accept_source_route": "0",
          "net.ipv4.conf.default.accept_source_route": "0",
      }
      for key, expected in expected_sysctls.items():
          hardened.succeed(f"test \"$(sysctl -n {key})\" = \"{expected}\"")

      sshd_config = hardened.succeed("sshd -T")
      assert "permitrootlogin no\n" in sshd_config
      assert "passwordauthentication no\n" in sshd_config
      assert "kbdinteractiveauthentication no\n" in sshd_config

      # 4 failed password attempts — one over maxretry=3
      for _ in range(4):
          attacker.fail(
              "sshpass -p wrongpassword ssh"
              " -o StrictHostKeyChecking=no"
              " -o ConnectTimeout=5"
              " testuser@target exit"
          )

      # fail2ban should have banned the attacker's IP (Currently banned: > 0)
      target.wait_until_succeeds(
          "fail2ban-client status sshd | grep -q 'Currently banned:.*[1-9]'",
          timeout=30,
      )

      # Verify the nftables ban rule was actually installed (not just internal counter)
      target.succeed("nft list ruleset | grep -qE '2001:db8:1::1|f2b'")

      # Verify the connection times out — blocked at the firewall, not just auth failure
      attacker.fail(
          "sshpass -p wrongpassword ssh"
          " -o StrictHostKeyChecking=no"
          " -o ConnectTimeout=3"
          " testuser@target exit"
      )
    '';
  }
