{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
  pcsclite,
  darwin,
}:
rustPlatform.buildRustPackage rec {
  pname = "age-plugin-yubikey";
  version = "0.4.0+envsupport";

  src = fetchFromGitHub {
    owner = "babeuh";
    repo = pname;
    rev = "v${version}";
    sha256 = "sha256-6AFtZwNXMBWIitIc3cdPOocjIkgaBMAnSp5rAEzrEkk=";
  };

  cargoHash = "sha256-LA0wk8n+5/I5Oxs5WW4s1eHModJNBgg/C8yEhEx/E1s=";

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs =
    [
      openssl
    ]
    ++ lib.optional stdenv.isLinux pcsclite
    ++ lib.optionals stdenv.isDarwin [
      darwin.apple_sdk.frameworks.IOKit
      darwin.apple_sdk.frameworks.Foundation
      darwin.apple_sdk.frameworks.PCSC
    ];

  meta = with lib; {
    description = "YubiKey plugin for age";
    homepage = "https://github.com/babeuh/age-plugin-yubikey";
    changelog = "https://github.com/babeuh/age-plugin-yubikey/blob/${src.rev}/CHANGELOG.md";
    license = with licenses; [mit asl20];
    maintainers = with maintainers; [babeuh];
  };
}
