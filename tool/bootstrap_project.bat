@echo off
setlocal
where flutter >nul 2>nul
if errorlevel 1 (
  echo error: Flutter SDK is required
  exit /b 1
)
call flutter pub get
if errorlevel 1 exit /b %errorlevel%
call dart run build_runner build --delete-conflicting-outputs
if errorlevel 1 exit /b %errorlevel%
echo Project bootstrap complete.
