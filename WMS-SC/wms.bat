REM 优先使用当前文件夹里的 python.exe（截图中已有这个文件），不依赖 PATH。
set "PYTHON_EXE="
if exist "%~dp0python.exe" set "PYTHON_EXE=%~dp0python.exe"

REM 如果当前目录没有 python.exe，再尝试 Windows 已安装的 Python。
if not defined PYTHON_EXE (
    where py >nul 2>&1
    if not errorlevel 1 (
        py -3 --version >nul 2>&1
        if not errorlevel 1 set "PYTHON_EXE=py -3"
    )
)
if not defined PYTHON_EXE (
    where python >nul 2>&1
    if not errorlevel 1 set "PYTHON_EXE=python"
)

if not defined PYTHON_EXE (
    echo [错误] 未找到可用的 Python。
    echo 已检查当前文件夹的 python.exe，也未在 PATH 中找到 Python。
    echo 请确认 python.exe 与本 BAT 位于同一文件夹，或安装 Python 3。
    pause
    exit /b 1
)

echo 使用的 Python：%PYTHON_EXE%
if "%PYTHON_EXE%"=="py -3" (
    py -3 --version
    py -3 -c "import requests" >nul 2>&1
    if errorlevel 1 (
        echo [错误] 当前 Python 缺少 requests 依赖。
        echo 请执行：py -3 -m pip install requests
        pause
        exit /b 1
    )
    py -3 "%~dp0wms_integrated.py"
) else if "%PYTHON_EXE%"=="python" (
    python --version
    python -c "import requests" >nul 2>&1
    if errorlevel 1 (
        echo [错误] 当前 Python 缺少 requests 依赖。
        echo 请执行：python -m pip install requests
        pause
        exit /b 1
    )
    python "%~dp0wms_integrated.py"
) else (
    "%PYTHON_EXE%" --version
    if errorlevel 1 (
        echo [错误] 当前目录的 python.exe 无法启动。
        pause
        exit /b 1
    )
    "%PYTHON_EXE%" -c "import requests" >nul 2>&1
    if errorlevel 1 (
        echo [错误] 当前目录的 Python 环境没有安装 requests。
        echo 尝试执行以下命令安装：
        echo "%PYTHON_EXE%" -m pip install requests
        pause
        exit /b 1
    )
    "%PYTHON_EXE%" "%~dp0wms_integrated.py"
)

set "RUN_EXIT=%errorlevel%"
echo.
echo 程序已退出，退出代码：%RUN_EXIT%
pause
exit /b %RUN_EXIT%
