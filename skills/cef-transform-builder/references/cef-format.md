# CEF format reference (CEF:0)

Source: OpenText/Micro Focus **"Implementing ArcSight Common Event Format (CEF)"** (current
revision 27, ArcSight SmartConnectors 24.2). Emit the **`CEF:0`** version marker — it is the
universally parsed format; `CEF:1` is defined but not adopted.

## Message layout

```
CEF:0|Device Vendor|Device Product|Device Version|Signature ID|Name|Severity|Extension
```

Seven `|`-delimited **header** fields (all mandatory; empty allowed but the pipes must remain),
then a space-separated **Extension** of `key=value` pairs (optional). The whole message is UTF-8.
A syslog timestamp+host prefix often precedes `CEF:0` but is not part of CEF itself.

| # | Header field | Notes |
|---|--------------|-------|
| 0 | `CEF:0` | literal version marker |
| 1 | Device Vendor | vendor of the producing device |
| 2 | Device Product | product name (vendor+product uniquely identify the type) |
| 3 | Device Version | producing product/appliance version |
| 4 | Signature ID | unique id **per event type** (low cardinality) |
| 5 | Name | human-readable event description (stable, not per-event data) |
| 6 | Severity | integer 0–10 (or Low/Medium/High/Very-High/Unknown) |
| 7 | Extension | space-separated `key=value` pairs |

## Escaping (escape backslash FIRST)

| Char | Header field | Extension value |
|------|--------------|-----------------|
| `\` (backslash) | `\\` | `\\` |
| `|` (pipe) | `\|` | left as-is (allowed in extension values) |
| `=` (equals) | left as-is | `\=` |
| newline / CR | not allowed | encode as literal `\n` / `\r` |

The shared serializer (`templates/cef-serializer.yaml`) implements exactly this; per-source
mapping transforms must **not** escape.

## Severity

Integer **0–10**: Low 0–3 / Medium 4–6 / High 7–8 / Very-High 9–10 (higher = more important).
Emit the integer — most portable. Map ordinal source severities onto the buckets.

## Timestamps

Time fields (`rt`, `start`, `end`, `art`, `deviceCustomDate1/2`, `flexDate1`) accept **epoch
milliseconds** (13-digit) or `MMM dd yyyy HH:mm:ss[.SSS zzz]`. **Prefer epoch-ms** — no
locale/timezone ambiguity. The mapping (T1) emits epoch-ms, converting every source time
with the standard `to_epoch_ms` helper (SKILL.md, "Standard jq helpers").

## Extension keys

Prefer a standard dictionary key when one fits (`references/cef-extension-dictionary.json`;
`scripts/lookup-cef-key.sh`). For values with no dictionary home, use the paired custom slots and
**always send the label**: `cs1..cs6` (+`csNLabel`, ≤4000), `cn1..cn3` (+`cnNLabel`, Long),
`cfp1..cfp4` (+`cfpNLabel`, Float), `deviceCustomDate1..2` (+Label), `flexString1..2` (+Label),
`c6a1..c6a4` (+Label, IPv6). CEF permits arbitrary extension keys, but standard keys and custom
slots are what downstream SIEMs parse.

## Transport length

No CEF-level maximum, but the syslog transport caps apply (classic UDP/RFC 3164 ~1KB; TCP/TLS
RFC 5424 much larger). Keep individual custom-string values within their caps.
