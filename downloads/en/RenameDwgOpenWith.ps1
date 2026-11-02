<#
.SYNOPSIS
    Gives the AutoCAD entries of the .dwg "Open with" submenu a name that states their version ("AutoCAD 2025").

.DESCRIPTION
    When the ProgID provides no name, File Explorer shows the executable's description ("AutoCAD Application",
    the same for every version, cached in MuiCache). This script writes the FriendlyAppName value on the
    shell\open key of every ProgID listed in .dwg\OpenWithprogids that points to an installed AutoCAD; the
    name is taken from the installation folder ("AutoCAD 2025").

    Writes to HKCU only (no administrator rights) and only adds one value: the open command, the default
    association and ProgIDs whose name cannot be derived from an "AutoCAD YYYY" folder are left untouched.

    Simulates by default. -Apply first exports each shell\open key to a .reg file, writes the names,
    notifies File Explorer and measures again. -Undo removes the names set by this script.

    Source: https://wiip.fr/en/blog/autocad-open-with-versions

.PARAMETER Apply
    Writes the names. Without this switch, the script only shows what it would write.

.PARAMETER Undo
    Removes the FriendlyAppName values set by this script (those whose value is the name it computes).

.PARAMETER IncludeTrueView
    Also renames DWG TrueView ("DWG TrueView 2024").

.PARAMETER BackupDirectory
    Folder for the .reg backups. Defaults to a "Backups" folder next to the script.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\RenameDwgOpenWith.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\RenameDwgOpenWith.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Undo,
    [switch]$IncludeTrueView,
    [string]$BackupDirectory
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not know $PSScriptRoot yet when it evaluates default values.
if ([string]::IsNullOrWhiteSpace($BackupDirectory))
    { $BackupDirectory = Join-Path $PSScriptRoot 'Backups' }

if ($Apply -and $Undo)
    { throw '-Apply and -Undo cannot be used together.' }

$EXTENSION = '.dwg'
$PROGIDS_KEY = "HKCU:\Software\Classes\$EXTENSION\OpenWithprogids"
$VALUE_NAME = 'FriendlyAppName'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DwgOpenWithShell
{
    [ComImport, Guid("F04061AC-1659-4a3f-A954-775AA57FC083"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAssocHandler
    {
        void GetName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetUIName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    }

    [ComImport, Guid("973810ae-9599-4b88-9e4d-6ee98c9552da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IEnumAssocHandlers
    {
        [PreserveSig] int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out IAssocHandler handler, out uint fetched);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHAssocEnumHandlers(string extension, int filter, out IEnumAssocHandlers enumerator);

    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    const int ASSOC_FILTER_RECOMMENDED = 1;
    const int SHCNE_ASSOCCHANGED = 0x08000000;

    // Entries of the "Open with" submenu: displayed name, or null when the handler cannot be read.
    public static List<string> ReadRecommendedHandlers(string extension)
    {
        var result = new List<string>();
        IEnumAssocHandlers enumerator;
        SHAssocEnumHandlers(extension, ASSOC_FILTER_RECOMMENDED, out enumerator);
        IAssocHandler handler;
        uint fetched;
        while (enumerator.Next(1, out handler, out fetched) == 0 && fetched == 1)
        {
            string uiName;
            string name;
            try
            {
                handler.GetUIName(out uiName);
                handler.GetName(out name);
                result.Add(uiName + " | " + name);
            }
            catch (COMException)
            {
                result.Add(null);
            }
            Marshal.ReleaseComObject(handler);
        }
        Marshal.ReleaseComObject(enumerator);
        return result;
    }

    public static void NotifyAssociationsChanged()
    {
        SHChangeNotify(SHCNE_ASSOCCHANGED, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@

function Write-OpenWithMeasure {
    param([string]$Label)

    $handlers = [DwgOpenWithShell]::ReadRecommendedHandlers($EXTENSION)
    $unreadable = @($handlers | Where-Object { $null -eq $_ }).Count
    Write-Host "== $Label : $($handlers.Count) entries in ""Open with"" ($unreadable unreadable)" -ForegroundColor Cyan
    foreach ($handler in $handlers | Where-Object { $null -ne $_ })
        { Write-Host "   $handler" }
}

function Get-ProgIdExecutable {
    param([string]$ProgId)

    $command = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$ProgId\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
    if ([string]::IsNullOrWhiteSpace($command))
        { return $null }
    if ($command -match '^\s*"([^"]+)"')
        { return [Environment]::ExpandEnvironmentVariables($Matches[1]) }
    else
        { return [Environment]::ExpandEnvironmentVariables(($command.Trim() -split '\s+')[0]) }
}

# Name derived from the installation folder, or $null when the ProgID is not to be renamed.
function Get-TargetName {
    param([string]$Executable)

    if ($Executable -match '\\AutoCAD (\d{4})\\acad\.exe$')
        { return "AutoCAD $($Matches[1])" }
    elseif ($IncludeTrueView -and $Executable -match '\\DWG TrueView (\d{4})[^\\]*\\dwgviewr\.exe$')
        { return "DWG TrueView $($Matches[1])" }
    else
        { return $null }
}

$targets = foreach ($progId in (Get-Item -LiteralPath $PROGIDS_KEY).Property) {
    $executable = Get-ProgIdExecutable -ProgId $progId
    if ($null -eq $executable -or -not (Test-Path -LiteralPath $executable))
        { continue }
    $name = Get-TargetName -Executable $executable
    if ($null -eq $name)
        { continue }
    $openKey = "HKCU:\Software\Classes\$progId\shell\open"
    if (-not (Test-Path -LiteralPath $openKey)) {
        Write-Warning "$progId has no shell\open key in HKCU (machine-wide ProgID): skipped, it would require administrator rights."
        continue
    }
    $current = (Get-ItemProperty -LiteralPath $openKey).$VALUE_NAME
    [pscustomobject]@{ ProgId = $progId; Current = $current; Target = $name; Executable = $executable; OpenKey = $openKey }
}

Write-OpenWithMeasure -Label 'Before'

if ($Undo) {
    $undoTargets = @($targets | Where-Object { $_.Current -eq $_.Target })
    Write-Host "`n== $($undoTargets.Count) names to remove" -ForegroundColor Yellow
    $undoTargets | Select-Object ProgId, Current, Executable | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    foreach ($target in $undoTargets)
        { Remove-ItemProperty -LiteralPath $target.OpenKey -Name $VALUE_NAME }
    [DwgOpenWithShell]::NotifyAssociationsChanged()
    Write-OpenWithMeasure -Label 'After'
    return
}

$changes = @($targets | Where-Object { $_.Current -ne $_.Target })
Write-Host "`n== $($changes.Count) ProgIDs to rename ($VALUE_NAME on shell\open)" -ForegroundColor Yellow
$changes | Select-Object ProgId, Current, Target, Executable | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

if (-not $Apply) {
    Write-Host 'Simulation: nothing has been changed. Run again with -Apply to apply.' -ForegroundColor Green
    return
}

# .reg backups before any write: one per shell\open key.
New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
$timestamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
foreach ($change in $changes) {
    $path = Join-Path $BackupDirectory "$timestamp - $($change.ProgId) shell open.reg"
    & reg.exe export "HKCU\Software\Classes\$($change.ProgId)\shell\open" $path /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $path))
        { throw "Backup of $($change.ProgId) failed: no name has been written." }
    else
        { Write-Host "Backup: $path" }
}

foreach ($change in $changes)
    { Set-ItemProperty -LiteralPath $change.OpenKey -Name $VALUE_NAME -Value $change.Target -Type String }

[DwgOpenWithShell]::NotifyAssociationsChanged()
Write-Host "`n$($changes.Count) names written." -ForegroundColor Green
Write-OpenWithMeasure -Label 'After'
