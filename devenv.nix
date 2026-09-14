{ pkgs, lib, config, inputs, ... }:

{
  packages = [
    pkgs.git
    pkgs.pkg-config
    pkgs.ninja
    pkgs.cmake
    pkgs.rustc
    pkgs.cargo
    pkgs.libxml2.dev
    pkgs.zlib.dev
  ];

  languages.cplusplus.enable = true;
}
