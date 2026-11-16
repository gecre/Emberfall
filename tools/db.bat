@echo off
rem Runs the Emberfall admin CLI (database management).
rem
rem   tools\db.bat                       show the command list
rem   tools\db.bat list                  list accounts
rem   tools\db.bat backup                snapshot the database
rem   tools\db.bat query "SELECT ..."    run a read-only query
rem
rem Works whether or not Node.js is on the PATH.
setlocal

set "NODE="
where node >nul 2>nul && set "NODE=node"
if not defined NODE if exist "C:\Program Files\nodejs\node.exe" set "NODE=C:\Program Files\nodejs\node.exe"
if not defined NODE (
  echo Node.js was not found. Install it or add it to the PATH.
  if "%~1"=="" pause
  exit /b 1
)

pushd "%~dp0..\server"
"%NODE%" src/admin.js %*
set "CODE=%ERRORLEVEL%"
popd

if not "%~1"=="" exit /b %CODE%
pause
exit /b %CODE%
