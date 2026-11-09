{
  description = "llm-jail - QEMU MicroVM sandbox for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Nixpkgs that is pinned in NIX_PATH and flake registry in the VM, should be up to date
    nixpkgs-rolling.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, nixpkgs-rolling, llm-agents, ... }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      tools = import ./tools.nix;

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
      toolsForSystem = system:
        nixpkgs.lib.filterAttrs
          (_: def: builtins.elem system (def.systems or supportedSystems))
          tools;

      flags = {
        devenv = true;
        docker = true;
      };
      apply = package: setFlags: package.override { flags = setFlags; };
      addFlags = import ./lib/addFlags.nix;

      mkTool = system: toolName: toolDef:
        let
          pkgs = nixpkgs-rolling.legacyPackages.${system};
          # Default tool packages - overridable via `.override { claude-code = ...; }`
          # on the resulting runner derivation. Consumers can swap any of these
          # without forking the flake.
          defaultArgs = {
            inherit (llm-agents.packages.${system})
              claude-code
              codex
              copilot-cli
              opencode
              autolith
              pi
              omp
              ;
          };
          tool = pkgs.lib.makeOverridable (
          {
            claude-code,
            codex,
            copilot-cli,
            opencode,
            autolith,
            pi,
            omp,
            flags ? { },
          }:
          let
            guest = nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = {
                inherit
                  nixpkgs
                  nixpkgs-rolling
                  claude-code
                  codex
                  copilot-cli
                  opencode
                  autolith
                  pi
                  omp
                  ;
              };
              modules = [
                toolDef.guestModule
                { nixpkgs.config.allowUnfree = true; }
              ]
              ++ pkgs.lib.optional (flags ? docker) ./guests/docker.nix;
            };
          in import ./lib/mkRunner.nix {
            inherit pkgs guest flags;
            name = toolName;
            toolDefaults = toolDef.defaults;
          }
        ) defaultArgs;
        in
          addFlags tool flags apply;

    in {
      packages = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: def: mkTool system name def) (toolsForSystem system)
      );

      apps = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: _: {
          type = "app";
          program = "${self.packages.${system}.${name}}/bin/llm-jail-${name}";
        }) (toolsForSystem system)
      );

      checks = forAllSystems (system:
        import ./tests {
          inherit nixpkgs nixpkgs-rolling;
          inherit (llm-agents.packages.${system})
            claude-code
            codex
            copilot-cli
            opencode
            autolith
            pi
            omp
            ;
          inherit (self.packages.${system}) shell;
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        }
      );
    };
}
