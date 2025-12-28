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
  $mdxFiles = Get-ChildItem -Recurse -File -Filter *.mdx $docsRoot | Where-Object {
    $_.FullName -notlike '*\.mintlify\*' -and $_.FullName -notlike '*\node_modules\*'
  }
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
$mdxFiles = Get-ChildItem -Recurse -File -Filter *.mdx $docsRoot | Where-Object {
  $_.FullName -notlike '*\.mintlify\*' -and $_.FullName -notlike '*\node_modules\*'
}
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

# Internal link sanity
$routeToFile = @{}
foreach ($f in $mdxFiles) {
  $rel = $f.FullName.Substring($docsRoot.Length + 1).Replace('\', '/')
  if ($rel -eq 'index.mdx') {
    $routeToFile['/'] = $f.FullName
    continue
  }
  if ($rel.EndsWith('/index.mdx')) {
    $route = '/' + $rel.Substring(0, $rel.Length - '/index.mdx'.Length)
    $routeToFile[$route] = $f.FullName
    continue
  }
  $routeToFile['/' + $rel.Substring(0, $rel.Length - '.mdx'.Length)] = $f.FullName
}

foreach ($f in $mdxFiles) {
  $text = Get-Content -Raw -Encoding UTF8 $f.FullName
  $matches = [regex]::Matches($text, '\]\((/[^)\s]+)\)')
  foreach ($m in $matches) {
    $href = $m.Groups[1].Value
    $href = $href.Split('#')[0]
    if ([string]::IsNullOrWhiteSpace($href)) {
      continue
    }
    if ($href.Length -gt 1 -and $href.EndsWith('/')) {
      $href = $href.TrimEnd('/')
    }
    if ($href -eq '/') {
      continue
    }
    if ($href -eq '/favicon.ico' -or $href -match '^/(image|logo)/') {
      continue
    }
    if (-not $routeToFile.ContainsKey($href)) {
      Fail "Broken internal link to '$href' in $($f.FullName)"
    }
  }
}

# Version snippets
Assert-FileContains (Join-Path $docsRoot "guides/quickstart.mdx") ("org.tabooproject.fluxon:fluxon-core:$version")
Assert-FileContains (Join-Path $docsRoot "runtime/jsr223.mdx") ("org.tabooproject.fluxon:fluxon-core:$version")
Assert-FileContains (Join-Path $docsRoot "runtime/jsr223.mdx") ("org.tabooproject.fluxon:fluxon-core-jsr223:$version")

# Code fence conventions
Assert-NoMatchInDocs '```ruby\s+Fluxon'

# Doc cross-references should be clickable
$tick = [char]96
foreach ($f in $mdxFiles) {
  $text = Get-Content -Raw -Encoding UTF8 $f.FullName
  foreach ($page in $pages) {
    if ($page -notmatch '/') {
      continue
    }
    $needle = "$tick$page$tick"
    if ($text -match [regex]::Escape($needle)) {
      Fail "Found non-clickable doc reference '$needle' in $($f.FullName) (use a Markdown link instead)"
    }
  }
}

# Avoid plain route references like "/guides/cli" without a Markdown link.
$plainRoutePattern = [regex]'(^|\s)(/(?:language|guides|runtime|developer|appendix|tooling)/[A-Za-z0-9_\-/]+)'
foreach ($f in $mdxFiles) {
  $lines = Get-Content -Encoding UTF8 $f.FullName
  $inFrontmatter = $false
  $frontmatterDone = $false
  $inCodeFence = $false

  for ($i = 0; $i -lt $lines.Length; $i++) {
    $line = $lines[$i]

    if (-not $frontmatterDone) {
      if (-not $inFrontmatter) {
        if ($line -match '^(?:\uFEFF)?---\s*$') {
          $inFrontmatter = $true
          continue
        }
      } else {
        if ($line -match '^---\s*$') {
          $inFrontmatter = $false
          $frontmatterDone = $true
          continue
        }
        continue
      }
    }

    if ($line -match '^```') {
      $inCodeFence = -not $inCodeFence
      continue
    }
    if ($inCodeFence) {
      continue
    }
    if ($line.TrimStart().StartsWith('|')) {
      continue
    }

    $m = $plainRoutePattern.Match($line)
    if (-not $m.Success) {
      continue
    }

    $route = $m.Groups[2].Value
    $before = $line.Substring(0, $m.Groups[2].Index).TrimEnd()
    if ($before.EndsWith('](')) {
      continue
    }

    $lineNo = $i + 1
    Fail "Found non-clickable route reference '$route' in $($f.FullName):$lineNo (use a Markdown link instead)"
  }
}

# Visible line width (readability / layout hygiene)
# Approximation: ASCII=1, non-ASCII=2 (fits CJK-heavy docs better than raw character count).
$maxVisibleLineWidth = 120
if ($env:FLUXON_DOCS_MAX_VISIBLE_LINE_WIDTH) {
  $parsed = 0
  if (-not [int]::TryParse($env:FLUXON_DOCS_MAX_VISIBLE_LINE_WIDTH, [ref]$parsed)) {
    Fail "FLUXON_DOCS_MAX_VISIBLE_LINE_WIDTH must be an integer (actual: '$($env:FLUXON_DOCS_MAX_VISIBLE_LINE_WIDTH)')"
  }
  $maxVisibleLineWidth = $parsed
} elseif ($env:FLUXON_DOCS_MAX_VISIBLE_LINE_CHARS) {
  # Backward-compatible alias.
  $parsed = 0
  if (-not [int]::TryParse($env:FLUXON_DOCS_MAX_VISIBLE_LINE_CHARS, [ref]$parsed)) {
    Fail "FLUXON_DOCS_MAX_VISIBLE_LINE_CHARS must be an integer (actual: '$($env:FLUXON_DOCS_MAX_VISIBLE_LINE_CHARS)')"
  }
  $maxVisibleLineWidth = $parsed
}

function Get-VisibleText([string]$line) {
  $t = $line.Trim()
  $t = [regex]::Replace($t, '^(?:[-*]|\d+\.)\s+', '')
  $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]+\)', '$1')
  $t = [regex]::Replace($t, '`([^`]*)`', '$1')
  $t = $t.Replace('**', '').Replace('__', '')
  $t = [regex]::Replace($t, '<[^>]+>', '')
  $t = [regex]::Replace($t, '\s+', ' ').Trim()
  return $t
}

function Get-ApproxDisplayWidth([string]$text) {
  $w = 0
  foreach ($ch in $text.ToCharArray()) {
    if ([int][char]$ch -le 127) {
      $w += 1
    } else {
      $w += 2
    }
  }
  return $w
}

if ($maxVisibleLineWidth -gt 0) {
  foreach ($f in $mdxFiles) {
    $lines = Get-Content -Encoding UTF8 $f.FullName
    $inFrontmatter = $false
    $frontmatterDone = $false
    $inCodeFence = $false

    for ($i = 0; $i -lt $lines.Length; $i++) {
      $line = $lines[$i]

      if (-not $frontmatterDone) {
        if (-not $inFrontmatter) {
          if ($line -match '^(?:\uFEFF)?---\s*$') {
            $inFrontmatter = $true
            continue
          }
        } else {
          if ($line -match '^---\s*$') {
            $inFrontmatter = $false
            $frontmatterDone = $true
            continue
          }
          continue
        }
      }

      if ($line -match '^```') {
        $inCodeFence = -not $inCodeFence
        continue
      }
      if ($inCodeFence) {
        continue
      }
      # Skip Markdown tables: they wrap visually and are hard to lint at the raw line level.
      if ($line.TrimStart().StartsWith('|')) {
        continue
      }

      $visible = Get-VisibleText $line
      if ([string]::IsNullOrWhiteSpace($visible)) {
        continue
      }
      $width = Get-ApproxDisplayWidth $visible
      if ($width -gt $maxVisibleLineWidth) {
        $lineNo = $i + 1
        Fail "Line too wide ($width > $maxVisibleLineWidth) in $($f.FullName):$lineNo`n$visible`nSoft-wrap the line (no blank line), or restructure as a list."
      }
    }
  }
}

Write-Output "OK"
