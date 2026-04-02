{ pkgs, lib, config, inputs, ... }:

{
  packages = [
    pkgs.git
    pkgs.pkg-config
    pkgs.ninja
    pkgs.cmake
    pkgs.rustc
    pkgs.cargo
  ];

  languages.cplusplus.enable = true;
}
