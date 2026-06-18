# uiop.nix - Utility functions for the static site generator.
# Usage: import ./uiop.nix { inherit pkgs; }
{ pkgs }:
let
  lib = pkgs.lib;
  uiop = rec {
    # Pandoc Lua filter applied to every page.
    pandocFilter = builtins.path {
      path = ./assets/filter.lua;
      name = "filter.lua";
    };

    # -- Path utilities --
    filterExtensions =
      extensions: paths:
      let
        suffixes = map (ext: ".${lib.toLower ext}") extensions;
        match =
          path:
          let
            s = lib.toLower (builtins.toString path);
          in
          builtins.any (suffix: lib.hasSuffix suffix s);
      in
      builtins.filter match paths;

    # Recursively collect all asset files from a list of directories.
    # Returns a list of { source, srcRelPath, outputName } attrsets.
    # source is a Nix path; srcRelPath is relative to projectRoot; outputName is the basename.
    collectAssets =
      extensions: projectRoot: dirs:
      let
        suffixes = map (ext: ".${lib.toLower ext}") extensions;
        isAsset = name: builtins.any (suffix: lib.hasSuffix suffix (lib.toLower name)) suffixes;
        collectDir =
          dir:
          let
            entries = builtins.readDir dir;
            process =
              name: type:
              if type == "directory" then
                collectDir (dir + "/${name}")
              else if type == "regular" && isAsset name then
                let
                  srcPath = dir + "/${name}";
                  relPath = lib.removePrefix (projectRoot + "/") (toString srcPath);
                in
                [
                  {
                    source = srcPath;
                    srcRelPath = relPath;
                    outputName = name;
                  }
                ]
              else
                [ ];
          in
          lib.concatLists (lib.mapAttrsToList process entries);
      in
      lib.concatMap collectDir dirs;
    # -- String utilities --
    # Shell-quote a string with single quotes.
    shellQuote =
      s:
      let
        str = toString s;
      in
      "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] str + "'";

    # Escape dollar signs for ninja syntax.
    ninjaEscapeDollar = s: builtins.replaceStrings [ "$" ] [ "$$" ] s;

    # Escape a path for ninja build statements.
    ninjaEscapePath = s: builtins.replaceStrings [ "$" " " ":" ] [ "$$" "$ " "$:" ] s;

    # Prepare a value for a ninja variable assignment: shell-quote then ninja-escape.
    ninjaVarValue = s: ninjaEscapeDollar (shellQuote s);

    # -- Page normalization --

    # Derive base name from source path: ./index.md -> "index"
    mkPageName = source: lib.removeSuffix ".md" (builtins.baseNameOf (toString source));

    # Construct output filename from prefix and name, all lowercase.
    mkOutputFilename =
      {
        prefix ? null,
        name,
        ...
      }:
      lib.toLower (if prefix != null then "${prefix}--${name}.html" else "${name}.html");

    # Normalize a page attrset: fill in name, output, uplink, homelink, include.
    normalizePage =
      page:
      let
        name = page.name or (mkPageName page.source);
        prefix = page.prefix or null;
        base = page // {
          inherit name;
        };
        withPrefix = if prefix != null then base // { inherit prefix; } else removeAttrs base [ "prefix" ];
        output = mkOutputFilename (withPrefix // { inherit prefix; });

        # Auto-computed nav links; explicit page attrs override via `or`.
        computedUplink =
          if prefix == null then
            false # home area: nowhere to go up to
          else if name == "index" then
            false # area index: already at the top
          else
            mkOutputFilename {
              inherit prefix;
              name = "index";
            };
        computedHomelink =
          if prefix == null then
            false # home area: you are home
          else
            "index.html";

        uplink = withPrefix.uplink or computedUplink;
        homelink = withPrefix.homelink or computedHomelink;
        include = mkNavInclude { inherit uplink homelink; };
        filter = pandocFilter;
      in
      withPrefix
      // {
        inherit
          output
          uplink
          homelink
          include
          filter
          ;
      };

    # Generate a nav HTML fragment and return its store path.
    # uplink / homelink: a URL string to show the link, or false/null to omit it.
    mkNavInclude =
      { uplink, homelink }:
      pkgs.writeText "nav-include" ''
        <nav class="nav">
          ${
            if builtins.isString uplink then ''<a class="up" data-tooltip="Up" href="${uplink}"></a>'' else ""
          }
          ${
            if builtins.isString homelink then
              ''<a class="home" data-tooltip="Home" href="${homelink}"></a>''
            else
              ""
          }
        </nav>
      '';

    # -- Content utilities --

    # Strip a trailing newline (and any preceding carriage return).
    trim = s: lib.removeSuffix "\r" (lib.removeSuffix "\n" s);

    # Extract the document title from a Markdown file using pure Nix string parsing.
    # Handles ATX headings (# through ######), YAML front matter, and pandoc attribute blocks.
    extractTitle =
      source:
      let
        lines = lib.splitString "\n" (builtins.readFile source);

        # Strip YAML front matter (--- … ---/...) if present at the top.
        withoutFM =
          let
            hasFM = lines != [ ] && lib.removeSuffix "\r" (builtins.head lines) == "---";
            skipUntilEnd =
              ls:
              if ls == [ ] then
                [ ]
              else
                let
                  h = lib.removeSuffix "\r" (builtins.head ls);
                in
                if h == "---" || h == "..." then builtins.tail ls else skipUntilEnd (builtins.tail ls);
          in
          if hasFM then skipUntilEnd (builtins.tail lines) else lines;

        # Find the first heading line (any level: # through ######).
        isHeading = line: builtins.match "#{1,6} .*" line != null;
        headingLine = lib.findFirst isHeading null withoutFM;

        # Strip leading hashes + space(s); right-trim trailing whitespace.
        rawTitle =
          if headingLine == null then
            ""
          else
            let
              m = builtins.match "#{1,6} +(.*[^ \t]|[^ \t])" headingLine;
            in
            if m != null then builtins.head m else "";

        # Strip trailing pandoc attribute block {#id .class …}.
        title =
          let
            m = builtins.match "(.*[^ ]) *[{][^}]*[}]$" rawTitle;
          in
          if m != null then builtins.head m else rawTitle;
      in
      title;

    # Lowercase a string and replace non-alphanumeric runs with a single dash.
    slugify =
      s:
      let
        lower = lib.toLower s;
        chars = lib.stringToCharacters lower;
        isAlnum = c: builtins.match "[a-z0-9]" c != null;
        step =
          acc: c:
          if isAlnum c then
            {
              str = acc.str + (if acc.sep && acc.str != "" then "-" else "") + c;
              sep = false;
            }
          else
            acc // { sep = true; };
        result = builtins.foldl' step {
          str = "";
          sep = false;
        } chars;
      in
      result.str;

    # Build a page attrset from a source file and an already-computed title.
    # extraAttrs (e.g. { css = "foo.css"; }) are merged into the result.
    mkPageWithTitle =
      extraAttrs: source: title:
      let
        name = slugify title;
        srcAbsPath = toString source;
        safeSource = builtins.path {
          path = source;
          name = "${name}.md";
        };
      in
      extraAttrs
      // {
        inherit name title srcAbsPath;
        source = safeSource;
      };

    # Build a page attrset from a source file, extracting the title automatically.
    mkPage = extraAttrs: source: mkPageWithTitle extraAttrs source (extractTitle source);

    # Read all .md files from dir as pages, sorted by filename.
    # builtins.attrNames returns keys in lexicographic order.
    readPages =
      extraAttrs: dir:
      let
        mdNames = builtins.filter (n: lib.hasSuffix ".md" n) (builtins.attrNames (builtins.readDir dir));
      in
      map (n: mkPage extraAttrs (dir + "/${n}")) mdNames;

    # Read .md files from dir as chapters: the first keeps its title as-is;
    # subsequent entries are titled "Chapter N — <original title>" (N from 1).
    readPagesWithPrefix =
      prefix: extraAttrs: dir:
      let
        mdNames = builtins.filter (n: lib.hasSuffix ".md" n) (builtins.attrNames (builtins.readDir dir));
        sources = map (n: dir + "/${n}") mdNames;
        mkChapter =
          i: source:
          let
            rawTitle = extractTitle source;
            title = if i == 0 then rawTitle else "${prefix} ${toString i} — ${rawTitle}";
          in
          mkPageWithTitle extraAttrs source title;
      in
      lib.imap0 mkChapter sources;

    # Generate a Markdown index body for a list of { heading, pages } sections.
    mkIndexBody =
      { prefix, sections }:
      let
        mkLink =
          page:
          "- [${page.title}](${
            mkOutputFilename {
              inherit prefix;
              name = page.name;
            }
          })";
        mkSection =
          {
            heading ? null,
            pages,
          }:
          "## ${heading}\n\n" + ":::index\n" + lib.concatStringsSep "\n" (map mkLink pages) + "\n:::\n";
      in
      lib.concatStringsSep "\n\n" (map mkSection sections);

    # Build an index page from a Markdown template.
    # Supports two placeholder styles (may be mixed in one template):
    #   <!-- INDEX:key --> replaced with only the page links for the matching section.
    #     key is section.key if present, otherwise slugify section.heading.
    #   <!-- INDEX --> replaced with all sections (headings + links) bundled.
    # sections: [ { heading = "..."; pages = [...]; } ]
    # extraAttrs (e.g. { css = "..."; }) are merged into the page attrset.
    mkIndexPage =
      {
        prefix,
        template,
        sections,
        extraAttrs ? { },
      }:
      let
        mkLink =
          page:
          "- [${page.title}](${
            mkOutputFilename {
              inherit prefix;
              name = page.name;
            }
          })";
        sectionKey = section: section.key or (slugify (section.heading or ""));
        mkSectionLinks =
          section: ":::index\n" + (lib.concatStringsSep "\n" (map mkLink section.pages)) + "\n:::\n";
        templateContent = builtins.readFile template;
        withNamed = builtins.foldl' (
          content: section:
          builtins.replaceStrings [ "<!-- INDEX:${sectionKey section} -->" ] [ (mkSectionLinks section) ]
            content
        ) templateContent sections;
        body = mkIndexBody { inherit prefix sections; };
        content = builtins.replaceStrings [ "<!-- INDEX -->" ] [ body ] withNamed;
        source = pkgs.writeText "${prefix}-index.md" content;
        title = extractTitle template;
      in
      extraAttrs
      // {
        name = "index";
        inherit source title;
        epubSource = template;
      };

    # -- Area loading --

    # Load a site area directory.
    # "home" gets no prefix; other areas get their dirname as prefix.
    loadArea =
      projectRoot: areaPath:
      let
        rawPages = import areaPath { inherit lib uiop; };
        dirName = builtins.baseNameOf (toString areaPath);
        prefix = if dirName == "home" then null else dirName;
        normPages = map (page: normalizePage ({ inherit prefix; } // page)) rawPages;
        addSrcRelPath =
          page:
          let
            absPath =
              if page ? srcAbsPath then
                page.srcAbsPath
              else if builtins.isPath page.source then
                toString page.source
              else
                null;
            relPath = if absPath != null then lib.removePrefix (projectRoot + "/") absPath else null;
          in
          if relPath != null && relPath != absPath then page // { srcRelPath = relPath; } else page;
      in
      map addSrcRelPath normPages;

    # Load and flatten all site areas into one list.
    flattenAreas = projectRoot: areaPaths: lib.concatMap (loadArea projectRoot) areaPaths;

    # -- Ninja file generation --

    # Structural keys: not passed as environment variables.
    structuralKeys = [
      "source"
      "output"
      "uplink"
      "homelink"
      "srcAbsPath"
      "srcRelPath"
      "epubSource"
    ];

    # Collect the union of all env-var names across all pages.
    collectEnvVarNames =
      pages:
      let
        perPage = map (p: builtins.attrNames (removeAttrs p structuralKeys)) pages;
      in
      lib.unique (lib.concatLists perPage);

    # Generate the ninja rule definition.
    mkNinjaRule =
      {
        envVarNames,
        buildScript,
        shell,
      }:
      let
        dollar = "$";
        mkEnvPart = k: "${k}=${dollar}{${k}}";
        envParts = map mkEnvPart envVarNames;
        envString = lib.concatStringsSep " " envParts;
      in
      "rule buildpage\n"
      + "  command = env ${envString} ${shell} ${buildScript} $in $out\n"
      + "  description = Building $out\n";

    # Generate a ninja build statement for one page.
    pageToNinjaBuild =
      page:
      let
        dollar = "$";
        sourceRef =
          if page ? srcRelPath then
            "${dollar}{src}/${ninjaEscapePath page.srcRelPath}"
          else
            ninjaEscapePath "${page.source}";
        outputRef = "${dollar}{out}/${ninjaEscapePath page.output}";
        envAttrs = lib.filterAttrs (_: v: v != null) (removeAttrs page structuralKeys);
        varLines = lib.mapAttrsToList (k: v: "  ${k} = ${ninjaVarValue v}") envAttrs;
        allLines = [
          "build ${outputRef}: buildpage ${sourceRef}"
        ]
        ++ varLines;
      in
      lib.concatStringsSep "\n" allLines;

    # Ninja rule definition for copying a file verbatim.
    mkNinjaCopyRule =
      "rule copyfile\n" + "  command = cp $in $out\n" + "  description = Copying $out\n";

    # Generate a ninja build statement to copy one asset.
    assetToNinjaBuild =
      asset:
      let
        dollar = "$";
        sourceRef = "${dollar}{src}/${ninjaEscapePath asset.srcRelPath}";
        outputRef = "${dollar}{out}/${ninjaEscapePath asset.outputName}";
      in
      "build ${outputRef}: copyfile ${sourceRef}";

    # Generate a shell snippet that prepends ninja variable assignments and writes the result.
    # output: destination path for the assembled file, defaults to "build.ninja".
    # env: the build link farm, where `build.ninja` can be found.
    # All remaining attributes are treated as varname = shell-token pairs.
    # Values may be Nix-expanded store paths or shell variable references (e.g. "$out", "$PWD").
    # Variables are emitted in alphabetical order (builtins.attrNames).
    mkBuildNinja =
      attrs:
      let
        output = if attrs ? output then attrs.output else "build.ninja";
        vars = removeAttrs attrs [
          "buildNinja"
          "output"
        ];
        names = builtins.attrNames vars;
        format = lib.concatMapStringsSep ''\n'' (name: "${name}=%s") names;
        args = lib.concatStringsSep " " (map (name: ''"'' + vars.${name} + ''"'') names);
      in
      ''
        {
          printf '${format}\n' ${args} | sed -E -e 's/ /$ /g'
          cat ${attrs.buildNinja}
        } > ${output}
      '';

    # Generate the complete build.ninja file content.
    mkNinjaBuildFile =
      {
        buildScript,
        shell,
        pages,
        assets ? [ ],
      }:
      let
        envVarNames = collectEnvVarNames pages;
        pageRule = mkNinjaRule { inherit envVarNames buildScript shell; };
        pageBuilds = map pageToNinjaBuild pages;
        assetBuilds = map assetToNinjaBuild assets;
      in
      lib.concatStringsSep "\n\n" (
        [
          pageRule
          mkNinjaCopyRule
        ]
        ++ pageBuilds
        ++ assetBuilds
        ++ [ "" ]
      );
  };
in
uiop
