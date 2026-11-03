#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
ce_source="${PCL_CE_SOURCE:-$project_dir/../PCL-CE}"
dotnet_bin="${PCL_CE_DOTNET:-$project_dir/.build/ce-interop/dotnet/dotnet}"
if [[ ! -x "$dotnet_bin" || ! -f "$ce_source/PCL.Core/Link/Scaffolding/LobbyCodeGenerator.cs" ]]; then
  print -u2 'Provide PCL_CE_DOTNET (.NET 10 SDK executable) and PCL_CE_SOURCE (CE source root).'
  exit 2
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
"$dotnet_bin" build Support/Multiplayer/CEInterop/CEInterop.csproj \
  -o .build/ce-interop/bin -p:CESource="$ce_source" \
  -p:BaseIntermediateOutputPath="$project_dir/.build/ce-interop/obj/" --disable-build-servers
export PCL_CE_DOTNET="$dotnet_bin"
export PCL_CE_INTEROP_DLL="$project_dir/.build/ce-interop/bin/CEInterop.dll"
swift test --filter 'CESourceInteropTests|CETransportInteropTests'
