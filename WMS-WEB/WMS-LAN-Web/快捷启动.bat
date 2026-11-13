@echo off
cd /d "%~dp0"
title WMS LAN Web Service
echo.
echo WMS LAN Web service starting...
echo Project folder: %CD%
echo.
echo Use this PC: http://127.0.0.1:8000
echo Use LAN: http://YOUR-PC-IP:8000
echo Browser will NOT be opened automatically.
echo Keep this window open. Press Ctrl+C to stop.
echo.
if not exist ".venv\Scripts\python.exe" (
  echo ERROR: .venv\Scripts\python.exe not found in this folder.
  echo Please put this BAT file in the same folder as web_app.py and .venv.
  pause
  exit /b 1
)
if not exist "web_app.py" (
  echo ERROR: web_app.py not found in %CD%
  pause
  exit /b 1
)
".venv\Scripts\python.exe" -m uvicorn web_app:app --host 0.0.0.0 --port 8000 --workers 1
echo.
echo Service stopped or failed to start. Check the error above.
pause
