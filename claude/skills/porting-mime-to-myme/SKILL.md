---
name: porting-mime-to-myme
description: Port Tcl code from tcllib's mime package to myme (a self-contained, bug-fixed fork), and write new code against myme correctly. Use when code calls mime::* commands (initialize, buildmessage, copymessage, getbody, getheader, setheader, parseaddress, parsedatetime, word_encode, field_decode), does `package require mime`, or uses myme::*; or when the user mentions myme, MIME message construction/parsing in Tcl, or AWS SES/SMTP raw messages built in Tcl.
---

# Porting from tcllib `mime` to `myme`

`myme` is a fork of tcllib's `mime` 1.7.2 with no dependencies outside
the Tcl core (Tcl 8.6+). It fixes many bugs and RFC compliance problems.
Where a fix meant changing behaviour, the fix won over compatibility, so
**a port is not just a rename**. Work through every section below for
each call site. The most important one is **2. Characters vs octets**:
getting it wrong silently produces mojibake or errors.

```tcl
package require myme
```

## 0. Find the call sites

```sh
grep -rnE 'package require mime|mime::|::mime\b' --include='*.tcl' --include='*.tm' .
grep -rnE 'word_encode|field_decode|word_decode|parsedatetime|parseaddress' --include='*.tcl' .
grep -rnE 'smtp::' --include='*.tcl' .     # see section 12
```

## 1. Mechanical rename

- `package require mime` becomes `package require myme`. Drop
  `package require base64`, `md5`, `Trf` or `tcl::chan::memchan` if they
  were only there for mime.
- `mime::cmd` and `::mime::cmd` become `myme::cmd`. The same goes for
  `namespace import mime::*`.
- Tokens are `::myme::N`. Code that pattern-matches tokens (`::mime::*`)
  needs updating.
- `mime::fcopy` and `mime::scopy` (unused internals) are gone.

## 2. Characters vs octets (THE big change)

`mime` was inconsistent. With 7bit/8bit, `buildmessage` encoded the
`-string` in the **system encoding**, but base64 and quoted-printable
treated it as **bytes**. Callers compensated in different ways. `myme`
has one consistent model:

| Thing | myme |
|---|---|
| `-string` for `-canonical text/*` | **characters**. They are encoded to the `charset` parameter when the part is created. If there is no charset and the text is non-ASCII, `charset=utf-8` is **added**. Characters the charset can't represent raise an error. |
| `-string` for any other `-canonical` type (image/*, application/*, message/*) | **octets** (no chars > U+00FF, otherwise error) |
| `-string` to parse (no `-canonical`) | **octets** of the whole message (otherwise error) |
| `-file` (any type, canonical or parsed) | read as **octets**, unchanged (no charset conversion, no charset added) |
| `getbody $tok` | **octets** (for text, in its charset) |
| `getbody $tok -decode` | **characters**: US-ASCII if no charset, UTF-8 for `message/global*`; invalid octets become U+FFFD, or raise an error with `-strict` |
| `buildmessage` | **octets** with CRLF line endings |
| `copymessage $tok $chan` | writes **octets**. The channel's `-encoding` is set to iso8859-1 for the duration and then restored, so the channel's encoding no longer matters. `-translation` still decides line endings. |
| header values (`setheader`, `-header`, `getheader`) | **characters** (see section 4) |
| Content-Type params (`-param`, `getproperty params`) | **characters** (see section 5) |

Porting rules:

- **Remove `encoding convertto` before `-string` for text parts.**
  `mime::initialize -canonical "text/plain; charset=utf-8" -string [encoding convertto utf-8 $text]`
  becomes `myme::initialize -canonical "text/plain; charset=utf-8" -string $text`.
  Keeping the convertto **double-encodes** (Ã© mojibake).
- Text that was passed as characters with 7bit/8bit (relying on the
  system encoding being UTF-8) is now correct by construction. Make sure
  the declared charset matches what you want: `charset=iso-8859-1` now
  really produces Latin-1 octets.
- **Non-text bodies must be octets.** Read files with
  `-translation binary` (`open $f rb`), or pass `-file`. Images and PDFs
  read in text mode were already broken. Now they error if any character
  is above U+00FF.
- **Messages to parse must be octets.** Read them in binary mode. If a
  message string came from a UTF-8 text channel, use
  `encoding convertto utf-8 $msg` first, or better, read it binary.
- **`buildmessage` output is octets.** For HTTP or JSON APIs that take a
  string of the raw message (for example AWS SES `Raw.Data` through a
  JSON template), check how the API layer treats it. Pure-ASCII messages
  are the same either way, and non-ASCII text bodies are encoded by their
  CTE (quoted-printable/base64) unless `-encoding 8bit` is given. To
  write it to a channel, use binary mode (`fconfigure $ch -translation binary`).
  `mime` returned system-encoded output, so code that did
  `encoding convertto utf-8 [mime::buildmessage ...]` must drop that.
- **`getbody` without `-decode` on a canonical text part now returns
  encoded octets, not the characters you passed in.** Add `-decode` if
  you want the text back.
- For text in a `-file`, the file's bytes must already be in the
  declared charset. Pass `-param {charset utf-8}` yourself, since no
  charset is inferred from a file.

## 3. Content-Transfer-Encoding

- Generated messages contain **exactly one** `Content-Transfer-Encoding`
  header. mime 1.7.2 emitted it twice for canonical leaf parts, which AWS
  SES and other strict MTAs reject. Workarounds that stripped the
  duplicate (`regsub`, header surgery on the `buildmessage` output) must
  be **removed**.
- Inference when `-encoding` is omitted:
  - CRLF line endings no longer count as non-ASCII or as trailing
    whitespace. CRLF text with short lines gets no CTE, where it used to
    become quoted-printable with `=0D` at line ends.
  - Non-ASCII text is never sent without a CTE (which declares 7bit).
    With no charset or an ISO-8859 charset you get quoted-printable;
    otherwise, including the auto-added utf-8, base64.
  - Pass `-encoding 8bit` or `quoted-printable` explicitly if you want a
    specific CTE.
- Quoted-printable text encodes CRLF as line breaks (not `=0D`), always
  encodes a lone `.` line and a leading `From ` correctly, and encodes
  `\x1F`.
- `-encoding base64` or `quoted-printable` with `-canonical multipart/*`
  or `message/*` is now an **error** (RFC 2045 §6.4). Use 7bit, 8bit or
  binary, or omit it.
- Re-serialising a *parsed* part copies its CTE header as-is:
  - None is invented if it had none (mime invented one, corrupting the
    body).
  - Unknown values such as `x-uuencode` no longer raise an error.
  - `Content-Transfer-Encoding: Base64 (comment)` is recognised.
- Body line endings: `buildmessage` no longer turns existing `\r\n` in
  content into `\r\r\n` (tcllib ticket 67ace2b948), and parts with
  `-encoding binary` are not line-translated at all. Remove any
  `string map {\r\n \n}` workarounds applied before `initialize`. They
  are harmless, but no longer needed.

## 4. Headers

- **Output folding:** header fields are folded at whitespace (never
  inside quoted-strings) into lines of at most 78 characters where
  possible.
  - A value containing a bare line break (`\n` or `\r` not followed by a
    space or tab) is an **error**. This blocks header injection. Strip or
    validate user-supplied values.
  - A line that can't be folded under 998 octets is an **error**.
  - Pre-folded values (`"a\n b"`) are unfolded and refolded.
  - Values are trimmed of surrounding whitespace.
- **Content-Type is emitted on one line**, folded like any other field:
  `Content-Type: text/plain; charset="utf-8"; name="x"`. mime used
  `;\n              ` between parameters. Tests or code that match the
  old layout need updating.
- **Non-ASCII header values:**
  - `Subject`, `Comments` and `Content-Description` are **automatically
    RFC 2047 encoded** (Q, UTF-8). Remove manual
    `word_encode`/`encoding convertto` calls for these. They are harmless
    if the result is ASCII, but no longer needed.
  - Other fields are written as raw UTF-8 (RFC 6532). For display names
    in From/To/Cc etc., which need RFC 2047 for non-SMTPUTF8 transports,
    encode the phrase yourself:
    `"[myme::word_encode utf-8 quoted-printable $name] <$addr>"`.
- Field names must be printable ASCII without `:`, otherwise error.
- **Parsing:**
  - Header fields are **unfolded** (RFC 5322 §2.2.3), so `getheader`
    returns `"hello world"` for `hello\n world`. mime kept the `\n`.
  - Raw values are decoded from **UTF-8** to characters where valid
    (RFC 6532), otherwise octet for character.
  - They are *not* RFC 2047 decoded: use `myme::field_decode`, as
    before.
- `getheader $tok Name` still returns a **list** of values. Use
  `lindex ... 0` for a single-valued field.

## 5. Content-Type parameters (RFC 2231)

- `-canonical` accepts inline parameters, which are parsed properly:
  `-canonical {text/plain; charset="UTF-8"}` gives content `text/plain`
  and params `charset UTF-8`. In mime, the whole string became the
  content type and parameters weren't seen; with myme's charset logic
  that would have produced a duplicate `charset`. Explicit `-param`
  values override inline ones.
- `getproperty $tok params` is a dictionary of **decoded** values:
  - RFC 2231 continuations (`name*0`, `name*1*`, ...) are joined.
  - Extended values (`title*=utf-8''%E2%82%AC`) are decoded and returned
    under the **plain name** (`title`, not `title*`).
  - Quoted-pairs `\"` and `\\` are undone (other backslashes are kept,
    for unescaped Windows paths).
  - Code that looked for `name*` keys, or decoded `%XX` itself, must be
    simplified.
- On output, parameter values are characters:
  - Short ASCII values are quoted with `"` and `\` escaped.
  - Long values use `name*0=`, `name*1=` continuations.
  - Non-ASCII values use `name*=utf-8''...`.
  - Pass Unicode filenames and the like **as characters**, with no
    pre-encoding.
  - A `-param` whose name already ends in `*` is emitted verbatim and
    unquoted.

## 6. Content-Disposition (and similar fields)

New helpers apply the same RFC 2231 handling to other parameterised
fields (RFC 2183):

```tcl
# attachment with a Unicode filename
set cd [myme::formatparams attachment [dict create filename $filename]]
set part [myme::initialize -canonical application/pdf -param [list name $filename] \
    -encoding base64 -string $pdfOctets -header [list Content-Disposition $cd]]

# reading one
lassign [myme::parseparams [lindex [myme::getheader $part Content-Disposition] 0]] disp params
set filename [dict get $params filename]     ;# characters, decoded
```

Replace hand-built `Content-Disposition` strings (`"attachment; filename=\"$f\""`),
which break on quotes and non-ASCII names.

## 7. Parsing differences

- **message/\* parts:** only `message/rfc822`, `message/global` and
  `message/news` are parsed as embedded messages, with a `parts` child.
  `message/delivery-status`, `message/disposition-notification`,
  `message/partial` and others are **leaves**. Code that did
  `getproperty $tok parts` on a delivery-status part and called
  `getheader` on the child must use `getbody $tok` instead, and parse
  the RFC 3464 fields from it (or `myme::initialize -string` the body to
  read the first group of fields as a header).
- Parts of `multipart/digest` with no Content-Type default to
  `message/rfc822` (they used to be text/plain).
- Multipart delimiters with trailing whitespace (transport padding) are
  recognised. mime failed the whole parse with "end-of-string
  encountered".
- A multipart `-string` without a close-delimiter no longer raises an
  error. It parses like `-file`: the last part runs to the end and is
  typed `application/octet-stream`.
- Parsing no longer depends on `::errorCode` existing. In mime, the
  first parse in a fresh interpreter could silently degrade multipart to
  text/plain (tcllib ticket 0534941436). Drop `catch {error x}` priming
  hacks.

## 8. Encoded-words: word_encode / field_decode

- **`word_encode` takes characters by default** (`-charset_encoded 0`).
  mime defaulted to 1, so the input had to be pre-encoded:
  - `mime::word_encode utf-8 quoted-printable [encoding convertto utf-8 $s]`
    becomes `myme::word_encode utf-8 quoted-printable $s`.
  - To keep passing octets, add `-charset_encoded 1`.
  - The first argument is a **Tcl** encoding name (`utf-8`, `iso8859-1`),
    as before.
- Q encoding now encodes every character except `[A-Za-z0-9!*+/-]` and
  space (which becomes `_`). Phrase specials like `,` `(` `<` `.` are
  encoded, so encoded-words are safe in address display names (RFC 2047
  §5(3)). Exact-output assertions on encoded words change.
- `field_decode`:
  - Encoded-words with an unknown charset, octets that aren't valid in
    their charset, or otherwise undecodable are **left as they are**. mime raised an error. Drop the `catch` if it
    was only for that, and check for leftover `=?...?=` if needed.
  - `=?charset*lang?...?=` (RFC 2231 §5) is accepted.
  - Encoded trailing spaces (`..._?=`) are no longer dropped (tcllib
    ticket d3f66f9a75).
- `qp_decode` handles CRLF soft line breaks (`=\r\n`).

## 9. parsedatetime

- Fields (`hour`, `mday`, `wday`, `month`, ...) are in the **date's own
  zone**, not the local zone. `"... 23:30:00 -0500" hour` is `23`
  everywhere; mime gave the local-zone hour. With `-now`, the local zone
  is used.
- `proper` keeps the zone given (`... 23:30:00 -0500`). mime converted
  to the local zone.
- `zone` works for numeric zones (mime raised "unrecognized
  timezone-mnemonic" for every numeric zone). Offsets beyond ±12h are
  accepted. Trailing comments like `(PDT)` are ignored.
- Missing, military or unknown alphabetic zones are taken as `-0000`,
  i.e. UTC (RFC 5322 §4.3). mime used local time for a missing zone and
  raised an error for unknown names.
- `clock` returns the epoch seconds. `lmonth` for September is spelled
  correctly (mime had "Sepember").
- The undocumented properties `date2gmt`, `date2local`, `dst`, `sday`,
  `szone` and `tzone` raise "unknown property", as before.

## 10. parseaddress

- A bare local part (`jdoe`) gives `address jdoe` and an empty `domain`.
  mime invented `jdoe@<info hostname>`. Add your own default domain
  explicitly if you relied on that.
- `friendly` has quoted-pairs undone (`John "JD" Doe`, not
  `John \"JD\" Doe`) and RFC 2047 encoded-words decoded.

## 11. Multipart output

- Generated boundaries look like `=_myme_<base64>`. mime used
  `----- =_<base64>`, which contains a space. Don't assert on the
  format, and read it with `regexp {boundary="([^"]+)"}`.

## 12. smtp is NOT ported

tcllib's `smtp` package calls `mime::*` on its token, so **`smtp::sendmessage` cannot take a myme token**.
Options:

- Build the message with `myme::buildmessage`, which gives octets with
  CRLF line endings, and send it with an SMTP client that takes raw
  messages, or an HTTP API such as AWS SES `SendEmail` with
  `Content.Raw.Data`.
- Or keep tcllib `mime`+`smtp` for that path only. Both packages can be
  loaded in the same interpreter, since the namespaces differ, but their
  tokens are not interchangeable.

## 13. Errors that are new in myme

| Situation | Error |
|---|---|
| text `-string` not representable in its charset | `-string has characters that charset "X" can't represent` |
| non-text canonical `-string` with chars > U+00FF | `-string for TYPE must be octets (bytes), ...` |
| parsed `-string` with chars > U+00FF | `-string must be the octets (bytes) of a message, ...` |
| unknown `charset` parameter on a text `-string` | `unknown charset "X"` |
| base64 or QP for multipart/message | `-encoding base64 not allowed for message/rfc822` |
| header value with a line break | `header field NAME: value contains a line break` |
| unfoldable header line > 998 octets | `header field NAME: a line is longer than 998 octets, ...` |
| bad header field name | `invalid header field name "X"` |
| `-canonical` value that isn't a valid type | parse errors such as `expecting type/subtype ...` |

## 14. Porting checklist

1. Rename the package and namespace (section 1).
2. For every `initialize -canonical text/* -string`, remove
   pre-encoding. For every other `-string`, make sure it is octets
   (section 2).
3. Every parse input must be octets: binary reads (section 2).
4. Every consumer of `buildmessage`, `copymessage` or `getbody` output
   must treat it as octets. Add `getbody -decode` where text was expected
   (section 2).
5. Remove duplicate-CTE and CRLF-doubling workarounds (section 3).
6. Remove manual Subject encoding. Validate header values that could
   contain newlines (section 4).
7. Update `params` and `name*` handling. Use `formatparams`/`parseparams`
   for Content-Disposition (sections 5 and 6).
8. Update code that walks `message/delivery-status` and similar parts
   (section 7).
9. Flip `word_encode` call sites that passed octets (section 8).
10. Re-check every `parsedatetime` and `parseaddress` use against
    sections 9 and 10.
11. Replace `smtp::sendmessage` usage (section 12).
12. Update tests asserting exact output: Content-Type layout, folding,
    boundaries, encoded-words, CTE choice.
