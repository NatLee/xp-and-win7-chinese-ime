@echo off
rem DELETE.BAT: remove what SETUP.BAT installed, both the XP and the WIN7 IME.
rem What to remove comes from the payload itself: the file names in
rem old_typer_ver_bat\System32 and SysWOW64, and the [keys] in the .reg files.
rem This file is Big5 (code page 950) with CRLF line endings. Keep every line
rem above "chcp 950" ASCII; tests\check-files.ps1 checks all of this.
setlocal EnableExtensions DisableDelayedExpansion

rem A 32-bit cmd.exe gets SysWOW64 when it asks for System32 and reads the
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

echo 刪除已安裝的舊注音  by Nat Lee
echo.
echo 建議先到輸入法設定，把舊注音從鍵盤清單拿掉，再執行這個檔案。
echo.

call :Preflight || goto Failed
call :Ask "要刪除所有舊注音嗎？" || goto Done

rem Registry first: once the keys are gone Windows stops loading the IME, so a
rem file that is in use right now can still be deleted after a restart.
echo.
call :DeleteKeys "%PAYLOAD%\REG.reg"
call :DeleteKeys "%PAYLOAD%\Win7.reg"
call :DeleteFiles "%PAYLOAD%\System32" "%DEST_64%"
call :DeleteFiles "%PAYLOAD%\SysWOW64" "%DEST_32%"

echo.
if defined FAILED goto Failed
if defined LOCKED (
    set "EXIT_CODE=1"
    echo 登錄檔已經刪除，但有檔案正在使用中，刪不掉。
    echo 請重新開機後再執行一次 DELETE.BAT。
    goto Done
)
if not defined REMOVED (
    echo 沒有找到已安裝的舊注音，不用刪除。
    goto Done
)
echo 刪除成功！
echo 請檢查輸入法，若有問題請重新啟動電腦！
goto Done

:Failed
set "EXIT_CODE=1"
echo 刪除沒有完成，請看上面的錯誤訊息。
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

:DeleteKeys
rem %1 = a .reg file from the payload. Delete every [key] it creates; type
rem also reads Win7.reg, which is UTF-16.
for /f "usebackq tokens=1 delims=[]" %%K in (`type "%~1" ^| findstr /l /b /c:"["`) do call :DeleteKey "%%K"
exit /b 0

:DeleteKey
reg query "%~1" >nul 2>&1 || exit /b 0
reg delete "%~1" /f >nul || (set "FAILED=1" & exit /b 1)
echo 已刪除登錄機碼：%~1
set "REMOVED=1"
exit /b 0

:DeleteFiles
rem %1 = payload folder, %2 = system folder (empty: this Windows has none).
if "%~2"=="" exit /b 0
for %%F in ("%~1\*") do call :DeleteFile "%~2\%%~nxF"
exit /b 0

:DeleteFile
if not exist "%~1" exit /b 0
del /f /q "%~1" >nul 2>&1
if exist "%~1" (
    echo 刪不掉，可能正在使用中："%~1"
    set "LOCKED=1"
    exit /b 1
)
echo 已刪除："%~1"
set "REMOVED=1"
exit /b 0
