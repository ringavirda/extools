# Generating repositories rather than driving an existing one: a standalone starter monorepo from
# the exlib checkout's own samples, and an empty mod scaffolded into whichever repo names this
# checkout as its tools.
#
#   exmod starter <dest>     a standalone starter repo, generated from exlib's tested samples
#   exmod new <modid>        an empty mod (or, with --module, a framework module) added to this repo

#region manifest

# Escapes a string for embedding inside a JSON string literal built by hand - this generator's
# modinfo.json and lang templates are plain text, not run through ConvertTo-Json. Backslash first,
# then the quote it would otherwise close early.
function ConvertTo-JsonStringLiteral([string]$Text) {
  return $Text.Replace('\', '\\').Replace('"', '\"')
}

# One mods/samples-shaped entry, compact: "<id>": { "path": "<path>" [, "<key>": <value>]... },
# carrying whatever extra keys the entry already has (e.g. overlays) in the order
# ConvertFrom-Json gave them.
function ConvertTo-CompactModRow([string]$Id, [pscustomobject]$Entry) {
  $parts = foreach ($p in $Entry.PSObject.Properties) {
    "`"$($p.Name)`": $($p.Value | ConvertTo-Json -Depth 10 -Compress)"
  }
  return "`"$Id`": { $($parts -join ', ') }"
}

# Writes exmod.json in the compact, hand-editable shape both starter and new produce - never
# through a bare ConvertTo-Json, which explodes 'mods' into one property per line per entry and
# reorders nothing usefully. Every field of $Manifest is written back in its own order; 'mods' as
# one row per id, 'series' and 'depends' as their own compact shapes, everything else through
# ConvertTo-Json -Compress.
function Write-ExmodManifest([pscustomobject]$Manifest, [string]$Path) {
  $fieldLines = foreach ($prop in $Manifest.PSObject.Properties) {
    switch ($prop.Name) {
      'mods' {
        $rows = @($prop.Value.PSObject.Properties | ForEach-Object { '    ' + (ConvertTo-CompactModRow $_.Name $_.Value) })
        "  `"mods`": {`n" + ($rows -join ",`n") + "`n  }"
      }
      'series' {
        $items = (@($prop.Value) | ForEach-Object { "`"$_`"" }) -join ', '
        "  `"series`": [$items]"
      }
      'depends' {
        $rows = @($prop.Value.PSObject.Properties | ForEach-Object {
          "    `"$($_.Name)`": $($_.Value | ConvertTo-Json -Depth 10 -Compress)"
        })
        "  `"depends`": {`n" + ($rows -join ",`n") + "`n  }"
      }
      default {
        "  `"$($prop.Name)`": $($prop.Value | ConvertTo-Json -Depth 10 -Compress)"
      }
    }
  }
  ("{`n" + ($fieldLines -join ",`n") + "`n}`n") | Set-Content $Path -NoNewline
}

#endregion

#region csproj transform

# Replaces the first occurrence of $Old with $New, or throws naming $Label - a block that has
# vanished means the sample this transform reads from has changed shape, which is a transform bug,
# not something to silently paper over. $New empty removes the block outright.
function Set-CsprojText([string]$Text, [string]$Old, [string]$New, [string]$Label) {
  if (-not $Text.Contains($Old)) { throw "starter transform: expected text not found ($Label)." }
  return $Text.Replace($Old, $New)
}

# Replaces everything from the start of $Begin to the end of $End (searched after $Begin) with
# $New. Used for the one block whose interior text differs between HelloExpanded's and HelloModule's
# csproj (a generator comment naming the assembly) but whose edges do not, so a plain Set-CsprojText
# can't match both files with one literal string.
function Set-CsprojSpan([string]$Text, [string]$Begin, [string]$End, [string]$New, [string]$Label) {
  $start = $Text.IndexOf($Begin)
  if ($start -lt 0) { throw "starter transform: expected span start not found ($Label)." }
  $endAt = $Text.IndexOf($End, $start)
  if ($endAt -lt 0) { throw "starter transform: expected span end not found ($Label)." }
  $stop = $endAt + $End.Length
  return $Text.Substring(0, $start) + $New + $Text.Substring($stop)
}

# The sample mod csproj (HelloExpanded.csproj or HelloModule.csproj) with its source-mode half
# removed: the explicit Sdk.props/Sdk.targets split collapses to the ordinary Sdk attribute, the
# $(ExlibRoot) default and the two conditioned build/ExpandedLib.props|targets imports go, and the
# dual-mode ItemGroup unwraps to its package-mode half unconditioned. $(CurrentGameTfm)'s own
# default survives - restore needs $(TargetFramework) before any package is present, so it can't
# come from the package's own props, standalone or not. Fails loudly the moment the sample this
# reads from no longer matches the blocks below, rather than silently shipping half a transform.
function ConvertTo-StarterModCsproj([string]$Text, [string]$Label) {
  $Text = Set-CsprojText $Text @'
<Project>
  <!-- samples/ sits directly under this repo's root, so unlike a mod under mods/ in the family repo
       it would otherwise auto-inherit Directory.Build.props/.targets the way every project below
       the root does. It deliberately opts out (ImportDirectoryBuildProps/Targets=false, and the
       explicit Sdk.props/Sdk.targets split that lets the props half take effect) and imports the
       shared build files directly instead - the props here, the targets at the bottom of this file -
       which is exactly what a third-party mod's own project gets from the ExpandedLib package; see
       the wiki's Getting-Started for the standalone form. Source mode only ($(ExlibRoot) != ''): in
       package mode the PackageReference below pulls the same two files in automatically (the NuGet
       build/<id>.props|targets convention), and importing both ways would double them up. Opting out
       of the repo's own Directory.Build.props also keeps -p:ExlibRoot= (forcing package mode)
       meaningful here: that file's own default would otherwise refill it. -->
  <PropertyGroup>
    <ImportDirectoryBuildProps>false</ImportDirectoryBuildProps>
    <ImportDirectoryBuildTargets>false</ImportDirectoryBuildTargets>
  </PropertyGroup>
  <Import Project="Sdk.props" Sdk="Microsoft.NET.Sdk" />
'@ '<Project Sdk="Microsoft.NET.Sdk">' "$Label header"

  $Text = Set-CsprojText $Text @'

  <PropertyGroup>
    <!-- The source-mode switch, canonically set in this repo's own Directory.Build.props; this
         project opts out of that file's auto-import (see above), so it carries the same one-line
         default rather than importing that whole file, which would also pull in the version
         manifest and test-only settings this project has no use for.
         -p:ExlibRoot= (a global property) wins over this default and forces package mode. -->
    <ExlibRoot Condition="'$(ExlibRoot)' == ''"
      >$(MSBuildThisFileDirectory)../../</ExlibRoot>
    <!-- Restore needs $(TargetFramework) (below, reading $(CurrentGameTfm)) before any package is
         present, so in package mode it can't come through ExpandedLib.props - the same reason the
         target framework list always stays in the consumer, never the package. Source mode's
         ExpandedLib.props sets the same default, guarded the same way, so this only ever fires
         first. -->
    <CurrentGameTfm Condition="'$(CurrentGameTfm)' == ''"
      >net10.0</CurrentGameTfm>
  </PropertyGroup>
  <Import
    Project="../../build/ExpandedLib.props"
    Condition="'$(ExlibRoot)' != ''"
  />
'@ @'

  <PropertyGroup>
    <!-- Restore needs $(TargetFramework) before any package is present, so this repo - standalone,
         package mode only - carries the default itself rather than through an import. -->
    <CurrentGameTfm Condition="'$(CurrentGameTfm)' == ''"
      >net10.0</CurrentGameTfm>
  </PropertyGroup>
'@ "$Label ExlibRoot default + build/ExpandedLib.props import"

  $Text = Set-CsprojText $Text @'
    <!-- Primary build is the current game version, single-target; the legacy lanes buy nothing for
         a sample that exists to be read, so this stays on $(CurrentGameTfm) even with -p:Legacy=true. -->
'@ @'
    <!-- Single-target, the current game version only: a starter mod carries no legacy game series
         to build for, unlike the family repo this was generated from. -->
'@ "$Label legacy-lane comment"

  $Text = Set-CsprojSpan $Text @'
  <!--
    Inside this monorepo (source mode,
'@ '  <ItemGroup Condition="''$(ExlibRoot)'' == ''''">' '  <ItemGroup>' "$Label dual-mode exlib reference"

  $Text = Set-CsprojText $Text @'
  <!-- Imported last so the properties it needs from the project body ($(TargetFramework),
       $(AssetDomain) - unset here, so its asset globs stay inert) are already evaluated; see
       ExpandedLib.targets for what this pulls in (GamePath, provisioning, the capability
       constants). This project carries no AssetDomain of its own, so its assets/ (a direct sibling
       of the csproj, not one level up under src/) is still globbed by hand below. Source mode only,
       same reason as the .props import above. -->
  <Import
    Project="../../build/ExpandedLib.targets"
    Condition="'$(ExlibRoot)' != ''"
  />


'@ '' "$Label build/ExpandedLib.targets import"

  # The starter nests a mod's tests under its own folder (mods/<id>/tests, the layout
  # Get-ExmodMods reads), unlike the sample this is generated from, which keeps its tests project
  # entirely outside the sample folder - so the SDK's implicit compile glob, unmodified, would
  # compile the test project's own sources into the mod's assembly too.
  $Text = Set-CsprojText $Text @'
    <OutputPath>bin\$(Configuration)\Mods\mod</OutputPath>
'@ @'
    <OutputPath>bin\$(Configuration)\Mods\mod</OutputPath>
    <DefaultItemExcludes>$(DefaultItemExcludes);tests/**</DefaultItemExcludes>
'@ "$Label tests/ compile exclusion"

  $Text = Set-CsprojText $Text @'

  <Import Project="Sdk.targets" Sdk="Microsoft.NET.Sdk" />
</Project>
'@ @'

</Project>
'@ "$Label footer"

  return $Text
}

# The sample test csproj (HelloExpanded.Tests.csproj or HelloModule.Tests.csproj) with its
# source-mode half removed, the same way ConvertTo-StarterModCsproj does for the mod project: the
# Sdk.props/Sdk.targets split collapses, the repo-root Directory.Build.props import (which carried
# $(CurrentGameTfm) here) is replaced with the project's own default, and the dual-mode ItemGroup
# unwraps to its package-mode half. $OldModRef/$NewModRef rewrite the ProjectReference to the mod
# project: the starter's tests sit one level deeper than the sample's own (mods/<id>/tests vs
# samples/<Name>.Tests), so the relative path shortens by one segment.
function ConvertTo-StarterTestCsproj([string]$Text, [string]$OldModRef, [string]$NewModRef, [string]$Label) {
  $Text = Set-CsprojText $Text @'
<Project>
  <!-- samples/ sits directly under this repo's root, so it would otherwise auto-inherit
       Directory.Build.props/.targets the way every project below the root does; opted out
       (ImportDirectoryBuildProps/Targets=false, and the explicit Sdk.props/Sdk.targets split that
       lets the props half take effect) so the explicit import below is the only source, not a
       second copy layered on top of the automatic one. -->
  <PropertyGroup>
    <ImportDirectoryBuildProps>false</ImportDirectoryBuildProps>
    <ImportDirectoryBuildTargets>false</ImportDirectoryBuildTargets>
  </PropertyGroup>
  <Import Project="Sdk.props" Sdk="Microsoft.NET.Sdk" />
  <Import Project="../../Directory.Build.props" />

  <PropertyGroup>
    <TargetFramework>$(CurrentGameTfm)</TargetFramework>
'@ @'
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <!-- Restore needs $(TargetFramework) before any package is present, so this repo - standalone,
         package mode only - carries the default itself rather than through an import. -->
    <CurrentGameTfm Condition="'$(CurrentGameTfm)' == ''"
      >net10.0</CurrentGameTfm>
    <TargetFramework>$(CurrentGameTfm)</TargetFramework>
'@ "$Label header"

  $Text = Set-CsprojText $Text @'
    <!-- Private=true, same as a family mod's own tests project: the vstest discoverer probes a test assembly's direct
         references on disk BEFORE the harness's assembly resolver can run, and a reference missing
         from the output folder makes discovery silently report zero tests rather than fail. -->
'@ @'
    <!-- Private=true: the vstest discoverer probes a test assembly's direct references on disk
         BEFORE the harness's assembly resolver can run, and a reference missing from the output
         folder makes discovery silently report zero tests rather than fail. -->
'@ "$Label Private=true comment"

  $Text = Set-CsprojSpan $Text @'
  <!-- Dual mode, same switch as
'@ '  <ItemGroup Condition="''$(ExlibRoot)'' == ''''">' '  <ItemGroup>' "$Label dual-mode harness reference"

  $Text = Set-CsprojText $Text $OldModRef $NewModRef "$Label mod project reference"

  $Text = Set-CsprojText $Text @'
  <!-- Explicit import: GamePath (used above via HintPath) lives in ExpandedLib.targets,
       imported after the project body - the Directory.Build.props import above only carries
       ExpandedLib.props (the props half), and this project sits outside src/, so the
       auto-imported Directory.Build.targets never reaches it either. Source mode only
       ($(ExlibRoot) != ''): in package mode the ExpandedLib PackageReference above pulls the same
       file in automatically, and importing both ways would double it up. -->
  <Import
    Project="../../build/ExpandedLib.targets"
    Condition="'$(ExlibRoot)' != ''"
  />

'@ '' "$Label build/ExpandedLib.targets import"

  $Text = Set-CsprojText $Text @'

  <Import Project="Sdk.targets" Sdk="Microsoft.NET.Sdk" />
</Project>
'@ @'

</Project>
'@ "$Label footer"

  return $Text
}

#endregion

#region generate

# Copies $Src into $Dest recursively, skipping bin/ and obj/ - the two folders every sample carries
# from being built and tested in place, and the only ones a starter must not inherit.
function Copy-SourceTree([string]$Src, [string]$Dest) {
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  Get-ChildItem $Src -Force | Where-Object { $_.Name -notin @('bin', 'obj') } | ForEach-Object {
    if ($_.PSIsContainer) { Copy-SourceTree $_.FullName (Join-Path $Dest $_.Name) }
    else { Copy-Item $_.FullName (Join-Path $Dest $_.Name) -Force }
  }
}

# One starter mod: copies the sample's src/, assets/ and modicon.png (if any) verbatim, pins the
# modinfo.json's exlib dependency floor to $Version (the starter's whole point - a guard other than
# this generator would otherwise have to keep in step by hand), transforms the mod csproj and, when
# the sample carries one, the tests project.
function New-StarterMod {
  param(
    [string]$ExlibRoot, [string]$Dest, [string]$SampleName, [string]$ModId, [string]$Version,
    [string]$ModuleRefOld, [string]$ModuleRefNew
  )
  $samplePath = Join-Path $ExlibRoot "samples/$SampleName"
  if (-not (Test-Path $samplePath)) { throw "exlib checkout at $ExlibRoot has no samples/$SampleName." }
  $modDest = Join-Path $Dest "mods/$ModId"
  New-Item -ItemType Directory -Force -Path $modDest | Out-Null

  Copy-SourceTree (Join-Path $samplePath 'src') (Join-Path $modDest 'src')
  Copy-SourceTree (Join-Path $samplePath 'assets') (Join-Path $modDest 'assets')
  $icon = Join-Path $samplePath 'modicon.png'
  if (Test-Path $icon) { Copy-Item $icon (Join-Path $modDest 'modicon.png') -Force }

  # Parsed rather than matched by a regex that would no-op silently if the shape ever changed: a
  # sample's modinfo.json missing an exlib dependency is a transform bug, not something to ship
  # half-pinned. The replace itself still runs on the raw text (not a re-serialization, which would
  # reflow the whole file), through the literal old "exlib": "<floor>" line, checked to occur
  # exactly once.
  $modinfoText = Get-Content (Join-Path $samplePath 'modinfo.json') -Raw
  $modinfoJson = $modinfoText | ConvertFrom-Json
  if (-not $modinfoJson.dependencies -or -not $modinfoJson.dependencies.PSObject.Properties['exlib']) {
    throw "starter transform: samples/$SampleName/modinfo.json names no exlib dependency."
  }
  $oldExlibLine = "`"exlib`": `"$($modinfoJson.dependencies.exlib)`""
  $matchCount = ([regex]::Matches($modinfoText, [regex]::Escape($oldExlibLine))).Count
  if ($matchCount -ne 1) {
    throw "starter transform: samples/$SampleName/modinfo.json's exlib dependency line occurs $matchCount times (want exactly 1)."
  }
  $modinfoText = $modinfoText.Replace($oldExlibLine, "`"exlib`": `"$Version`"")
  Set-Content (Join-Path $modDest 'modinfo.json') $modinfoText -NoNewline

  $csprojSrc = Find-SingleCsproj $samplePath "samples/$SampleName"
  $csprojName = Split-Path $csprojSrc -Leaf
  $csprojText = ConvertTo-StarterModCsproj (Get-Content $csprojSrc -Raw) $SampleName
  if ($ModuleRefOld) {
    $csprojText = Set-CsprojText $csprojText $ModuleRefOld $ModuleRefNew "$SampleName module reference"
    $csprojText = Set-CsprojText $csprojText @'
  <!-- hellomodule is a sample dependency inside this repo, not a package - referenced by project in
       both modes. Copy-local off for the same reason as exlib above: the player installs
       hellomodule as its own mod. -->
'@ @'
  <!-- hellomodule is this starter's own mod, referenced by project rather than package the same
       way exlib is above. Copy-local off for the same reason: the player installs hellomodule as
       its own mod. -->
'@ "$SampleName module reference comment"
  }
  Set-Content (Join-Path $modDest $csprojName) $csprojText -NoNewline

  $testsSrc = Join-Path $ExlibRoot "samples/$SampleName.Tests"
  if (-not (Test-Path $testsSrc)) { return }
  $testsDest = Join-Path $modDest 'tests'
  New-Item -ItemType Directory -Force -Path $testsDest | Out-Null
  Get-ChildItem $testsSrc -Force | Where-Object { $_.Name -notin @('bin', 'obj') } | ForEach-Object {
    if ($_.Extension -eq '.csproj') { return }
    if ($_.PSIsContainer) { Copy-SourceTree $_.FullName (Join-Path $testsDest $_.Name) }
    else { Copy-Item $_.FullName (Join-Path $testsDest $_.Name) -Force }
  }
  $testCsprojSrc = Find-SingleCsproj $testsSrc "samples/$SampleName.Tests"
  $testCsprojName = Split-Path $testCsprojSrc -Leaf
  # samples/<Name>.Tests sits beside samples/<Name>, so the sample's own reference reads
  # "..\<Name>\<Name>.csproj"; a starter's tests live one level DEEPER, inside the mod's own folder
  # (mods/<id>/tests), so the equivalent reference is "..\<Name>.csproj" - one level up only.
  $oldModRef = "<ProjectReference Include=`"..\$SampleName\$csprojName`" />"
  $newModRef = "<ProjectReference Include=`"..\$csprojName`" />"
  $testCsprojText = ConvertTo-StarterTestCsproj (Get-Content $testCsprojSrc -Raw) $oldModRef $newModRef $SampleName
  Set-Content (Join-Path $testsDest $testCsprojName) $testCsprojText -NoNewline
}

# One PackageVersion's pinned version, read from exlib's own Directory.Packages.props by a literal
# match on its Include - the starter tracks exlib's own versions for these test/harness packages
# rather than pinning a second copy by hand that silently drifts from what exlib actually tests
# against.
function Get-ExlibPackageVersion([string]$ExlibRoot, [string]$Id) {
  $propsPath = Join-Path $ExlibRoot 'Directory.Packages.props'
  $text = Get-Content $propsPath -Raw
  $m = [regex]::Match($text, "PackageVersion Include=`"$([regex]::Escape($Id))`" Version=`"([^`"]+)`"")
  if (-not $m.Success) { throw "exlib checkout's Directory.Packages.props names no PackageVersion for '$Id'." }
  return $m.Groups[1].Value
}

# Refuses a $Dest that would make `starter` wipe tooling out from under a live checkout (it is,
# contains, or is contained by the repo running the command, the tools checkout, or the exlib
# checkout it reads from), or drop generated files into a directory that holds something else
# entirely (non-empty, and carrying no marker of a previous `starter` run) unless -Force says so.
function Assert-StarterDest([string]$Dest, [string]$RepoRoot, [string]$ToolsRoot, [string]$ExlibRoot, [bool]$Force) {
  $full = [System.IO.Path]::GetFullPath($Dest).TrimEnd('/', '\')
  foreach ($guarded in @($RepoRoot, $ToolsRoot, $ExlibRoot)) {
    $g = $guarded.TrimEnd('/', '\')
    if ($full -eq $g -or $full.StartsWith("$g/") -or $full.StartsWith("$g\") -or
        $g.StartsWith("$full/") -or $g.StartsWith("$full\")) {
      throw "exmod starter refuses to generate at ${Dest}: it is, contains, or is contained by $guarded."
    }
  }
  if (-not (Test-Path $Dest)) { return }
  $entries = @(Get-ChildItem $Dest -Force)
  if ($entries.Count -eq 0) { return }
  $readme = Join-Path $Dest 'README.md'
  $marker = (Test-Path $readme) -and ((Get-Content $readme -Raw) -match 'generated by\s*`exmod starter`')
  if (-not $marker -and -not $Force) {
    throw "exmod starter refuses to generate at ${Dest}: it is not empty and carries no marker of a previous starter run. Pass -Force to proceed anyway."
  }
}

# (Re)generates $Dest/$Name.sln, adding every project in $Projects, in order. The solution is owned
# by `starter`: this always starts from nothing (a stale project reference from a mod that no
# longer exists would otherwise survive a re-run) and every project a re-run's caller still wants -
# the two generated mods and every mod `exmod new` carried forward - is added back by the caller.
function New-StarterSolution([string]$Dest, [string]$Name, [string[]]$Projects) {
  $slnPath = Join-Path $Dest "$Name.sln"
  if (Test-Path $slnPath) { Remove-Item -Force $slnPath }
  Push-Location $Dest
  try {
    # -f sln: the SDK's own default flipped to the XML .slnx format, which Get-ExmodSolution (a
    # plain *.sln glob) and `dotnet sln add` below do not expect.
    dotnet new sln -n $Name -f sln | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet new sln failed in $Dest." }
    foreach ($proj in $Projects) {
      dotnet sln "$Name.sln" add $proj | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "dotnet sln add $proj failed in $Dest." }
    }
  } finally {
    Pop-Location
  }
  return $slnPath
}

$StarterGitignore = @'
[Dd]ebug/
[Rr]elease/
[Bb]in/
[Oo]bj/
*.user
.vs/
.idea/
TestResults/

# Downloaded Vintage Story installs + cached archives.
/.game
/.gamedata

# Self-contained .NET (SDK + runtimes).
/.dotnet

# Dependency mods `exmod provision mods` resolves and caches.
/.exmod/

# extools, cloned by scripts/exmod.sh or scripts/exmod.ps1 when no sibling checkout is found.
/.extools/
'@

$StarterLicense = @'
MIT License

Copyright (c) <year> <your name>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@

$StarterReadmeTemplate = @'
# {0}

A starter monorepo for [Expanded Library](https://github.com/ringavirda/exlib) mods, generated by
`exmod starter` from exlib
{1}. It carries two mods: `mods/hellomodule`, a framework module shipped as its own mod, and
`mods/helloexpanded`, a mod that depends on it - the same pair exlib's own Getting-Started guide and
Modules wiki page walk through, here as a working repository instead of a read-along.

## Using it

```
git clone <this repo>
cd {2}
bash scripts/exmod.sh setup       # .NET, the game, exlib and its two mods, restored
bash scripts/exmod.sh build latest
bash scripts/exmod.sh test latest
bash scripts/exmod.sh smoke       # boots a real dedicated server with both mods loaded
```

Windows runs the same commands through `scripts\exmod.ps1`; `bash scripts/exmod.sh` with no command
lists everything else `exmod` can do (run a client, package a release, and so on), and
`exmod help <command>` describes one in detail.

## Adding a mod

```
bash scripts/exmod.sh new <id>              # a mod
bash scripts/exmod.sh new <id> --module     # a framework module, the shape hellomodule is
```

scaffolds `mods/<id>` (csproj, modinfo.json, an asset skeleton, a test project wired to the
harness), adds it to `exmod.json` and, when this repo names a solution, to it too. A scaffolded
mod's csproj sits under `mods/<id>/src/`, unlike the two generated mods above (csproj beside
modinfo.json, no src/ split) - both shapes resolve the same way, but only the flat one matches the
sample this repo was generated from. `new` needs Directory.Packages.props' own `ExpandedLib`
PackageVersion to pin against; it never runs before `setup` has produced one.

## Licence

MIT licensed; see LICENSE.
'@

# The starter repository at $Dest: both sample mods as a monorepo, the launcher scripts, the
# manifest, a solution, CI and the repo dotfiles - everything a `git clone` of this generated repo
# needs to restore, build, test and smoke with nothing hand-edited. Regenerates in place: every
# path this command owns is wiped and rewritten on each run, and every mod `exmod new` has added
# since is carried forward into the fresh manifest and solution rather than dropped. A fresh $Dest
# is committed once, an existing one is left for the caller to review and commit.
function Invoke-Starter([string[]]$Argv) {
  $positional = @(Get-Positional $Argv @('-ExlibRoot', '-Version') @('-Force'))
  if ($positional.Count -lt 1) { throw "exmod starter needs a destination path." }
  $dest = if ([System.IO.Path]::IsPathRooted($positional[0])) { $positional[0] } else { Join-Path (Get-Location).Path $positional[0] }
  $force = Get-Flag $Argv '-Force'

  $exlibRoot = Get-Opt $Argv '-ExlibRoot' $null
  if (-not $exlibRoot) {
    $sibling = Join-Path $RepoRoot '../exlib'
    if (-not (Test-Path (Join-Path $sibling 'exmod.json'))) {
      throw "No exlib checkout found: pass -ExlibRoot <path>, or check one out beside this repository as ../exlib."
    }
    $exlibRoot = $sibling
  }
  $exlibRoot = (Resolve-Path $exlibRoot).Path

  Assert-StarterDest $dest $RepoRoot $ToolsRoot $exlibRoot $force

  $exlibModinfoPath = Join-Path $exlibRoot 'src/modinfo.json'
  if (-not (Test-Path $exlibModinfoPath)) { throw "exlib checkout at $exlibRoot has no src/modinfo.json." }
  $exlibVersion = (Get-Content $exlibModinfoPath -Raw | ConvertFrom-Json).version
  $version = Get-Opt $Argv '-Version' $exlibVersion

  # The tools pin: the version of THIS extools checkout (whose wrappers/ are copied into
  # scripts/ below), not of whatever repository's exmod.json happens to be driving the command.
  $toolsVersion = (Get-Content (Join-Path $ToolsRoot 'exmod.json') -Raw | ConvertFrom-Json).tools
  # The game series CI and the smoke lane pin - the current supported patch, not just the series,
  # so a fresh clone's first `exmod setup` provisions the same server build this was proven against.
  $vsVersionPin = '1.22.7'

  Write-Step "Generating starter at $dest (exlib $version)"
  $isNewRepo = -not (Test-Path (Join-Path $dest '.git'))
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $repoName = Split-Path $dest -Leaf

  # Every mod `exmod new` added since the last run, read before anything below touches exmod.json,
  # so a re-run carries them forward into the fresh manifest and solution instead of dropping them.
  $existingManifestPath = Join-Path $dest 'exmod.json'
  $carriedMods = [ordered]@{}
  if (Test-Path $existingManifestPath) {
    $existingManifest = Get-Content $existingManifestPath -Raw | ConvertFrom-Json
    if ($existingManifest.PSObject.Properties['mods']) {
      foreach ($p in $existingManifest.mods.PSObject.Properties) {
        if ($p.Name -in @('hellomodule', 'helloexpanded')) { continue }
        $carriedMods[$p.Name] = $p.Value
      }
    }
  }

  # Every path this command owns; wiped and rewritten below so a re-run overwrites rather than
  # accumulates. Only the two sample mods, not all of mods/ - `exmod new` may have added others
  # since the last run, and those entries were read above and are merged back into the manifest and
  # solution further down, not wiped. exmod.json and the solution are rewritten in place, not
  # wiped-then-regenerated blind, for the same reason. .git, and anything else the owner added by
  # hand, is left alone too.
  foreach ($p in @('mods/hellomodule', 'mods/helloexpanded', 'scripts', '.github',
      'Directory.Packages.props', '.gitignore', '.gitattributes', '.editorconfig', '.csharpierrc',
      'LICENSE', 'README.md')) {
    $full = Join-Path $dest $p
    if (Test-Path $full) { Remove-Item -Recurse -Force $full }
  }

  # hellomodule first: helloexpanded's csproj references it by project, so it has to exist (and,
  # for the build order Get-ExmodMods/Get-ExmodBuildTargets read off exmod.json's own order, build
  # first) before helloexpanded does.
  New-StarterMod -ExlibRoot $exlibRoot -Dest $dest -SampleName 'HelloModule' -ModId 'hellomodule' -Version $version
  New-StarterMod -ExlibRoot $exlibRoot -Dest $dest -SampleName 'HelloExpanded' -ModId 'helloexpanded' -Version $version `
    -ModuleRefOld '<ProjectReference Include="..\HelloModule\HelloModule.csproj">' `
    -ModuleRefNew '<ProjectReference Include="..\hellomodule\HelloModule.csproj">'

  $allMods = [ordered]@{}
  $allMods['hellomodule'] = [pscustomobject]@{ path = 'mods/hellomodule' }
  $allMods['helloexpanded'] = [pscustomobject]@{ path = 'mods/helloexpanded' }
  foreach ($k in $carriedMods.Keys) { $allMods[$k] = $carriedMods[$k] }

  $slnProjects = @()
  foreach ($id in $allMods.Keys) {
    $modPath = Join-Path $dest $allMods[$id].path
    if (-not (Test-Path $modPath)) { throw "starter: mods.$id names $modPath, which does not exist." }
    $slnProjects += Find-SingleCsproj (Get-ModProjectDir $modPath) "mods.$id"
    $testsDir = Join-Path $modPath 'tests'
    if (Test-Path $testsDir) { $slnProjects += Find-SingleCsproj $testsDir "mods.$id.tests" }
  }
  New-StarterSolution -Dest $dest -Name $repoName -Projects $slnProjects | Out-Null

  $manifestObj = [pscustomobject]@{
    tools    = $toolsVersion
    series   = @('1.22')
    solution = "$repoName.sln"
    mods     = [pscustomobject]$allMods
    depends  = [pscustomobject]@{ exlib = [pscustomobject]@{ github = 'ringavirda/exlib' } }
  }
  Write-ExmodManifest $manifestObj (Join-Path $dest 'exmod.json')

  $scriptsDir = Join-Path $dest 'scripts'
  New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
  Copy-Item (Join-Path $ToolsRoot 'wrappers/exmod.sh') (Join-Path $scriptsDir 'exmod.sh') -Force
  Copy-Item (Join-Path $ToolsRoot 'wrappers/exmod.ps1') (Join-Path $scriptsDir 'exmod.ps1') -Force

  $testSdkVersion = Get-ExlibPackageVersion $exlibRoot 'Microsoft.NET.Test.Sdk'
  $xunitVersion = Get-ExlibPackageVersion $exlibRoot 'xunit'
  $xunitRunnerVersion = Get-ExlibPackageVersion $exlibRoot 'xunit.runner.visualstudio'
  $nsubstituteVersion = Get-ExlibPackageVersion $exlibRoot 'NSubstitute'

  @"
<Project>
  <!-- Central package management: every csproj's PackageReference drops its Version attribute and
       the version moves here, one row per package id. The three ExpandedLib rows are pinned to the
       exlib version this starter was generated from; bump them together with a fresh
       exmod starter run, not by hand. The test/harness rows above them track exlib's own
       Directory.Packages.props the same way, read at generation time rather than copied by hand. -->
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>

  <ItemGroup>
    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="$testSdkVersion" />
    <PackageVersion Include="xunit" Version="$xunitVersion" />
    <PackageVersion Include="xunit.runner.visualstudio" Version="$xunitRunnerVersion" />
    <PackageVersion Include="NSubstitute" Version="$nsubstituteVersion" />

    <PackageVersion Include="ExpandedLib" Version="$version" />
    <!-- Referenced by no mod this starter generates; here for a mod that adds the Industry module. -->
    <PackageVersion Include="ExpandedLib.Industry" Version="$version" />
    <PackageVersion Include="ExpandedLib.Testing" Version="$version" />
  </ItemGroup>
</Project>
"@ | Set-Content (Join-Path $dest 'Directory.Packages.props')

  $ciDir = Join-Path $dest '.github/workflows'
  New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
  ((@'
# Build and test lane, generated by `exmod starter`. Both mods and their tests are driven through
# exmod, the same commands a local checkout runs - see .github/workflows/smoke.yml for the matching
# dedicated-server boot check.

name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  VS_VERSION: "1.22"

jobs:
  test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: "10.0.x"

      - name: Cache Vintage Story install
        uses: actions/cache@v4
        with:
          path: .game
          key: vs-game-${{ env.VS_VERSION }}

      # Provisions the freely-downloadable dedicated-server archive into .game/<slug> - it carries
      # VintagestoryAPI.dll/VSSurvivalMod.dll/VSEssentials.dll, so no game licence or purchase is
      # needed to build and test a mod headlessly.
      - name: Provision Vintage Story (server assemblies)
        run: bash scripts/exmod.sh provision game -Version "$VS_VERSION" -Kind server

      - name: Build
        run: bash scripts/exmod.sh build latest -Tests

      - name: Test
        run: bash scripts/exmod.sh test latest
'@).Replace('VS_VERSION: "1.22"', "VS_VERSION: `"$vsVersionPin`"")) | Set-Content (Join-Path $ciDir 'tests.yml')

  ((@'
# Smoke lane, generated by `exmod starter`: boots the real Vintage Story dedicated server with
# hellomodule and helloexpanded and fails the job on any [Error]/[Fatal] line or a non-clean
# /exmod verify. See .github/workflows/tests.yml for the build and test lane.

name: Smoke

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  VS_VERSION: "1.22"

jobs:
  smoke:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: "10.0.x"

      - name: Cache Vintage Story install
        uses: actions/cache@v4
        with:
          path: .game
          key: vs-game-${{ env.VS_VERSION }}

      - name: Build the mods
        run: bash scripts/exmod.sh build latest

      # No -Mods needed: with none given, exmod smoke stages every mod exmod.json names plus their
      # resolved dependencies (exlib, fetched from its GitHub releases here - no workspace sibling
      # in CI).
      - name: Smoke-test the dedicated server boot
        run: bash scripts/exmod.sh smoke -Version "$VS_VERSION"
'@).Replace('VS_VERSION: "1.22"', "VS_VERSION: `"$vsVersionPin`"")) | Set-Content (Join-Path $ciDir 'smoke.yml')

  Copy-Item (Join-Path $exlibRoot '.gitattributes') (Join-Path $dest '.gitattributes') -Force
  Copy-Item (Join-Path $exlibRoot '.editorconfig') (Join-Path $dest '.editorconfig') -Force
  Copy-Item (Join-Path $exlibRoot '.csharpierrc') (Join-Path $dest '.csharpierrc') -Force
  Set-Content (Join-Path $dest 'LICENSE') $StarterLicense
  Set-Content (Join-Path $dest '.gitignore') $StarterGitignore
  ($StarterReadmeTemplate -f $repoName, $version, $repoName) | Set-Content (Join-Path $dest 'README.md')

  Push-Location $dest
  try {
    if ($isNewRepo) {
      git init -q -b main .
      if ($LASTEXITCODE -ne 0) { throw "git init failed in $dest." }
      git add -A
      if ($LASTEXITCODE -ne 0) { throw "git add failed in $dest." }
      git commit -q -m "Generated from exlib $version."
      if ($LASTEXITCODE -ne 0) { throw "git commit failed in $dest." }
      Write-Host "Generated a new repository at $dest and committed it."
    } else {
      $changed = @(git status --porcelain)
      if ($changed) {
        Write-Host "Regenerated $dest - changed:"
        $changed | ForEach-Object { Write-Host "  $_" }
      } else {
        Write-Host "Regenerated $dest - nothing changed."
      }
    }
  } finally {
    Pop-Location
  }
}

Add-ExmodCommand -Group start -Name starter -Summary 'generate the standalone starter repository' -Action {
  param([string[]]$Argv) Invoke-Starter $Argv
} -Detail @'
exmod starter <dest> [-ExlibRoot <path>] [-Version <exlib version>] [-Force]

Generates a standalone starter monorepo at <dest>: exlib's HelloModule and HelloExpanded samples
as two mods (mods/hellomodule, mods/helloexpanded), a solution, the launcher scripts, an
exmod.json naming them, a Directory.Packages.props pinned to -Version, CI and the repo dotfiles -
a repository that clones, restores from NuGet, builds, tests and smokes with nothing hand-edited.
The four mod/test csprojs and each mod's modinfo.json are generated from the samples' own files by
a text transform (never a hand-maintained template), so they cannot drift from what exlib's own
gate already proves; the solution, Directory.Packages.props, CI, the dotfiles and the README are
written by this command itself.

  -ExlibRoot   the exlib checkout to read from; defaults to the workspace sibling ../exlib
  -Version     the ExpandedLib package version to pin; defaults to the exlib checkout's own
               src/modinfo.json version
  -Force       generate into a non-empty <dest> that carries no marker of a previous starter run

<dest> is regenerated in place on a second run: every path this command owns is wiped and
rewritten, and every mod `exmod new` added since is carried forward into the fresh manifest and
solution. A re-run reports `git status --porcelain` in <dest>, which also lists the owner's own
unrelated edits, not only this command's. A fresh <dest> gets `git init` and one commit; an
existing one is left for the caller to review and commit. Refuses to generate into a path that is,
contains, or is contained by the checkout this command is run from, this tools checkout, or the
exlib checkout it reads from.
'@

#endregion

#region new

# Every mod scaffold's csproj: package-mode shape (a PackageReference, never a ProjectReference -
# `exmod new` never assumes a workspace sibling), $(AssetDomain) set so the package's own
# build/ExpandedLib.targets globs assets/<modid> and feeds ExLangKeyGenerator automatically, unlike
# the flat samples (see ConvertTo-StarterModCsproj) which hand-roll that glob for a layout with no
# src/ split.
$NewModCsproj = @'
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <CurrentGameTfm Condition="'$(CurrentGameTfm)' == ''">net10.0</CurrentGameTfm>
    <TargetFramework>$(CurrentGameTfm)</TargetFramework>
    <LangVersion>14</LangVersion>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <OutputPath>bin\$(Configuration)\Mods\mod</OutputPath>
    <Nullable>enable</Nullable>
    <AssemblyName>__MODID__</AssemblyName>
    <RootNamespace>__PASCAL__</RootNamespace>
    <AssetDomain>__MODID__</AssetDomain>
  </PropertyGroup>

  <ItemGroup>
    <Reference Include="VintagestoryAPI">
      <HintPath>$(GamePath)/VintagestoryAPI.dll</HintPath>
      <Private>false</Private>
    </Reference>
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="ExpandedLib" ExcludeAssets="runtime" />
  </ItemGroup>

  <ItemGroup>
    <Content Include="modinfo.json">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </Content>
    <Content Include="modicon.png" Condition="Exists('modicon.png')">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </Content>
  </ItemGroup>

</Project>
'@

$NewTestCsproj = @'
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <CurrentGameTfm Condition="'$(CurrentGameTfm)' == ''">net10.0</CurrentGameTfm>
    <TargetFramework>$(CurrentGameTfm)</TargetFramework>
    <LangVersion>14</LangVersion>
    <Nullable>enable</Nullable>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>

  <ItemGroup>
    <!-- Private=true: the vstest discoverer probes a test assembly's direct references on disk
         BEFORE the harness's assembly resolver can run, and a reference missing from the output
         folder makes discovery silently report zero tests rather than fail. -->
    <Reference Include="VintagestoryAPI">
      <HintPath>$(GamePath)/VintagestoryAPI.dll</HintPath>
      <Private>true</Private>
    </Reference>
    <Reference Include="VSSurvivalMod">
      <HintPath>$(GamePath)/Mods/VSSurvivalMod.dll</HintPath>
      <Private>true</Private>
    </Reference>
    <Reference Include="VSEssentials">
      <HintPath>$(GamePath)/Mods/VSEssentials.dll</HintPath>
      <Private>false</Private>
    </Reference>
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" />
    <PackageReference Include="xunit" />
    <PackageReference Include="xunit.runner.visualstudio" />
    <PackageReference Include="NSubstitute" />
    <PackageReference Include="ExpandedLib" />
    <PackageReference Include="ExpandedLib.Testing" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../src/__PASCAL__.csproj" />
  </ItemGroup>

</Project>
'@

# Fills __MODID__/__PASCAL__ tokens in a csproj template. Kept out of PowerShell's own string
# interpolation (single-quoted here-strings above) because the templates carry MSBuild's own
# "$(...)" syntax, which PowerShell double-quoting would try to evaluate as a subexpression.
function Expand-NewTemplate([string]$Template, [string]$ModId, [string]$PascalName) {
  return $Template.Replace('__MODID__', $ModId).Replace('__PASCAL__', $PascalName)
}

# Scaffolds mods/<modid> into the current repository (the one this checkout's exmod.json names)
# and adds it to that manifest: a package-mode csproj, modinfo.json, a lang skeleton and a test
# project wired to the harness with one smoke test. --module scaffolds a framework module instead -
# the [assembly: ExModule] + IExModule + empty ModSystem shape samples/HelloModule proves (see the
# wiki's Modules page).
function Invoke-New([string[]]$Argv) {
  $positional = @(Get-Positional $Argv @('-Name') @('--module'))
  if ($positional.Count -lt 1) { throw "exmod new needs a mod id." }
  $modId = $positional[0]
  if ($modId -notmatch '^[a-z][a-z0-9]*$') { throw "Mod id '$modId' must start with a lower-case letter and hold only lower-case letters and digits after that." }

  $manifestPath = Join-Path $RepoRoot 'exmod.json'
  if (-not (Test-Path $manifestPath)) { throw "No exmod.json under $RepoRoot." }
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.PSObject.Properties['mods'] -and $manifest.mods.PSObject.Properties[$modId]) {
    throw "Mod id '$modId' is already in exmod.json."
  }

  $isModule = Get-Flag $Argv '--module'
  $displayName = Get-Opt $Argv '-Name' $modId
  $pascalName = $modId.Substring(0, 1).ToUpperInvariant() + $modId.Substring(1)

  $packagesPropsPath = Join-Path $RepoRoot 'Directory.Packages.props'
  if (-not (Test-Path $packagesPropsPath)) { throw "No Directory.Packages.props under $RepoRoot to read the pinned exlib version from." }
  $exlibVersionMatch = [regex]::Match((Get-Content $packagesPropsPath -Raw), 'PackageVersion Include="ExpandedLib" Version="([^"]+)"')
  if (-not $exlibVersionMatch.Success) { throw "Directory.Packages.props names no ExpandedLib PackageVersion." }
  $exlibVersion = $exlibVersionMatch.Groups[1].Value

  $modDir = Join-Path $RepoRoot "mods/$modId"
  if (Test-Path $modDir) { throw "$modDir already exists." }
  $srcDir = Join-Path $modDir 'src'
  $langDir = Join-Path $modDir "assets/$modId/lang"
  $testsDir = Join-Path $modDir 'tests'
  New-Item -ItemType Directory -Force -Path $srcDir, $langDir, $testsDir | Out-Null

  $modCsprojPath = Join-Path $srcDir "$pascalName.csproj"
  $testCsprojPath = Join-Path $testsDir "$pascalName.Tests.csproj"
  Expand-NewTemplate $NewModCsproj $modId $pascalName | Set-Content $modCsprojPath
  Expand-NewTemplate $NewTestCsproj $modId $pascalName | Set-Content $testCsprojPath

  $displayNameJson = ConvertTo-JsonStringLiteral $displayName
  @"
{
  "`$schema": "https://moddbcdn.vintagestory.at/schema/modinfo.latest.json",
  "type": "Code",
  "modid": "$modId",
  "name": "$displayNameJson",
  "authors": [],
  "description": "",
  "version": "1.0.0",
  "dependencies": {
    "game": "1.22.0",
    "exlib": "$exlibVersion"
  }
}
"@ | Set-Content (Join-Path $srcDir 'modinfo.json')

  @"
{
  "$modId-name": "$displayNameJson"
}
"@ | Set-Content (Join-Path $langDir 'en.json')

  if ($isModule) {
    @"
using ExpandedLib.Registries;

// Own mod, own domain: this module ships as its own mod folder, so its classes and assets are
// keyed under its own id, not its host's.
[assembly: ExDomain("$modId")]

// A third-party-shaped module, hosted by exlib itself (the default Host on ExModuleAttribute).
[assembly: ExModule("$modId")]
"@ | Set-Content (Join-Path $srcDir 'AssemblyInfo.cs')

    @"
using Vintagestory.API.Common;

namespace $pascalName;

/// <summary>
/// The game's Code-mod loader refuses a dll with no <see cref="ModSystem"/> and no ModInfo
/// attribute at all, so this empty placeholder exists purely to satisfy that check - exlib's own
/// <c>ExModuleModSystem</c> is what actually drives <see cref="${pascalName}Module"/>.
/// </summary>
public class ${pascalName}ModSystem : ModSystem { }
"@ | Set-Content (Join-Path $srcDir "${pascalName}ModSystem.cs")

    @"
using ExpandedLib.Registries;

namespace $pascalName;

/// <summary>
/// Entry point for this module. exlib's <c>ExModuleModSystem</c> discovers this class through the
/// assembly's <c>[assembly: ExModule]</c> and drives it through the same phases a
/// <see cref="Vintagestory.API.Common.ModSystem"/> would get.
/// </summary>
public sealed class ${pascalName}Module : IExModule { }
"@ | Set-Content (Join-Path $srcDir "${pascalName}Module.cs")

    @"
using System.Runtime.CompilerServices;
using ExpandedLib.Testing;

namespace $pascalName.Tests;

/// <summary>
/// Registers the Vintage Story assembly resolver before any test type is touched by the runner's
/// reflection-based discovery, and touches <see cref="${pascalName}Module"/> so its
/// <c>[assembly: ExModule]</c> is loaded before <c>ExModules</c> discovery runs.
/// </summary>
internal static class ModuleInit {
  [ModuleInitializer]
  internal static void Init() {
    VsAssemblyResolver.Register();
    TestLang.Init();
    _ = typeof(global::$pascalName.${pascalName}Module);
  }
}
"@ | Set-Content (Join-Path $testsDir 'ModuleInit.cs')

    @"
using Xunit;

namespace $pascalName.Tests;

/// <summary>Proves the assembly loads and its module entry point exists, before any real coverage
/// is written.</summary>
public class ${pascalName}SmokeTests {
  [Fact]
  public void Module_entry_point_exists() {
    Assert.NotNull(typeof($pascalName.${pascalName}Module));
  }
}
"@ | Set-Content (Join-Path $testsDir "${pascalName}SmokeTests.cs")
  } else {
    @"
using ExpandedLib.Registries;

[assembly: ExDomain("$modId")]
"@ | Set-Content (Join-Path $srcDir 'AssemblyInfo.cs')

    @"
using ExpandedLib.Registries;

namespace $pascalName;

/// <summary>
/// The whole registration walk: <see cref="ExModSystem"/> loads this assembly's config, registers
/// every attribute-marked class and code-first definition, and wires each command on each side -
/// all with nothing to write here.
/// </summary>
public class ${pascalName}ModSystem : ExModSystem { }
"@ | Set-Content (Join-Path $srcDir "${pascalName}ModSystem.cs")

    @"
using System.Runtime.CompilerServices;
using ExpandedLib.Testing;

namespace $pascalName.Tests;

/// <summary>
/// Registers the Vintage Story assembly resolver before any test type is touched by the runner's
/// reflection-based discovery.
/// </summary>
internal static class ModuleInit {
  [ModuleInitializer]
  internal static void Init() {
    VsAssemblyResolver.Register();
    TestLang.Init();
  }
}
"@ | Set-Content (Join-Path $testsDir 'ModuleInit.cs')

    @"
using Xunit;

namespace $pascalName.Tests;

/// <summary>Proves the assembly loads and its mod system type exists, before any real coverage is
/// written.</summary>
public class ${pascalName}SmokeTests {
  [Fact]
  public void Mod_system_type_exists() {
    Assert.NotNull(typeof($pascalName.${pascalName}ModSystem));
  }
}
"@ | Set-Content (Join-Path $testsDir "${pascalName}SmokeTests.cs")
  }

  if (-not $manifest.PSObject.Properties['mods']) {
    $manifest | Add-Member -NotePropertyName mods -NotePropertyValue ([pscustomobject]@{})
  }
  $manifest.mods | Add-Member -NotePropertyName $modId -NotePropertyValue ([pscustomobject]@{ path = "mods/$modId" })

  # Added to the solution when this repository names one (exmod.json's own 'solution', or a single
  # .sln at its root) - a repository with neither (this tools checkout itself, for instance) is left
  # to add the project by hand.
  $slnPath = $null
  if ($manifest.PSObject.Properties['solution'] -and $manifest.solution) {
    $slnPath = Join-Path $RepoRoot $manifest.solution
  } else {
    $slns = @(Get-ChildItem $RepoRoot -Filter '*.sln' -File)
    if ($slns.Count -eq 1) { $slnPath = $slns[0].FullName }
  }
  if ($slnPath -and (Test-Path $slnPath)) {
    foreach ($proj in @($modCsprojPath, $testCsprojPath)) {
      dotnet sln $slnPath add $proj | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "dotnet sln add $proj failed." }
    }
  }

  Write-ExmodManifest $manifest $manifestPath

  Write-Host "Scaffolded mods/$modId$(if ($isModule) { ' (module)' }) and added it to exmod.json."
}

Add-ExmodCommand -Group start -Name new -Summary 'scaffold an empty mod into this repository' -Action {
  param([string[]]$Argv) Invoke-New $Argv
} -Detail @'
exmod new <modid> [-Name <display name>] [--module]

Scaffolds mods/<modid> into this repository (the one exmod.json names) and adds it there: a
package-mode csproj (TargetFramework net10.0, AssetDomain <modid>), modinfo.json (game 1.22.0 and
exlib pinned to Directory.Packages.props's own ExpandedLib version), assets/<modid>/lang/en.json,
and mods/<modid>/tests wired to the harness with one smoke test that the mod system's type exists.
Also added to the solution when this repository names one (exmod.json's own 'solution', or a
single .sln at its root).

Needs a root Directory.Packages.props carrying an ExpandedLib PackageVersion - every generated
PackageReference is versionless, package mode only, the shape `exmod setup` produces.

  -Name      the mod's display name (modinfo.json's "name", and the lang file's), defaults to
             <modid>
  --module   scaffold a framework module instead: [assembly: ExModule("<modid>")], an IExModule
             entry point and the empty ModSystem the engine's Code-mod loader requires (see the
             wiki's Modules page and samples/HelloModule)

<modid> must start with a lower-case letter, hold only lower-case letters and digits after that,
and not already name a mod in exmod.json.
'@

#endregion
