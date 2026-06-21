@echo off
title T-City Lite - txAdmin

echo ============================================
echo   T-City Lite - txAdmin v8.0.1
echo   Port: 40120
echo ============================================
echo.

set TXHOST_TXA_PORT=40120
set TXHOST_DATA_PATH=%~dp0T-CityLite.base\txData

cd /d D:\server
echo [Info] FXServer dir: D:\server
echo [Info] Server data: %~dp0T-CityLite.base
echo [Info] Web panel: http://localhost:40120/
echo.

echo Auto-opening txAdmin web panel...
where msedge >nul 2>&1
if not errorlevel 1 (
    start msedge --new-window http://localhost:40120/
) else (
    start http://localhost:40120/
)

FXServer.exe +set citizen_dir citizen +set monitorMode true

echo.
echo Closing txAdmin browser tab...
taskkill /fi "WINDOWTITLE eq localhost:40120*" 2>nul

echo [Done] txAdmin stopped.
