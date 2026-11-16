# Converts EmberfallWiki.xlsx (a Helmet Heroes Wiki scrape) into the
# JSON data files used by the game at runtime.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/convert_wiki_data.ps1
#
# Optional:
#   -Xlsx  path to the workbook   (default: ..\EmberfallWiki.xlsx)
#   -OutDir path to write JSON to (default: ..\Emberfall\data)

param(
  [string]$Xlsx,
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
if (-not $Xlsx)   { $Xlsx = Join-Path $projectRoot 'EmberfallWiki.xlsx' }
if (-not $OutDir) { $OutDir = Join-Path $projectRoot 'Emberfall\data' }
$tempDir = Join-Path $env:TEMP 'emberfall_wiki_tsv'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

# --------------------------------------------------------------------------
# 1. Unpack the workbook into TSV sheets
# --------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-ZipText($zip, $name) {
  $e = $zip.GetEntry($name)
  if (-not $e) { return $null }
  $sr = New-Object System.IO.StreamReader($e.Open())
  $t = $sr.ReadToEnd(); $sr.Close(); return $t
}

function Convert-ColRefToIndex([string]$cellRef) {
  $letters = ($cellRef -replace '[0-9]', '')
  $n = 0
  foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int][char]$ch - 64) }
  return $n - 1
}

$zip = [System.IO.Compression.ZipFile]::OpenRead($Xlsx)
$shared = New-Object System.Collections.Generic.List[string]
$ssXml = Read-ZipText $zip 'xl/sharedStrings.xml'
if ($ssXml) {
  [xml]$ss = $ssXml
  foreach ($si in $ss.sst.si) {
    if ($si.t -is [string]) { $shared.Add($si.t) }
    elseif ($si.t.'#text') { $shared.Add($si.t.'#text') }
    else {
      $sb = ''
      foreach ($r in $si.r) {
        if ($r.t -is [string]) { $sb += $r.t }
        elseif ($r.t.'#text') { $sb += $r.t.'#text' }
      }
      $shared.Add($sb)
    }
  }
}

[xml]$rels = Read-ZipText $zip 'xl/_rels/workbook.xml.rels'
$relMap = @{}
foreach ($r in $rels.Relationships.Relationship) { $relMap[$r.Id] = $r.Target }
[xml]$wb = Read-ZipText $zip 'xl/workbook.xml'

foreach ($s in $wb.workbook.sheets.sheet) {
  $rid = $s.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
  $target = $relMap[$rid]
  if ($target -notmatch '^xl/') { $target = 'xl/' + $target }
  $xmlText = Read-ZipText $zip $target
  if (-not $xmlText) { continue }
  [xml]$doc = $xmlText
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($row in $doc.worksheet.sheetData.row) {
    $cells = @{}
    $maxCol = -1
    foreach ($c in $row.c) {
      $ci = Convert-ColRefToIndex $c.r
      $v = ''
      if ($c.t -eq 's') {
        $idx = [int]$c.v
        if ($idx -lt $shared.Count) { $v = $shared[$idx] }
      } elseif ($c.t -eq 'inlineStr') {
        if ($c.is.t -is [string]) { $v = $c.is.t } else { $v = $c.is.t.'#text' }
      } else {
        $v = [string]$c.v
      }
      $cells[$ci] = ($v -replace "`r?`n", ' ' -replace "`t", ' ')
      if ($ci -gt $maxCol) { $maxCol = $ci }
    }
    if ($maxCol -lt 0) { $lines.Add(''); continue }
    $arr = New-Object string[] ($maxCol + 1)
    for ($i = 0; $i -le $maxCol; $i++) { if ($cells.ContainsKey($i)) { $arr[$i] = $cells[$i] } else { $arr[$i] = '' } }
    $lines.Add(($arr -join "`t"))
  }
  $safe = $s.name -replace '[\\/:*?"<>|]', '_'
  [System.IO.File]::WriteAllLines((Join-Path $tempDir "$safe.tsv"), $lines, (New-Object System.Text.UTF8Encoding($false)))
}
$zip.Dispose()

function Read-Sheet([string]$name) {
  $p = Join-Path $tempDir "$name.tsv"
  if (-not (Test-Path $p)) { return @() }
  return @(Import-Csv -Path $p -Delimiter "`t")
}

# --------------------------------------------------------------------------
# 2. Value parsing helpers
# --------------------------------------------------------------------------
function To-Number($value) {
  if ($null -eq $value) { return $null }
  $t = ([string]$value).Trim()
  if ($t -eq '') { return $null }
  if ($t -match '(?i)formatnum:\s*([0-9\.,]+)') { $t = $matches[1] }
  $t = $t -replace '[,\$#]', ''
  $t = $t -replace '(?i)\s*(mph|ft|hp|mp|%|seconds?|secs?|x)\b.*$', ''
  $t = $t.Trim()
  if ($t -match '^(-?\d+(?:\.\d+)?)$') { return [double]$t }
  if ($t -match '^(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)$') { return [double]$matches[1] }
  if ($t -match '^(-?\d+(?:\.\d+)?)') { return [double]$matches[1] }
  return $null
}

function To-Int($value) {
  $n = To-Number $value
  if ($null -eq $n) { return $null }
  return [int][math]::Round($n)
}

function To-Range($value) {
  if ($null -eq $value) { return @($null, $null) }
  $t = ([string]$value).Trim()
  if ($t -match '^(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?)$') {
    return @([double]$matches[1], [double]$matches[2])
  }
  $n = To-Number $t
  return @($n, $n)
}

function To-List($value) {
  if ($null -eq $value) { return @() }
  $t = ([string]$value).Trim()
  if ($t -eq '') { return @() }
  $t = $t -replace '(?i)\bno\s+npc''?s?\b', ''
  $t = $t -replace '(?i)\bno\s+monsters?\b', ''
  $t = $t -replace '(?i)\bno\s+fish\b', ''
  $t = $t -replace '(?i)\bnone\b', ''
  $t = $t -replace ([string][char]0x2022), "`n"
  $parts = $t -split "[`n;]" | ForEach-Object { $_.Trim().Trim('.') } | Where-Object { $_ -ne '' }
  return @($parts)
}

function Parse-StageRef([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  if ($value -match '\(\s*#?(\d+)\s*#?\s*\)\s*(.*)$') {
    return [ordered]@{ number = [int]$matches[1]; name = $matches[2].Trim() }
  }
  return [ordered]@{ number = $null; name = $value.Trim() }
}

function New-ItemEntry([string]$name) {
  return [ordered]@{
    name          = $name
    type          = 'misc'
    slot          = 'none'
    level         = 1
    categories    = @()
    defense       = 0
    power         = 0
    magic         = 0
    range         = 0
    luck          = 0
    strength      = 0
    dexterity     = 0
    health        = 0
    damage_min    = 0
    damage_max    = 0
    reach         = 0
    two_handed    = $false
    rpm           = 0
    price         = 0
    sell          = 0
    shop          = ''
    effect        = ''
    stats_text    = ''
    special_type  = ''
    special_damage = 0
    rare          = $false
    seasonal      = $false
    dropped_by    = @()
    pet_mode      = ''
    pet_dexterity = 0
    image         = ''
  }
}

# --------------------------------------------------------------------------
# 3. Categories -> item type
# --------------------------------------------------------------------------
$categoryToType = @{
  'Armors'              = @('armor', 'armor')
  'Helmets'             = @('helmet', 'helmet')
  'Leggings'            = @('legs', 'legs')
  'Shoes/Boots'         = @('boots', 'boots')
  'Shields'             = @('shield', 'shield')
  'Accessories'         = @('accessory', 'accessory')
  'Melee Weapons'       = @('melee', 'weapon')
  'Magic Weapons'       = @('magic', 'weapon')
  'Artillery Weapons'   = @('artillery', 'weapon')
  'Ranged Weapons'      = @('ranged', 'weapon')
  'Consumables'         = @('consumable', 'consumable')
  'Pet Helmets'         = @('pet_helmet', 'pet_helmet')
  'Pets'                = @('pet', 'pet')
  'Fish'                = @('fish', 'consumable')
  'Logs'                = @('log', 'material')
  'Seeds'               = @('seed', 'material')
}

$pageCategories = @{}
foreach ($row in (Read-Sheet 'PageCategories')) {
  if (-not $pageCategories.ContainsKey($row.Title)) { $pageCategories[$row.Title] = New-Object System.Collections.Generic.List[string] }
  $pageCategories[$row.Title].Add($row.Category)
}

# --------------------------------------------------------------------------
# 4. Items
# --------------------------------------------------------------------------
$items = [ordered]@{}

function Get-ItemEntry([string]$name) {
  if (-not $items.Contains($name)) { $items[$name] = New-ItemEntry $name }
  return $items[$name]
}

# Seed every item-like page so shop-only items are included.
$itemCategoryNames = @('Armors','Helmets','Leggings','Shoes/Boots','Shields','Accessories',
  'Melee Weapons','Magic Weapons','Artillery Weapons','Ranged Weapons','Consumables',
  'Pet Helmets','Pets','Fish','Logs','Seeds')
foreach ($row in (Read-Sheet 'CategoryMembers')) {
  if ($itemCategoryNames -notcontains $row.Category) { continue }
  $entry = Get-ItemEntry $row.Title
  $mapping = $categoryToType[$row.Category]
  if ($mapping) { $entry.type = $mapping[0]; $entry.slot = $mapping[1] }
}

foreach ($name in $pageCategories.Keys) {
  $cats = $pageCategories[$name]
  $isItemPage = $items.Contains($name)
  if (-not $isItemPage) {
    foreach ($cat in $cats) { if ($itemCategoryNames -contains $cat) { $isItemPage = $true; break } }
  }
  if (-not $isItemPage) { continue }
  $entry = Get-ItemEntry $name
  $entry.categories = @($cats)
  foreach ($cat in $cats) {
    if ($categoryToType.ContainsKey($cat)) {
      $mapping = $categoryToType[$cat]
      $entry.type = $mapping[0]; $entry.slot = $mapping[1]
    }
    if ($cat -eq 'Rare Items') { $entry.rare = $true }
    if ($cat -eq 'Seasonal Items') { $entry.seasonal = $true }
  }
}

function Apply-EquipmentRow($row) {
  $name = $row.SourcePage
  if ([string]::IsNullOrWhiteSpace($name)) { return }
  $e = Get-ItemEntry $name
  if ($e.type -eq 'misc' -and $row.Template -eq 'EquipmentInfobox') {
    # Fall back to the name suffix when categories are missing.
    $n = $name.ToLower()
    if ($n -match 'helmet|hat|cap|hood|helm') { $e.type = 'helmet'; $e.slot = 'helmet' }
    elseif ($n -match 'leg|pant|skirt') { $e.type = 'legs'; $e.slot = 'legs' }
    elseif ($n -match 'boot|shoe') { $e.type = 'boots'; $e.slot = 'boots' }
    elseif ($n -match 'shield') { $e.type = 'shield'; $e.slot = 'shield' }
    elseif ($n -match 'cape|wing|tail|pack|balloon') { $e.type = 'accessory'; $e.slot = 'accessory' }
    else { $e.type = 'armor'; $e.slot = 'armor' }
  }
  $lvl = To-Int $row.level
  if ($null -ne $lvl) { $e.level = $lvl }
  foreach ($field in @('defense','power','magic','range','luck','strength','dexterity','health')) {
    $v = To-Number $row.$field
    if ($null -ne $v) { $e[$field] = $v }
  }
  $price = To-Number $row.price
  if ($null -eq $price) { $price = To-Number $row.pricebuy }
  if ($null -ne $price) { $e.price = [int]$price }
  $sell = To-Number $row.pricesell
  if ($null -eq $sell) { $sell = To-Number $row.sell }
  if ($null -ne $sell) { $e.sell = [int]$sell }
  if ($row.shop) { $e.shop = $row.shop }
  if ($row.effect) { $e.effect = $row.effect }
  if ($row.stats) { $e.stats_text = $row.stats }
}

foreach ($row in (Read-Sheet 'EquipmentInfobox')) { Apply-EquipmentRow $row }

function Apply-WeaponRow($row) {
  $name = $row.SourcePage
  if ([string]::IsNullOrWhiteSpace($name)) { return }
  $e = Get-ItemEntry $name
  if ($e.type -eq 'misc') {
    $e.type = 'melee'; $e.slot = 'weapon'
  }
  $lvl = To-Int $row.level
  if ($null -ne $lvl) { $e.level = $lvl }
  $range = To-Range $row.damage
  if ($null -ne $range[0]) { $e.damage_min = $range[0]; $e.damage_max = $range[1] }
  $dmin = To-Number $row.damagemin
  $dmax = To-Number $row.damagemax
  if ($null -ne $dmin) { $e.damage_min = $dmin }
  if ($null -ne $dmax) { $e.damage_max = $dmax }
  $reach = To-Number $row.reach
  if ($null -ne $reach) { $e.reach = $reach }
  if ($row.twohanded) { $e.two_handed = ($row.twohanded -match '(?i)^yes|true') }
  $rpm = To-Number $row.rpm
  if ($null -ne $rpm) { $e.rpm = $rpm }
  $price = To-Number $row.price
  if ($null -eq $price) { $price = To-Number $row.pricebuy }
  if ($null -ne $price) { $e.price = [int]$price }
  $sell = To-Number $row.pricesell
  if ($null -eq $sell) { $sell = To-Number $row.sell }
  if ($null -ne $sell) { $e.sell = [int]$sell }
  if ($row.shop) { $e.shop = $row.shop }
  if ($row.specialtype) { $e.special_type = $row.specialtype }
  $sd = To-Number $row.specialdamage
  if ($null -ne $sd) { $e.special_damage = $sd }
  if ($row.items) { $e.stats_text = $row.items }
}

foreach ($row in (Read-Sheet 'WeaponInfobox')) { Apply-WeaponRow $row }

foreach ($row in (Read-Sheet 'ConsumableInfobox')) {
  $name = $row.SourcePage
  if ([string]::IsNullOrWhiteSpace($name)) { continue }
  $e = Get-ItemEntry $name
  $e.type = 'consumable'; $e.slot = 'consumable'
  if ($row.effect) { $e.effect = $row.effect }
  $price = To-Number $row.price
  if ($null -eq $price) { $price = To-Number $row.pricebuy }
  if ($null -ne $price) { $e.price = [int]$price }
  $sell = To-Number $row.pricesell
  if ($null -eq $sell) { $sell = To-Number $row.sell }
  if ($null -ne $sell) { $e.sell = [int]$sell }
  if ($row.shop) { $e.shop = $row.shop }
  $heal = To-Number $row.heal
  if ($null -ne $heal) { $e.health = $heal }
}

foreach ($row in (Read-Sheet 'PetHelmetInfobox')) {
  $name = $row.SourcePage
  if ([string]::IsNullOrWhiteSpace($name)) { continue }
  $e = Get-ItemEntry $name
  $e.type = 'pet_helmet'; $e.slot = 'pet_helmet'
  $lvl = To-Int $row.level
  if ($null -ne $lvl) { $e.level = $lvl }
  foreach ($field in @('defense','power','magic','range','luck')) {
    $v = To-Number $row.$field
    if ($null -ne $v) { $e[$field] = $v }
  }
  $price = To-Number $row.price
  if ($null -ne $price) { $e.price = [int]$price }
  if ($row.effect) { $e.effect = $row.effect }
}

# Shop-list templates fill in anything the infoboxes missed.
$rowSheets = @{
  'ArmorRow'       = 'armor'
  'WeaponRow'      = 'weapon'
  'GunRow'         = 'artillery'
  'ShieldRow'      = 'shield'
  'AccessoryRow'   = 'accessory'
  'ConsumableRow'  = 'consumable'
  'PetHelmetRow'   = 'pet_helmet'
  'PetRow'         = 'pet'
}
foreach ($sheetName in $rowSheets.Keys) {
  foreach ($row in (Read-Sheet $sheetName)) {
    $name = $row.name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $row.SourcePage }
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $e = Get-ItemEntry $name
    if ($e.type -eq 'misc') {
      $e.type = $rowSheets[$sheetName]
      $e.slot = switch ($rowSheets[$sheetName]) {
        'weapon' { 'weapon' } 'artillery' { 'weapon' } 'shield' { 'shield' }
        'accessory' { 'accessory' } 'consumable' { 'consumable' }
        'pet_helmet' { 'pet_helmet' } 'pet' { 'pet' } default { $rowSheets[$sheetName] }
      }
    }
    if ($e.level -eq 1) { $lvl = To-Int $row.level; if ($null -ne $lvl -and $lvl -gt 1) { $e.level = $lvl } }
    if ($e.defense -eq 0) { $v = To-Number $row.defense; if ($null -ne $v) { $e.defense = $v } }
    if ($e.power -eq 0) { $v = To-Number $row.power; if ($null -ne $v) { $e.power = $v } }
    if ($e.magic -eq 0) { $v = To-Number $row.magic; if ($null -ne $v) { $e.magic = $v } }
    if ($e.range -eq 0) { $v = To-Number $row.range; if ($null -ne $v) { $e.range = $v } }
    if ($e.luck -eq 0) { $v = To-Number $row.luck; if ($null -ne $v) { $e.luck = $v } }
    if ($e.strength -eq 0) { $v = To-Number $row.strength; if ($null -ne $v) { $e.strength = $v } }
    if ($e.dexterity -eq 0) { $v = To-Number $row.dexterity; if ($null -ne $v) { $e.dexterity = $v } }
    if ($e.damage_min -eq 0 -and $e.damage_max -eq 0) {
      $r = To-Range $row.damage
      if ($null -ne $r[0]) { $e.damage_min = $r[0]; $e.damage_max = $r[1] }
    }
    if ($e.reach -eq 0) { $v = To-Number $row.reach; if ($null -ne $v) { $e.reach = $v } }
    if ($e.price -eq 0) {
      $v = To-Number $row.price
      if ($null -eq $v) { $v = To-Number $row.pricebuy }
      if ($null -ne $v) { $e.price = [int]$v }
    }
    if ($e.sell -eq 0) {
      $v = To-Number $row.pricesell
      if ($null -eq $v) { $v = To-Number $row.sell }
      if ($null -ne $v) { $e.sell = [int]$v }
    }
    if (-not $e.shop -and $row.shop) { $e.shop = $row.shop }
    if (-not $e.effect -and $row.effect) { $e.effect = $row.effect }
    if (-not $e.stats_text -and $row.stats) { $e.stats_text = $row.stats }
    if ($row.dexterity) { $v = To-Number $row.dexterity; if ($null -ne $v) { $e.pet_dexterity = $v } }
    if ($row.mode) { $e.pet_mode = $row.mode }
  }
}

# Drop sources
foreach ($row in (Read-Sheet 'DroppedBy')) {
  if (-not $row.Item) { continue }
  $e = Get-ItemEntry $row.Item
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($m in $e.dropped_by) { $list.Add($m) }
  if (-not $list.Contains($row.Monster)) { $list.Add($row.Monster) }
  $e.dropped_by = @($list)
}

# --------------------------------------------------------------------------
# 5. Monsters
# --------------------------------------------------------------------------
$monsters = [ordered]@{}
function Get-Monster([string]$name) {
  if (-not $monsters.Contains($name)) {
    $monsters[$name] = [ordered]@{
      name      = $name
      health    = 100
      defense   = 0
      power     = 10
      xp        = 10
      speed     = 3.0
      height    = 2.0
      worth     = 5
      boss      = $false
      drops     = @()
      locations = @()
      tier      = 1
    }
  }
  return $monsters[$name]
}

foreach ($row in (Read-Sheet 'CategoryMembers')) {
  if ($row.Category -eq 'Monsters') { [void](Get-Monster $row.Title) }
  if ($row.Category -eq 'Bosses') { $m = Get-Monster $row.Title; $m.boss = $true }
}

foreach ($row in (Read-Sheet 'GreenMonsterBox')) {
  $name = $row.name
  if ([string]::IsNullOrWhiteSpace($name)) { $name = $row.SourcePage }
  if ([string]::IsNullOrWhiteSpace($name)) { continue }
  $m = Get-Monster $name
  foreach ($field in @('health','defense','power','xp','speed','height','worth')) {
    $v = To-Number $row.$field
    if ($null -ne $v) { $m[$field] = $v }
  }
}

foreach ($row in (Read-Sheet 'MonsterInfobox')) {
  $name = $row.SourcePage
  if ([string]::IsNullOrWhiteSpace($name)) { continue }
  $m = Get-Monster $name
  foreach ($field in @('health','defense','power','xp','speed','height','worth')) {
    $v = To-Number $row.$field
    if ($null -ne $v) { $m[$field] = $v }
  }
  $tier = 1
  if ($m.health -gt 0) {
    $tier = [int][math]::Ceiling([math]::Log($m.health, 1.35))
    $tier = [math]::Max(1, [math]::Min(200, $tier))
  }
  $m.tier = $tier
}

foreach ($row in (Read-Sheet 'MonsterDrops')) {
  if (-not $row.Monster) { continue }
  $m = Get-Monster $row.Monster
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($d in $m.drops) { $list.Add($d) }
  if (-not $list.Contains($row.Item)) { $list.Add($row.Item) }
  $m.drops = @($list)
}

foreach ($row in (Read-Sheet 'MonsterLocations')) {
  if (-not $row.Monster) { continue }
  $m = Get-Monster $row.Monster
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($l in $m.locations) { $list.Add($l) }
  if (-not $list.Contains($row.Location)) { $list.Add($row.Location) }
  $m.locations = @($list)
}

# --------------------------------------------------------------------------
# 6. Stages
# --------------------------------------------------------------------------
$stages = @{}

function New-Stage([int]$num, [string]$name) {
  if ($stages.ContainsKey($num)) { return $stages[$num] }
  $stages[$num] = [ordered]@{
    number     = $num
    name       = $name
    display    = $name
    npcs       = @()
    enemies    = @()
    fish       = @()
    previous   = $null
    next       = $null
    monsters   = @()
    spawn_cap  = 0
  }
  return $stages[$num]
}

# GreenMiniStageBox is the complete stage list (numbers 1..145, some gaps).
foreach ($row in (Read-Sheet 'GreenMiniStageBox')) {
  $num = To-Int $row.number
  $name = $row.name
  if ($null -eq $num) { continue }
  if ([string]::IsNullOrWhiteSpace($name) -or $name -ieq 'None') { continue }
  $stage = New-Stage $num $name
  $stage.name = $name
  $stage.display = $name
  $stage.npcs = @(To-List $row.npcs)
  $stage.enemies = @(@(To-List $row.monsters) + @(To-List $row.enemies))
  $stage.fish = @(To-List $row.fish)
  $cap = To-Int $row.spawncap
  if ($null -ne $cap) { $stage.spawn_cap = $cap }
}

# Chain stages together in numeric order.
$ordered = @($stages.Values | Sort-Object { $_.number })
for ($i = 0; $i -lt $ordered.Count; $i++) {
  if ($i -gt 0) {
    $ordered[$i].previous = [ordered]@{ number = $ordered[$i-1].number; name = $ordered[$i-1].name }
  }
  if ($i -lt $ordered.Count - 1) {
    $ordered[$i].next = [ordered]@{ number = $ordered[$i+1].number; name = $ordered[$i+1].name }
  }
}

foreach ($m in $monsters.Values) {
  foreach ($loc in $m.locations) {
    foreach ($stage in $stages.Values) {
      if ($stage.name -eq $loc -and $stage.monsters -notcontains $m.name) {
        $stage.monsters += $m.name
      }
    }
  }
}

# Also match monster names inside each stage's "enemies" list.
$monsterNames = @($monsters.Keys)
foreach ($stage in $stages.Values) {
  foreach ($enemy in $stage.enemies) {
    foreach ($mn in $monsterNames) {
      if ($enemy -match [regex]::Escape($mn) -and $stage.monsters -notcontains $mn) {
        $stage.monsters += $mn
      }
    }
  }
}

# Compute monster tiers once all stats are merged.
foreach ($m in $monsters.Values) {
  $tier = 1
  if ($m.health -gt 0) {
    $tier = [int][math]::Ceiling([math]::Log($m.health, 1.35))
    $tier = [math]::Max(1, [math]::Min(200, $tier))
  }
  $m.tier = $tier
}

# --------------------------------------------------------------------------
# 7. NPCs
# --------------------------------------------------------------------------
$npcs = [ordered]@{}
$pageExcerpts = @{}
foreach ($row in (Read-Sheet 'AllPages')) {
  if ($row.Title) { $pageExcerpts[$row.Title] = $row.Excerpt }
}
foreach ($row in (Read-Sheet 'NPCInfobox')) {
  $name = $row.SourcePage
  if ([string]::IsNullOrWhiteSpace($name)) { continue }
  $loc = Parse-StageRef $row.location
  $quote = ''
  if ($pageExcerpts.ContainsKey($name)) {
    $ex = $pageExcerpts[$name]
    if ($ex -match '\{\{Quotation\|([^|}]+)') { $quote = $matches[1].Trim() }
  }
  $npcs[$name] = [ordered]@{
    name         = $name
    gender       = $row.gender
    location     = $row.location
    stage_number = $(if ($loc) { $loc.number } else { $null })
    stage_name   = $(if ($loc) { $loc.name } else { '' })
    service      = $row.service
    mission      = $row.'mission'
    quote        = $quote
  }
}

# --------------------------------------------------------------------------
# 8. Skills
# --------------------------------------------------------------------------
$skills = @()
foreach ($row in (Read-Sheet 'SkillInfobox')) {
  if (-not $row.skillname) { continue }
  $skills += [ordered]@{
    name             = $row.skillname
    max_level        = $row.maxlevel
    points_required  = To-Int $row.pointsrequired
    base_stat        = $row.basestat
    max_stat         = $row.maxstat
    description      = $row.description
    skill_type       = $row.skilltype
  }
}

# --------------------------------------------------------------------------
# 9. Crafting
# --------------------------------------------------------------------------
$crafting = @()
foreach ($row in (Read-Sheet 'CraftingRecipe')) {
  if (-not $row.SourcePage) { continue }
  if ($row.name -or $row.items) {
    $crafting += [ordered]@{ name = $row.SourcePage; materials = @(To-List $row.items); effect = $row.effect }
  }
}

# --------------------------------------------------------------------------
# 10. Write JSON
# --------------------------------------------------------------------------
function Write-Json($data, [string]$fileName) {
  $path = Join-Path $OutDir $fileName
  if ($null -eq $data) {
    $json = '[]'
  } elseif ($data -is [System.Collections.ICollection] -and $data.Count -eq 0) {
    $json = '[]'
  } else {
    $json = $data | ConvertTo-Json -Depth 12
  }
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Output ("wrote {0} ({1:N0} bytes)" -f $path, (New-Object System.IO.FileInfo($path)).Length)
}

$config = [ordered]@{
  source         = 'Emberfall Wiki (helmet-heroes.fandom.com)'
  generated      = (Get-Date).ToString('yyyy-MM-dd')
  item_count     = $items.Count
  monster_count  = $monsters.Count
  stage_count    = $stages.Count
  npc_count      = $npcs.Count
  skill_count    = $skills.Count
}

Write-Json $items    'items.json'
Write-Json $monsters 'monsters.json'
Write-Json @($stages.Values | Sort-Object { $_.number }) 'stages.json'
Write-Json $npcs     'npcs.json'
Write-Json $skills   'skills.json'
Write-Json $crafting 'crafting.json'
Write-Json $config   'meta.json'
