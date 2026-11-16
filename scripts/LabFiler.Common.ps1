# Helpers shared by the lab filer scripts. Load with:
#   . (Join-Path $PSScriptRoot 'LabFiler.Common.ps1')

# Turns a path from the config into a full path.
# Relative paths are taken as relative to the folder that holds the config file.
function Resolve-ConfigPath {
    param(
        [string]$BaseDir,
        [string]$Value
    )
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }
    return Join-Path $BaseDir $Value
}
