@echo off
title Reagent Connector
echo.
echo   Reagent Connector
echo.
if not exist node_modules (
    echo   Installing dependencies...
    call npm install --silent
    echo.
    echo   Dependencies installed!
    echo.
)
node server.js %*
pause
