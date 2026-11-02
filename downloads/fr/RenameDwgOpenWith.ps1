<#
.SYNOPSIS
    Donne aux AutoCAD du sous-menu « Ouvrir avec » des .dwg un nom qui dit leur version (« AutoCAD 2025 »).

.DESCRIPTION
    L'Explorateur affiche la description de l'exécutable (« AutoCAD Application », identique pour toutes les
    versions, mise en cache dans MuiCache) faute de nom fourni par le ProgID. Ce script écrit la valeur
    FriendlyAppName sur la clé shell\open de chaque ProgID de .dwg\OpenWithprogids qui pointe vers un
    AutoCAD installé ; le nom est tiré du dossier d'installation (« AutoCAD 2025 »).

    N'écrit que dans HKCU (aucun droit d'administrateur) et n'ajoute qu'une valeur : la commande
    d'ouverture, l'association par défaut et les ProgID dont le nom n'est pas tiré d'un dossier
    « AutoCAD AAAA » restent tels quels.

    Simule par défaut. -Apply exporte d'abord chaque clé shell\open en .reg, écrit les noms, prévient
    l'Explorateur et refait la mesure. -Undo retire les noms posés par ce script.

    Source : https://wiip.fr/fr/blog/autocad-ouvrir-avec-versions

.PARAMETER Apply
    Écrit les noms. Sans ce commutateur, le script affiche seulement ce qu'il écrirait.

.PARAMETER Undo
    Retire les FriendlyAppName que ce script a posés (ceux dont la valeur est le nom qu'il calcule).

.PARAMETER IncludeTrueView
    Renomme aussi DWG TrueView (« DWG TrueView 2024 »).

.PARAMETER BackupDirectory
    Dossier des sauvegardes .reg. Par défaut, un dossier « Sauvegardes » à côté du script.

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

# Windows PowerShell 5.1 ne connaît pas encore $PSScriptRoot quand il évalue les valeurs par défaut.
if ([string]::IsNullOrWhiteSpace($BackupDirectory))
    { $BackupDirectory = Join-Path $PSScriptRoot 'Sauvegardes' }

if ($Apply -and $Undo)
    { throw '-Apply et -Undo sont exclusifs.' }

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

    // Entrées du sous-menu « Ouvrir avec » : nom affiché, ou null quand le gestionnaire est illisible.
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
    Write-Host "== $Label : $($handlers.Count) entrées dans « Ouvrir avec » ($unreadable illisibles)" -ForegroundColor Cyan
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

# Nom tiré du dossier d'installation, ou $null quand le ProgID n'est pas à renommer.
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
        Write-Warning "$progId n'a pas de clé shell\open dans HKCU (ProgID machine) : ignoré, il faudrait l'administrateur."
        continue
    }
    $current = (Get-ItemProperty -LiteralPath $openKey).$VALUE_NAME
    [pscustomobject]@{ ProgId = $progId; Current = $current; Target = $name; Executable = $executable; OpenKey = $openKey }
}

Write-OpenWithMeasure -Label 'Avant'

if ($Undo) {
    $undoTargets = @($targets | Where-Object { $_.Current -eq $_.Target })
    Write-Host "`n== $($undoTargets.Count) noms à retirer" -ForegroundColor Yellow
    $undoTargets | Select-Object ProgId, Current, Executable | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    foreach ($target in $undoTargets)
        { Remove-ItemProperty -LiteralPath $target.OpenKey -Name $VALUE_NAME }
    [DwgOpenWithShell]::NotifyAssociationsChanged()
    Write-OpenWithMeasure -Label 'Après'
    return
}

$changes = @($targets | Where-Object { $_.Current -ne $_.Target })
Write-Host "`n== $($changes.Count) ProgID à renommer ($VALUE_NAME sur shell\open)" -ForegroundColor Yellow
$changes | Select-Object ProgId, Current, Target, Executable | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

if (-not $Apply) {
    Write-Host 'Simulation : rien n''a été modifié. Relancez avec -Apply pour appliquer.' -ForegroundColor Green
    return
}

# Sauvegardes .reg avant toute écriture : une par clé shell\open.
New-Item -ItemType Directory -Force -Path $BackupDirectory | Out-Null
$timestamp = Get-Date -Format 'yyyy-MM-dd HHmmss'
foreach ($change in $changes) {
    $path = Join-Path $BackupDirectory "$timestamp - $($change.ProgId) shell open.reg"
    & reg.exe export "HKCU\Software\Classes\$($change.ProgId)\shell\open" $path /y | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $path))
        { throw "La sauvegarde de $($change.ProgId) a échoué : aucun nom n'a été écrit." }
    else
        { Write-Host "Sauvegarde : $path" }
}

foreach ($change in $changes)
    { Set-ItemProperty -LiteralPath $change.OpenKey -Name $VALUE_NAME -Value $change.Target -Type String }

[DwgOpenWithShell]::NotifyAssociationsChanged()
Write-Host "`n$($changes.Count) noms écrits." -ForegroundColor Green
Write-OpenWithMeasure -Label 'Après'
