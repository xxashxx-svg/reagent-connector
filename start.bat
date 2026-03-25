@echo off
title Reagent Connector
echo.
echo   Reagent Connector
echo.
if not exist node_modules (
    echo   Installing dependencies...
    npm install --silent
    echo.
)
node server.js %*
pause
