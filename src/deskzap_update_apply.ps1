# Deskzap Host self-update helper. Runs as a one-shot SYSTEM scheduled task,
# independent of the service it replaces. Placeholders are filled in by
# src/deskzap_update.rs. Never leaves a half-updated install: any failure
# restores the backup and restarts the previous service.
$ErrorActionPreference = 'Stop'
$InstallDir = '__INSTALL_DIR__'
$Installer = '__INSTALLER__'
$ResultFile = '__RESULT_FILE__'
$TaskName = '__TASK_NAME__'
$Version = '__VERSION__'
$Service = 'Deskzap Host'
$Backup = "$InstallDir.update-backup"
$ProfileName = 'deskzap-profile.json'
$Log = Join-Path (Split-Path $ResultFile) 'apply-update.log'

function Say($msg) { Add-Content -Path $Log -Value "$([DateTime]::UtcNow.ToString('o')) $msg" }

function Stop-Host {
  Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue
  (Get-Service -Name $Service).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
  # The service's --server / tray processes hold the binaries open.
  Get-Process -Name 'deskzap-host' -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
}

function Start-Host {
  Start-Service -Name $Service
  (Get-Service -Name $Service).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
  # Still running after a short settle = it didn't crash on start.
  Start-Sleep -Seconds 20
  if ((Get-Service -Name $Service).Status -ne 'Running') { throw "service stopped after start" }
}

try {
  Say "update to $Version starting (install dir $InstallDir)"
  Stop-Host
  if (Test-Path $Backup) { Remove-Item -Recurse -Force $Backup }
  Copy-Item -Recurse -Force $InstallDir $Backup
  Say "backup taken"

  try {
    $p = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "installer exited with $($p.ExitCode)" }
    if (-not (Test-Path (Join-Path $InstallDir 'deskzap-host.exe'))) { throw "installer left no deskzap-host.exe" }
    # The installer writes the generic profile; keep this device's org
    # profile(s), wherever they sit under the install folder.
    Get-ChildItem -Path $Backup -Recurse -Filter $ProfileName -File | ForEach-Object {
      $target = Join-Path $InstallDir $_.FullName.Substring($Backup.Length).TrimStart([char]92)
      New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
      Copy-Item -Force $_.FullName $target
    }
    Say "installed; starting service"
    Start-Host
    Say "update to $Version applied"
    Remove-Item -Recurse -Force $Backup -ErrorAction SilentlyContinue
  } catch {
    $reason = "update to $Version failed: $($_.Exception.Message); rolled back"
    Say $reason
    Stop-Host
    robocopy $Backup $InstallDir /MIR /R:3 /W:2 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { $reason += " (rollback copy reported $LASTEXITCODE)" }
    Start-Service -Name $Service -ErrorAction SilentlyContinue
    Set-Content -Path $ResultFile -Value $reason
  }
} catch {
  # Failed before anything was replaced: make sure the old service is running.
  $reason = "update to $Version failed before install: $($_.Exception.Message)"
  Say $reason
  Start-Service -Name $Service -ErrorAction SilentlyContinue
  Set-Content -Path $ResultFile -Value $reason
} finally {
  Remove-Item -Force $Installer -ErrorAction SilentlyContinue
  schtasks /Delete /TN $TaskName /F | Out-Null
}
