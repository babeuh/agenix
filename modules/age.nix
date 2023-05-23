{
  config,
  options,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.age;

  isDarwin = lib.attrsets.hasAttrByPath ["environment" "darwinConfig"] options;

  ageBin = config.age.ageBin;

  users = config.users.users;

  mountCommand =
    if isDarwin
    then ''
      if ! diskutil info "${cfg.secretsMountPoint}" &> /dev/null; then
          num_sectors=1048576
          dev=$(hdiutil attach -nomount ram://"$num_sectors" | sed 's/[[:space:]]*$//')
          newfs_hfs -v agenix "$dev"
          mount -t hfs -o nobrowse,nodev,nosuid,-m=0751 "$dev" "${cfg.secretsMountPoint}"
      fi
    ''
    else ''
      grep -q "${cfg.secretsMountPoint} ramfs" /proc/mounts ||
        mount -t ramfs none "${cfg.secretsMountPoint}" -o nodev,nosuid,mode=0751
    '';
  newGeneration = ''
    _agenix_generation="$(basename "$(readlink ${cfg.secretsDir})" || echo 0)"
    (( ++_agenix_generation ))
    echo "[agenix] creating new generation in ${cfg.secretsMountPoint}/$_agenix_generation"
    mkdir -p "${cfg.secretsMountPoint}"
    chmod 0751 "${cfg.secretsMountPoint}"
    ${mountCommand}
    mkdir -p "${cfg.secretsMountPoint}/$_agenix_generation"
    chmod 0751 "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  chownGroup =
    if isDarwin
    then "admin"
    else "keys";
  # chown the secrets mountpoint and the current generation to the keys group
  # instead of leaving it root:root.
  chownMountPoint = ''
    chown :${chownGroup} "${cfg.secretsMountPoint}" "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  setTruePath = secretType: ''
    ${
      if secretType.symlink
      then ''
        _truePath="${cfg.secretsMountPoint}/$_agenix_generation/${secretType.name}"
      ''
      else ''
        _truePath="${secretType.path}"
      ''
    }
  '';

  yubikeyPinPrompt =
    if pkgs.stdenv.isLinux
    then ''AGE_YUBIKEY_PIN=$(${pkgs.systemd}/bin/systemd-ask-password --echo=masked "Enter your Yubikey PIN for $(${cfg.yubikey.plugin}/bin/age-plugin-yubikey -V):")''
    else "";

  installSecret = secretType: ''
    ${setTruePath secretType}
    echo "decrypting '${secretType.file}' to '$_truePath'..."
    TMP_FILE="$_truePath.tmp"

    IDENTITIES=()
    ${
      if cfg.yubikey.enable
      then ''
        mkdir -p /tmp/agenix
        for identity in ${toString (lib.attrsets.catAttrs "identity" (lib.attrsets.attrValues cfg.yubikey.keys))}; do
          (${cfg.yubikey.plugin}/bin/age-plugin-yubikey -i | ${pkgs.gnugrep}/bin/grep "$identity") || continue
          echo "$identity" > /tmp/agenix/$identity
          IDENTITIES+=(-i)
          IDENTITIES+=("/tmp/agenix/$identity")
        done
      ''
      else ''
        for identity in ${toString (cfg.identityPaths)}; do
          test -r "$identity" || continue
          IDENTITIES+=(-i)
          IDENTITIES+=("$identity")
        done
      ''
    }

    test "''${#IDENTITIES[@]}" -eq 0 && echo "[agenix] WARNING: no readable identities found!"

    mkdir -p "$(dirname "$_truePath")"
    [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && mkdir -p "$(dirname "${secretType.path}")"
    (
      umask u=r,g=,o=
      test -f "${secretType.file}" || echo '[agenix] WARNING: encrypted file ${secretType.file} does not exist!'
      test -d "$(dirname "$TMP_FILE")" || echo "[agenix] WARNING: $(dirname "$TMP_FILE") does not exist!"
      LANG=${config.i18n.defaultLocale or "C"} ${
      if cfg.yubikey.enable
      then "PATH=$PATH:${lib.makeBinPath [cfg.yubikey.plugin]}"
      else ""
    } ${
      if cfg.yubikey.enable
      then "AGE_YUBIKEY_PIN=$AGE_YUBIKEY_PIN"
      else ""
    } ${ageBin} --decrypt -i ''${IDENTITIES[@]} -o "$TMP_FILE" "${secretType.file}"
    )
    chmod ${secretType.mode} "$TMP_FILE"
    mv -f "$TMP_FILE" "$_truePath"

    ${optionalString secretType.symlink ''
      [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && ln -sfn "${cfg.secretsDir}/${secretType.name}" "${secretType.path}"
    ''}
  '';

  testIdentities =
    map
    (path: ''
      test -f ${path} || echo '[agenix] WARNING: config.age.identityPaths entry ${path} not present!'
    '')
    (
      if cfg.yubikey.enable
      then cfg.yubikeyIdentityPaths
      else cfg.identityPaths
    );

  cleanupAndLink = ''
    ${
      if cfg.yubikey.enable
      then "rm -r /tmp/agenix;AGE_YUBIKEY_PIN="
      else ""
    }
    _agenix_generation="$(basename "$(readlink ${cfg.secretsDir})" || echo 0)"
    (( ++_agenix_generation ))
    echo "[agenix] symlinking new secrets to ${cfg.secretsDir} (generation $_agenix_generation)..."
    ln -sfn "${cfg.secretsMountPoint}/$_agenix_generation" ${cfg.secretsDir}

    (( _agenix_generation > 1 )) && {
    echo "[agenix] removing old secrets (generation $(( _agenix_generation - 1 )))..."
    rm -rf "${cfg.secretsMountPoint}/$(( _agenix_generation - 1 ))"
    }
  '';

  installSecrets = builtins.concatStringsSep "\n" (
    ["echo '[agenix] decrypting secrets...'"]
    ++ testIdentities
    ++ [
      (
        if cfg.yubikey.enable
        then yubikeyPinPrompt
        else ""
      )
    ]
    ++ (map installSecret (builtins.attrValues cfg.secrets))
    ++ [cleanupAndLink]
  );

  chownSecret = secretType: ''
    ${setTruePath secretType}
    chown ${secretType.owner}:${secretType.group} "$_truePath"
  '';

  chownSecrets = builtins.concatStringsSep "\n" (
    ["echo '[agenix] chowning...'"]
    ++ [chownMountPoint]
    ++ (map chownSecret (builtins.attrValues cfg.secrets))
  );

  secretType = types.submodule ({config, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        description = ''
          Name of the file used in ''${cfg.secretsDir}
        '';
      };
      file = mkOption {
        type = types.path;
        description = ''
          Age file the secret is loaded from.
        '';
      };
      path = mkOption {
        type = types.str;
        default = "${cfg.secretsDir}/${config.name}";
        description = ''
          Path where the decrypted secret is installed.
        '';
      };
      mode = mkOption {
        type = types.str;
        default = "0400";
        description = ''
          Permissions mode of the decrypted secret in a format understood by chmod.
        '';
      };
      owner = mkOption {
        type = types.str;
        default = "0";
        description = ''
          User of the decrypted secret.
        '';
      };
      group = mkOption {
        type = types.str;
        default = users.${config.owner}.group or "0";
        description = ''
          Group of the decrypted secret.
        '';
      };
      symlink = mkEnableOption "symlinking secrets to their destination" // {default = true;};
    };
  });
in {
  imports = [
    (mkRenamedOptionModule ["age" "sshKeyPaths"] ["age" "identityPaths"])
  ];

  options.age = {
    ageBin = mkOption {
      type = types.str;
      default = "${pkgs.rage}/bin/rage";
      description = ''
        The age executable to use.
      '';
    };
    yubikey = {
      enable = mkEnableOption "Use Yubikeys instead of private keys";
      plugin = mkOption {
        type = types.package;
        default = pkgs.callPackage ../pkgs/age-plugin-yubikey.nix {};
        description = ''
          The age-plugin-yubikey package to use.
        '';
      };
      keys = mkOption {
        default = {};
        description = ''
          Yubikey identities to be used in age decryption.
        '';
        example = {
          AGE-PLUGIN-YUBIKEY-XYZ = {
            slot = 1;
          };
        };
        type = types.attrsOf (types.submodule ({identity, ...}: {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            identity = {
              type = types.str;
              default = identity;
              description = ''
                Identity of the ssh key on your Yubikey. Starts with AGE-PLUGIN-YUBIKEY-
              '';
            };
            slot = {
              type = types.int;
              default = 1;
              description = ''
                Slot of the ssh key on your Yubikey.
              '';
            };
          };
        }));
      };
    };
    secrets = mkOption {
      type = types.attrsOf secretType;
      default = {};
      description = ''
        Attrset of secrets.
      '';
    };
    secretsDir = mkOption {
      type = types.path;
      default = "/run/agenix";
      description = ''
        Folder where secrets are symlinked to
      '';
    };
    secretsMountPoint = mkOption {
      type =
        types.addCheck types.str
        (s:
          (builtins.match "[ \t\n]*" s)
          == null # non-empty
          && (builtins.match ".+/" s) == null) # without trailing slash
        // {description = "${types.str.description} (with check: non-empty without trailing slash)";};
      default = "/run/agenix.d";
      defaultText = "/run/agenix.d";
      description = ''
        Where secrets are created before they are symlinked to ''${cfg.secretsDir}
      '';
    };
    identityPaths = mkOption {
      type = types.listOf types.path;
      default =
        if (config.services.openssh.enable or false)
        then map (e: e.path) (lib.filter (e: e.type == "rsa" || e.type == "ed25519") config.services.openssh.hostKeys)
        else if isDarwin
        then [
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_rsa_key"
        ]
        else [];
      description = ''
        Path to SSH keys to be used as identities in age decryption.
      '';
    };
  };

  config = mkIf (cfg.secrets != {}) (mkMerge [
    {
      assertions = [
        {
          assertion =
            if cfg.yubikey.enable
            then cfg.yubikeyIdentityPaths != []
            else lib.attrsets.attrValues cfg.yubikey.keys != [];
          message = "age.identityPaths (or age.yubikey.keys if age.yubikey.enable is set) must be set.";
        }
      ];
    }

    (optionalAttrs (!isDarwin) {
      # Create a new directory full of secrets for symlinking (this helps
      # ensure removed secrets are actually removed, or at least become
      # invalid symlinks).
      system.activationScripts.agenixNewGeneration = {
        text = newGeneration;
        deps = [
          "specialfs"
        ];
      };

      system.activationScripts.agenixInstall = {
        text = installSecrets;
        deps = [
          "agenixNewGeneration"
          "specialfs"
        ];
      };

      # So user passwords can be encrypted.
      system.activationScripts.users.deps = ["agenixInstall"];

      # Change ownership and group after users and groups are made.
      system.activationScripts.agenixChown = {
        text = chownSecrets;
        deps = [
          "users"
          "groups"
        ];
      };

      # So other activation scripts can depend on agenix being done.
      system.activationScripts.agenix = {
        text = "";
        deps = ["agenixChown"];
      };
    })
    (optionalAttrs isDarwin {
      launchd.daemons.activate-agenix = {
        script = ''
          set -e
          set -o pipefail
          export PATH="${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:@out@/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin"
          ${newGeneration}
          ${installSecrets}
          ${chownSecrets}
          exit 0
        '';
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
        };
      };
    })
  ]);
}
