# package.nix - The site generator package.
{
  pkgs,
  lib,
  stdenvNoCC,
  writeText,
  linkFarm,
  gnused,
  ninja,
  pandoc,
  runCommand,
  zsh,
}:

let
  uiop = import ./uiop.nix { inherit pkgs; };
  assetExtensions = [ "css" "jpg" "png" "txt" "woff2" "zip" ];
  siteareas = [
    ./home
  ];

  # IM Fell isn't packaged in nixpkgs. Fetch the five TTFs we use directly
  # from the google/fonts archive (pinned by commit).
  imFellPin = "cf28404eac0c6f9753bef3510bbe271952e4154d";
  fetchImFell = subdir: name: hash:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/google/fonts/${imFellPin}/ofl/${subdir}/${name}";
      inherit hash;
    };
  imFellTtfs = [
    { source = fetchImFell "imfelldwpica" "IMFePIrm28P.ttf"
        "sha256-9l5UAW36tCIrpVLPuCJgsUp99lJ8zmZDD19mAirdsFI=";
      outputName = "IMFePIrm28P.ttf"; }
    { source = fetchImFell "imfelldwpica" "IMFePIit28P.ttf"
        "sha256-4JoAZUtd0mau50PAxD0SnIQEotXg6/J+Wg5HK9GQC40=";
      outputName = "IMFePIit28P.ttf"; }
    { source = fetchImFell "imfelldwpicasc" "IMFePIsc28P.ttf"
        "sha256-f8AcBWsglWvy6EN1NApidDMrZ/eEXLu0ef4LkLQfhF0=";
      outputName = "IMFePIsc28P.ttf"; }
    { source = fetchImFell "imfellenglish" "IMFeENrm28P.ttf"
        "sha256-/pcFu95Rr4AnGSRtRgjQjTe96VarmdmlkNqZalIhokw=";
      outputName = "IMFeENrm28P.ttf"; }
    { source = fetchImFell "imfellenglish" "IMFeENit28P.ttf"
        "sha256-R8113OVLHy4IMTWdItXmiPUZ1orkVwa2ZP0xD9DjzPc=";
      outputName = "IMFeENit28P.ttf"; }
  ];

  etBookDir = "${pkgs.et-book}/share/fonts/truetype";
  etBookTtfs = map
    (name: { source = "${etBookDir}/${name}"; outputName = name; })
    [
      "et-book-roman-old-style-figures.ttf"
      "et-book-display-italic-old-style-figures.ttf"
      "et-book-semi-bold-old-style-figures.ttf"
      "et-book-bold-line-figures.ttf"
    ];

  # Convert one TTF asset to a WOFF2 asset. WOFF2 ships ~45% smaller; saves
  # ~650 KB on this site's font payload.
  ttfToWoff2 = { source, outputName }:
    let base = lib.removeSuffix ".ttf" outputName;
    in {
      source = pkgs.runCommand "${base}.woff2"
        { nativeBuildInputs = [ pkgs.woff2 ]; } ''
          cp ${source} ${outputName}
          woff2_compress ${outputName}
          mv ${base}.woff2 $out
        '';
      outputName = "${base}.woff2";
    };

  pages = uiop.flattenAreas (toString ./.) siteareas;
  assets =
    uiop.collectAssets assetExtensions (toString ./.) ([ ./assets ] ++ siteareas)
    ++ map ttfToWoff2 imFellTtfs
    ++ map ttfToWoff2 etBookTtfs;

  ninjaContent = uiop.mkNinjaBuildFile {
    buildScript = ./buildPage.zsh;
    shell = "${zsh}/bin/zsh";
    inherit pages assets;
  };

  buildNinja = writeText "build.ninja" ninjaContent;

in
stdenvNoCC.mkDerivation rec {
  name = "site";

  src = ./.;
  dontUnpack = true;

  LC_ALL = "C.UTF-8";
  LANG = "C.UTF-8";

  nativeBuildInputs = [
    gnused
    ninja
    pandoc
    zsh
  ];

  buildPhase = ''
    mkdir -p "$out"
    ${uiop.mkBuildNinja {
      inherit buildNinja src;
      builddir = "$PWD";
      out = "$out";
    }}
    ninja -C "${src}" -f "$PWD/build.ninja" -v
  '';

  dontInstall = true;

  passthru = { inherit buildNinja; mkBuildNinja = uiop.mkBuildNinja; };
}
