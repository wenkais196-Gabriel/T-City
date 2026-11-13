@echo off
chcp 65001 >nul
REM T-City one-click launcher (Windows). Logic lives in start-tcity.ps1.
REM   start.cmd            start everything (Docker engine -> MariaDB -> FXServer -> self-check)
REM   start.cmd -Status    status only
REM   start.cmd -Restart   graceful stop, then start
REM   start.cmd -Stop      stop FXServer only
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-tcity.ps1" %*
exit /b %ERRORLEVEL%
