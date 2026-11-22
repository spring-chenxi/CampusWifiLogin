@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CAMPUS_WIFI_LOGIN_SOURCE=%~dp0CampusWifiLogin.ps1"
set "CAMPUS_WIFI_LOGIN_DESTINATION=%LOCALAPPDATA%\CampusWifiLogin\CampusWifiLogin.ps1"
set "wifiPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%CAMPUS_WIFI_LOGIN_SOURCE%" (
    echo CampusWifiLogin.ps1 was not found. Extract the whole ZIP and try again.
    goto failed
)

"%wifiPowerShell%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -Command "$ErrorActionPreference = 'Stop'; $source = $env:CAMPUS_WIFI_LOGIN_SOURCE; $destination = $env:CAMPUS_WIFI_LOGIN_DESTINATION; $downloaded = Get-Item -LiteralPath $source -Stream Zone.Identifier -ErrorAction SilentlyContinue; if ($downloaded) { $answer = Read-Host 'Trust this downloaded script and install it? [y/N]'; if ($answer -ne 'y') { exit 2 } }; if ($source -ne $destination) { New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null; Copy-Item -LiteralPath $source -Destination $destination -Force }; if ($downloaded) { Unblock-File -LiteralPath $destination }"
if errorlevel 2 goto canceled
if errorlevel 1 goto failed

"%wifiPowerShell%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%CAMPUS_WIFI_LOGIN_DESTINATION%" -Mode Setup -Ssid "CMCC-EDU"
if errorlevel 1 goto failed

"%wifiPowerShell%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%CAMPUS_WIFI_LOGIN_DESTINATION%" -Mode Install
if errorlevel 1 goto failed

echo.
echo Setup complete. Trying to connect to CMCC-EDU now...
"%wifiPowerShell%" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%CAMPUS_WIFI_LOGIN_DESTINATION%" -Mode Run
if errorlevel 1 goto failed
echo.
pause
exit /b 0

:canceled
echo Installation canceled.
pause
exit /b 2

:failed
echo.
echo See the message above for the step that failed.
pause
exit /b 1
