@echo off
chcp 65001 >nul
title T-City Lite Server
echo ========================================
echo   T-City Lite 开发服务器
echo   当前分支: v0.5-crime
echo ========================================
echo.
D:\server\FXServer.exe +set txAdminPort 0 +exec T-CityLite.base/server.cfg
pause
