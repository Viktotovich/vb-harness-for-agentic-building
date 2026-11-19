@echo off
rem SPDX-License-Identifier: Apache-2.0
rem Copyright 2026 V and Bruno LLC
rem
rem Double-click this file to start VB Harness on Windows.
rem It checks for Ruby 3.3+, Git and Node.js. For each one that is missing it says what it is for and,
rem only after you press Y, installs it with winget (the package manager built into Windows) from the
rem official winget catalog. If that is not possible it opens the official download page instead.
rem Then it runs: ruby exe\harness ui --open
rem It never asks for administrator rights itself; an installer may ask, and Windows shows you when it does.

setlocal
title VB Harness
cd /d "%~dp0"

echo.
echo   VB Harness
echo   ==========
echo.

if not exist "exe\harness" goto :not_unzipped

set "INSTALLED="
set "RUBY_MISSING="

rem --- Git -----------------------------------------------------------------
where git >nul 2>nul
if not errorlevel 1 goto :git_ok
echo   Git is missing. VB Harness uses Git to keep every change on its own branch, so a build can always
echo   be undone.
call :offer "Git" "Git.Git" "https://git-scm.com/downloads/win"
echo.
:git_ok

rem --- Node.js -------------------------------------------------------------
where node >nul 2>nul
if not errorlevel 1 goto :node_ok
echo   Node.js is missing. It runs website projects: "New Astro site" needs it. You can skip it if you
echo   only build other kinds of projects.
call :offer "Node.js" "OpenJS.NodeJS.LTS" "https://nodejs.org/en/download"
echo.
:node_ok

rem --- Ruby 3.3 or newer ---------------------------------------------------
where ruby >nul 2>nul
if errorlevel 1 goto :ruby_missing
ruby -e "exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3') ? 0 : 1)" >nul 2>nul
if not errorlevel 1 goto :ruby_ok
echo   Your Ruby is older than 3.3, which VB Harness needs.
goto :ruby_offer
:ruby_missing
echo   Ruby is missing. VB Harness is written in Ruby, so it cannot start without it.
:ruby_offer
set "RUBY_MISSING=1"
call :offer "Ruby 3.4" "RubyInstallerTeam.Ruby.3.4" "https://rubyinstaller.org/downloads/"
echo.
:ruby_ok

if defined INSTALLED goto :restart
if defined RUBY_MISSING goto :no_ruby

rem --- Start ---------------------------------------------------------------
echo   Starting VB Harness. Your browser opens in a moment.
echo   Keep this window open while you use it. Close it to stop VB Harness.
echo.
ruby exe\harness ui --open
if errorlevel 1 goto :crashed
exit /b 0

rem --- Messages ------------------------------------------------------------
:not_unzipped
echo   This file has to run from the unzipped folder.
echo   Right-click the ZIP you downloaded, choose "Extract All...", open the new folder and
echo   double-click "Start VB Harness" there.
goto :wait_and_fail

:restart
echo   Done installing. Close this window and double-click "Start VB Harness" again,
echo   so Windows picks up the new tools.
echo.
pause
exit /b 0

:no_ruby
echo   VB Harness cannot start without Ruby 3.3 or newer.
echo   Install Ruby from https://rubyinstaller.org/downloads/ - the recommended "Ruby+Devkit" or plain
echo   "Ruby" x64 installer, version 3.3 or newer - then double-click "Start VB Harness" again.
goto :wait_and_fail

:crashed
echo.
echo   VB Harness stopped with an error; the message is above.
echo   If it says it cannot listen on port 4567, VB Harness is probably already open in another window.
goto :wait_and_fail

:wait_and_fail
echo.
pause
exit /b 1

rem --- :offer NAME WINGET-ID DOWNLOAD-PAGE ---------------------------------
rem Asks before installing anything. Sets INSTALLED when winget finished without an error.
:offer
choice /c YN /n /m "  Install %~1 now? Press Y for yes or N for no: "
if errorlevel 2 goto :offer_skipped
where winget >nul 2>nul
if errorlevel 1 goto :offer_no_winget
echo   Installing %~1 with winget from the official catalog.
echo   If Windows asks "Do you want to allow this app to make changes to your device?", choose Yes.
winget install --id %~2 --exact --source winget
if errorlevel 1 goto :offer_failed
set "INSTALLED=1"
exit /b 0

:offer_skipped
echo   Skipped. You can install %~1 yourself from %~3
exit /b 1

:offer_no_winget
echo   winget is not available on this computer, so the official download page opens instead:
echo   %~3
start "" "%~3"
exit /b 1

:offer_failed
echo   The installer did not finish. The official download page opens instead:
echo   %~3
start "" "%~3"
exit /b 1
