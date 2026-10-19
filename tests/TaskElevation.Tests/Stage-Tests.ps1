param([ValidateSet('Install', 'Update', 'Cleanup')][string] $Mode)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$destination = (Get-Content "$root/obj/install-path.txt" -Raw).Trim()
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
if ([IO.Path]::GetDirectoryName($destination) -ne $programFiles -or
    [IO.Path]::GetFileName($destination) -notmatch '^SevenKeyboard\.TaskElevation\.Tests\.[0-9a-f]{32}$') { throw 'Invalid destination.' }
if ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne (Get-Content "$root/obj/owner-sid.txt" -Raw).Trim()) { throw 'Elevation changed user; abort.' }
Start-Transcript "$root/obj/admin-$Mode.log" -Force
function Run-Test([string] $exe, [string] $mode) {
    & $exe $mode
    if ($LASTEXITCODE) { throw "Test failed: $mode $exe" }
}
try {
    if ($Mode -in @('Install','Update')) {
        if ($Mode -eq 'Install' -and (Test-Path -LiteralPath $destination)) { throw 'Destination already exists.' }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        foreach ($flavor in @('jit', 'aot')) {
            New-Item -ItemType Directory -Path "$destination/$flavor" -Force | Out-Null
            Copy-Item "$root/bin/$flavor/*" "$destination/$flavor" -Recurse -Force
            $workingDirectory = Join-Path "$destination/$flavor" 'literal $(Arg0) $$ dollar$'
            New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
            $exe = "$destination/$flavor/TaskElevation.Tests.exe"
            Run-Test $exe '--register'
            $taskPath = (& $exe --path).Trim()
            if ($LASTEXITCODE) { throw 'Task path query failed.' }
            $scheduler = New-Object -ComObject 'Schedule.Service'
            $scheduler.Connect()
            $folderPath = '\' + [IO.Path]::GetDirectoryName($taskPath)
            $taskName = [IO.Path]::GetFileName($taskPath)
            $folder = $scheduler.GetFolder($folderPath)
            $original = $folder.GetTask($taskName).Xml
            if ($folder.GetTask($taskName).Definition.Actions.Item(1).WorkingDirectory -cne $workingDirectory.Replace('$', '$$')) {
                throw 'Task working directory was not escaped for scheduler substitution.'
            }
            # An unsupported argument protocol must not be adopted.
            $legacy = $original.Replace('--byscheduler --task-elevation-v1 $(Arg0)', '--byscheduler')
            $null = $folder.RegisterTask($taskName, $legacy, 6, [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, $null, 3, $null)
            try {
                Run-Test $exe '--incompatible'
                Run-Test $exe '--conflict'
                if ($folder.GetTask($taskName).Definition.Actions.Item(1).Arguments -ne '--byscheduler') { throw 'Legacy definition overwritten.' }
            } finally {
                $null = $folder.RegisterTask($taskName, $original, 6, [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, $null, 3, $null)
            }
            # Unrelated action under the same name must not be overwritten.
            $conflict = $original.Replace('--byscheduler --task-elevation-v1 $(Arg0)', '--unrelated')
            $null = $folder.RegisterTask($taskName, $conflict, 6, [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, $null, 3, $null)
            try {
                Run-Test $exe '--incompatible'
                Run-Test $exe '--conflict'
                if ($folder.GetTask($taskName).Definition.Actions.Item(1).Arguments -ne '--unrelated') { throw 'Conflict overwritten.' }
            } finally {
                $null = $folder.RegisterTask($taskName, $original, 6, [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, $null, 3, $null)
            }
            # Disabled tasks must not qualify for relaunch.
            $task = $folder.GetTask($taskName)
            $task.Enabled = $false
            try { Run-Test $exe '--incompatible' } finally { $task.Enabled = $true }
        }
    }
    if ($Mode -eq 'Cleanup') {
        foreach ($flavor in @('jit','aot')) {
            Run-Test "$destination/$flavor/TaskElevation.Tests.exe" '--delete'
        }
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $folderMissing = $false
        try { $null = $scheduler.GetFolder('\' + [IO.Path]::GetFileName($destination)) }
        catch {
            if ($_.Exception.HResult -notin @(-2147024894, -2147024893)) { throw }
            $folderMissing = $true
        }
        if (!$folderMissing) { throw 'Test scheduler folder still exists.' }
        if ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected reparse point.' }
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
} finally { Stop-Transcript }
