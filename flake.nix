{
  description = "Gjallarhorn — a from-scratch web framework, ORM and template engine in Odin, with a nest-style scaffolding CLI (new / run / build / generate / docs)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # The CLI's `docs` TUI uses core:sys/linux (ioctl), so it's Linux-only.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        default = gjallarhorn;

        gjallarhorn = pkgs.stdenv.mkDerivation {
          pname = "gjallarhorn";
          version = self.shortRev or self.dirtyShortRev or "dev";

          src = pkgs.lib.cleanSource ./.;

          nativeBuildInputs = [ pkgs.odin pkgs.makeWrapper ];

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"     # Odin caches / writes intermediates under HOME
            # `-out:gjallarhorn` would collide with the gjallarhorn/ package dir,
            # so build to .bin and install under the real name below.
            odin build cli -out:gjallarhorn.bin -o:speed
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            install -Dm755 gjallarhorn.bin "$out/bin/gjallarhorn"

            # The framework source that `gjallarhorn new` vendors into a project
            # (the CLI finds it via GJALLARHORN_LIB, set on the wrapper below).
            mkdir -p "$out/share/gjallarhorn"
            cp -r gjallarhorn "$out/share/gjallarhorn/gjallarhorn"

            # Point `new` at the vendored library, and put `odin` on PATH so
            # `gjallarhorn run` / `build` (which exec the compiler) work anywhere.
            wrapProgram "$out/bin/gjallarhorn" \
              --set-default GJALLARHORN_LIB "$out/share/gjallarhorn/gjallarhorn" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.odin ]}

            runHook postInstall
          '';

          meta = {
            description = "From-scratch Odin web framework, ORM and template engine, with a scaffolding CLI";
            homepage = "https://github.com/Lvcky-gg/Gjallarhorn";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.linux;
            mainProgram = "gjallarhorn";
          };
        };
      });

      # `nix run github:Lvcky-gg/Gjallarhorn -- docs`
      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.gjallarhorn}/bin/gjallarhorn";
        };
      });

      # `nix develop` — Odin on PATH for hacking on the framework itself.
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.odin ];
        };
      });
    };
}
