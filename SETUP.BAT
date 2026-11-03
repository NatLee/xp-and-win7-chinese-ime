@echo off
rem SETUP.BAT: put the old Microsoft Phonetic IME back on newer Windows.
rem   XP   - copies phonXP.ime, uniime.dll and the .tbl tables into the system
rem          folders, then imports old_typer_ver_bat\REG.reg.
rem   WIN7 - imports old_typer_ver_bat\Win7.reg, which adds the Windows 7
rem          Phonetic profile back to the built-in Microsoft Bopomofo.
rem This file is Big5 (code page 950) with CRLF line endings. Keep every line
rem above "chcp 950" ASCII; tests\check-files.ps1 checks all of this.
setlocal EnableExtensions DisableDelayedExpansion

rem A 32-bit cmd.exe gets SysWOW64 when it asks for System32 and writes to the
rem 32-bit registry, so let the 64-bit cmd.exe run this file instead. No
rem parentheses here: a folder such as "Downloads (1)" would close them early.
if not defined PROCESSOR_ARCHITEW6432 goto Native
"%windir%\Sysnative\cmd.exe" /c ""%~f0""
exit /b %errorlevel%
:Native

rem The messages are Big5, so show them with code page 950 and put the
rem console's own code page back at the end.
for /f "tokens=2 delims=:." %%C in ('chcp') do set /a "OLD_CP=%%C" >nul 2>&1
chcp 950 >nul

set "PAYLOAD=%~dp0old_typer_ver_bat"
set "EXIT_CODE=0"

echo 舊注音「ㄅ半」安裝程式  by Nat Lee
echo.
echo   XP 舊注音  ：Windows XP 的注音，要把檔案複製到系統資料夾。
echo   WIN7 舊注音：Windows 7 的注音，Windows 8 之後被藏起來，只改登錄檔。
echo.

call :Preflight || goto Failed

call :Ask "要安裝 XP 舊注音嗎？" || goto AskWin7
call :InstallXP && (set "INSTALLED=1") || (set "FAILED=1")

:AskWin7
call :Ask "要安裝 WIN7 舊注音嗎？" || goto Report
call :InstallWin7 && (set "INSTALLED=1") || (set "FAILED=1")

:Report
echo.
if defined FAILED goto Failed
if not defined INSTALLED (
    echo 沒有安裝任何東西。
    goto Done
)
echo 安裝成功！請到輸入法設定加入舊注音，步驟見 README。
echo 若無法使用，請重開機再確認一次。
goto Done

:Failed
set "EXIT_CODE=1"
echo 安裝沒有完成，請看上面的錯誤訊息。
goto Done

:Done
echo.
pause
if defined OLD_CP chcp %OLD_CP% >nul
endlocal & exit /b %EXIT_CODE%


rem ---------------------------------------------------------------------------

:Preflight
rem Stop before changing anything when the payload is missing, the script is
rem not elevated, or Windows is neither x86 nor x64. Sets DEST_64 and DEST_32.
if not exist "%PAYLOAD%\REG.reg" (
    echo 找不到 old_typer_ver_bat 資料夾。請先把整個 ZIP 解壓縮，再從解壓縮後的資料夾執行。
    exit /b 1
)
fltmc >nul 2>&1 || (
    echo 需要系統管理員權限：請在這個檔案上按右鍵，選「以系統管理員身分執行」。
    exit /b 1
)
rem The payload folders are named after where they go on 64-bit Windows:
rem System32 holds the 64-bit files, SysWOW64 the 32-bit ones. 32-bit Windows
rem only has System32, and that is where its 32-bit files go.
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    set "DEST_64=%windir%\System32"
    set "DEST_32=%windir%\SysWOW64"
    exit /b 0
)
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" (
    set "DEST_64="
    set "DEST_32=%windir%\System32"
    exit /b 0
)
echo 這些輸入法只有 x86 和 x64 版，不支援這台電腦的處理器：%PROCESSOR_ARCHITECTURE%
exit /b 1

:Ask
rem Exit code 0 only for Y. N, and no input at all (choice gives 255), mean no.
choice /c YN /m "%~1"
if errorlevel 2 exit /b 1
if errorlevel 1 exit /b 0
exit /b 1

:InstallXP
echo.
echo [XP 舊注音] 複製輸入法檔案
call :CopyFiles "%PAYLOAD%\System32" "%DEST_64%" || goto CopyFailed
call :CopyFiles "%PAYLOAD%\SysWOW64" "%DEST_32%" || goto CopyFailed
echo [XP 舊注音] 匯入 REG.reg
reg import "%PAYLOAD%\REG.reg" || exit /b 1
exit /b 0
:CopyFailed
echo 複製失敗。如果訊息說檔案正在使用中，請重新開機後再執行一次。
exit /b 1

:InstallWin7
echo.
echo [WIN7 舊注音] 匯入 Win7.reg
reg import "%PAYLOAD%\Win7.reg" || exit /b 1
exit /b 0

:CopyFiles
rem %1 = payload folder, %2 = system folder (empty: this Windows has none).
if "%~2"=="" exit /b 0
xcopy "%~1\*" "%~2\" /f /y
if errorlevel 1 exit /b 1
exit /b 0
