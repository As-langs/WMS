@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title WMS LAN Web - Startup
set "LOG=%~dp0startup.log"

echo ==================================================
echo WMS LAN Web startup
echo Folder: %CD%
echo Log: %LOG%
echo ==================================================
echo [%date% %time%] Startup > "%LOG%"

REM Create local config first, so first-run behavior is visible and predictable.
if not exist "wms_config.json" (
  echo [INFO] Creating wms_config.json from template...
  copy /y "wms_config.example.json" "wms_config.json" >> "%LOG%" 2>&1
  if errorlevel 1 goto :error
  echo.
  echo Created wms_config.json. Please enter your real WMS username/password.
  echo Opening Notepad now. Save and close it, then run this file again.
  notepad "wms_config.json"
  echo.
  echo Config step finished. Run start_web.bat again after saving the config.
  pause
  exit /b 0
)

where py >nul 2>&1
if not errorlevel 1 (
  set "PY=py -3"
  goto :python_found
)
where python >nul 2>&1
if not errorlevel 1 (
  set "PY=python"
  goto :python_found
)
echo [ERROR] Python was not found. Install Python 3.10+ and enable PATH.
echo [ERROR] Python was not found. >> "%LOG%"
goto :error

:python_found
echo [INFO] Checking Python...
%PY% --version >> "%LOG%" 2>&1
if errorlevel 1 goto :error

if not exist ".venv\Scripts\python.exe" (
  echo [INFO] Creating virtual environment...
  %PY% -m venv .venv >> "%LOG%" 2>&1
  if errorlevel 1 goto :error
)

echo [INFO] Installing/checking dependencies. This may take several minutes...
".venv\Scripts\python.exe" -m pip install --upgrade pip >> "%LOG%" 2>&1
if errorlevel 1 goto :error
".venv\Scripts\python.exe" -m pip install -r requirements.txt >> "%LOG%" 2>&1
if errorlevel 1 goto :error

echo [INFO] Checking application imports...
".venv\Scripts\python.exe" -c "import fastapi, uvicorn, requests; print('Dependencies OK')" >> "%LOG%" 2>&1
if errorlevel 1 goto :error
".venv\Scripts\python.exe" -m py_compile web_app.py wms_integrated.py >> "%LOG%" 2>&1
if errorlevel 1 goto :error

echo.
echo [INFO] Starting server at http://0.0.0.0:8000
echo On this PC open: http://127.0.0.1:8000
echo Web password will be shown on first server start and saved in web_access.txt.
echo Keep this window open while using the web app.
echo.
".venv\Scripts\python.exe" -m uvicorn web_app:app --host 0.0.0.0 --port 8000 --workers 1 >> "%LOG%" 2>&1
echo.
echo [INFO] Server stopped. Details are in startup.log
type "%LOG%"
pause
exit /b 0

:error
echo.
echo [ERROR] Startup failed. Details below and in startup.log:
echo --------------------------------------------------
type "%LOG%"
echo --------------------------------------------------
echo Please send the contents of startup.log for diagnosis.
pause
exit /b 1
