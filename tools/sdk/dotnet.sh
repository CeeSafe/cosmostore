#!/bin/sh
# The AWS SDK for .NET against `cosmostore serve` (M3 SDK matrix): tools/sdk/dotnet/Program.cs, then fsck.
# usage: [NUGET_PACKAGES=<package cache>] tools/sdk/dotnet.sh    (needs the .NET 10 SDK; AWSSDK.S3 comes from NuGet)
. "$(dirname "$0")/common.sh"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
dotnet run --project "$(cd "$(dirname "$0")/dotnet" && pwd)/Check.csproj" -c Release || failed=1
check "no extents left" "$(ls "$work/store/extents" | wc -l | tr -d ' ')" 0
finish "dotnet"
