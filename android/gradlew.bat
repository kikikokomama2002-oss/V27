@rem Standard Gradle wrapper launch script for Windows.
@echo off
set DIRNAME=%~dp0
set APP_HOME=%DIRNAME%
set "WRAPPER_JAR=%APP_HOME%gradle\wrapper\gradle-wrapper.jar"
if not exist "%WRAPPER_JAR%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%APP_HOME%gradle\wrapper\bootstrap-wrapper.ps1"
  if errorlevel 1 exit /b %errorlevel%
)
set EXPECTED_WRAPPER_SHA256=81a82aaea5abcc8ff68b3dfcb58b3c3c429378efd98e7433460610fecd7ae45f
for /f "delims=" %%H in ('powershell -NoProfile -Command "$h=(Get-FileHash -Algorithm SHA256 -LiteralPath $env:WRAPPER_JAR).Hash.ToLowerInvariant(); Write-Output $h"') do set "ACTUAL_WRAPPER_SHA256=%%H"
if /I not "%ACTUAL_WRAPPER_SHA256%"=="%EXPECTED_WRAPPER_SHA256%" (
  echo error: gradle-wrapper.jar checksum mismatch 1>&2
  exit /b 1
)
set CLASSPATH=%WRAPPER_JAR%
if not "%JAVA_HOME%"=="" (
  set JAVACMD=%JAVA_HOME%\bin\java.exe
) else (
  set JAVACMD=java.exe
)
"%JAVACMD%" -classpath "%CLASSPATH%" org.gradle.wrapper.GradleWrapperMain %*
