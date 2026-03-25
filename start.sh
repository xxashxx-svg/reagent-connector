#!/bin/bash
echo ""
echo "  Reagent Connector"
echo ""
if [ ! -d "node_modules" ]; then
    echo "  Installing dependencies..."
    npm install --silent
    echo ""
fi
node server.js "$@"
