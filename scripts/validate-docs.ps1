$ErrorActionPreference = "Stop"

$docsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $docsRoot

function Fail([string]$message) {
  Write-Error $message
  exit 1
}

function Get-RepoVersion([string]$gradlePropertiesPath) {
  if (-not (Test-Path $gradlePropertiesPath)) {
    Fail "Missing gradle.properties at: $gradlePropertiesPath"
  }
  $text = Get-Content -Raw -Encoding UTF8 $gradlePropertiesPath
  $m = [regex]::Match($text, '(?m)^version=(.+)$')
  if (-not $m.Success) {
    Fail "Failed to find version=... in $gradlePropertiesPath"
  }
  return $m.Groups[1].Value.Trim()
}

function Assert-FileContains([string]$path, [string]$needle) {
  if (-not (Test-Path $path)) {
    Fail "Missing file: $path"
  }
  $text = Get-Content -Raw -Encoding UTF8 $path
  if ($text -notmatch [regex]::Escape($needle)) {
    Fail "Expected '$needle' in $path"
  }
}

function Assert-NoMatchInDocs([string]$pattern) {
  $mdxFiles = Get-ChildItem -Recurse -File -Filter *.mdx $docsRoot
  foreach ($f in $mdxFiles) {
    $text = Get-Content -Raw -Encoding UTF8 $f.FullName
    if ([regex]::IsMatch($text, $pattern)) {
      Fail "Found forbidden pattern /$pattern/ in $($f.FullName)"
    }
  }
}

$version = Get-RepoVersion (Join-Path $repoRoot "gradle.properties")
Write-Output "Repo version: $version"

# docs.json basic sanity
$docsJsonPath = Join-Path $docsRoot "docs.json"
if (-not (Test-Path $docsJsonPath)) {
  Fail "Missing docs.json at: $docsJsonPath"
}

$docsJson = Get-Content -Raw -Encoding UTF8 $docsJsonPath | ConvertFrom-Json
if ($docsJson.footer.socials.github -ne "https://github.com/TabooLib/fluxon") {
  Fail "docs.json footer.socials.github must be https://github.com/TabooLib/fluxon (actual: $($docsJson.footer.socials.github))"
}

# Navigation pages exist
$pages = @()
foreach ($tab in $docsJson.navigation.tabs) {
  foreach ($group in $tab.groups) {
    foreach ($page in $group.pages) {
      $pages += $page
    }
  }
}

$missing = @()
foreach ($page in $pages) {
  $path = Join-Path $docsRoot ($page + ".mdx")
  if (-not (Test-Path $path)) {
    $missing += $page
  }
}
if ($missing.Count -gt 0) {
  Fail ("docs.json references missing page(s): " + ($missing -join ", "))
}

# Frontmatter required fields
$mdxFiles = Get-ChildItem -Recurse -File -Filter *.mdx $docsRoot
foreach ($f in $mdxFiles) {
  $text = Get-Content -Raw -Encoding UTF8 $f.FullName
  if (-not ($text -match '(?s)^(?:\uFEFF)?---\s*\r?\n.*?\r?\n---\s*\r?\n')) {
    Fail "Missing frontmatter block in $($f.FullName)"
  }
  if (-not ($text -match '(?m)^title:\s*\".+\"\s*$')) {
    Fail "Missing frontmatter title in $($f.FullName)"
  }
  if (-not ($text -match '(?m)^description:\s*\".+\"\s*$')) {
    Fail "Missing frontmatter description in $($f.FullName)"
  }
}

# Version snippets
Assert-FileContains (Join-Path $docsRoot "guides/quickstart.mdx") ("org.tabooproject.fluxon:fluxon-core:$version")
Assert-FileContains (Join-Path $docsRoot "runtime/jsr223.mdx") ("org.tabooproject.fluxon:fluxon-core:$version")
Assert-FileContains (Join-Path $docsRoot "runtime/jsr223.mdx") ("org.tabooproject.fluxon:fluxon-core-jsr223:$version")

# Code fence conventions
Assert-NoMatchInDocs '```ruby\s+Fluxon'

Write-Output "OK"
