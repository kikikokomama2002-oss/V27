$ErrorActionPreference = "Stop"
$wrapperDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$props = Join-Path $wrapperDir "gradle-wrapper.properties"
$jar = Join-Path $wrapperDir "gradle-wrapper.jar"
if (-not (Test-Path $props)) { throw "Missing $props" }
$content = Get-Content $props -Raw
$match = [regex]::Match($content, 'gradle-([0-9]+(?:\.[0-9]+)+)-(?:all|bin)\.zip')
if (-not $match.Success) { throw "Could not parse Gradle version from $props" }
$version = $match.Groups[1].Value
$expected = switch ($version) {
  "8.13" { "81a82aaea5abcc8ff68b3dfcb58b3c3c429378efd98e7433460610fecd7ae45f" }
  default { throw "No pinned wrapper checksum is configured for Gradle $version" }
}
$url = "https://raw.githubusercontent.com/gradle/gradle/v$version.0/gradle/wrapper/gradle-wrapper.jar"
Write-Host "Fetching Gradle $version wrapper JAR from $url..."
Invoke-WebRequest -Uri $url -OutFile $jar
$actual = (Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) {
  Remove-Item $jar -Force
  throw "Gradle wrapper JAR checksum mismatch. Expected $expected, got $actual."
}
Write-Host "Gradle $version wrapper JAR verified."
