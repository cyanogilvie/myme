# NAME

myme — Manipulation of MIME body parts

# SYNOPSIS

**package require Tcl 8.6-**  
**package require myme ?1.0.0?**

**myme::initialize** ?**-canonical** *type/subtype* ?**-param** {*key
value*}…? ?**-encoding** *value*? ?**-header** {*key value*}…??
(**-file** *name* \| **-string** *value* \| **-parts** {*token1* …
*tokenN*})  
**myme::finalize** *token* ?**-subordinates all** \| **dynamic** \|
**none**?  
**myme::getproperty** *token* ?*property* \| **-names**?  
**myme::getheader** *token* ?*key* \| **-names**?  
**myme::setheader** *token* *key value* ?**-mode write** \| **append**
\| **delete**?  
**myme::getbody** *token* ?**-decode**? ?**-command** *callback*
?**-blocksize** *octets*??  
**myme::copymessage** *token* *channel*  
**myme::buildmessage** *token*  
**myme::parseaddress** *string*  
**myme::parsedatetime** (*string* \| **-now**) *property*  
**myme::mapencoding** *encoding_name*  
**myme::reversemapencoding** *charset_type*

# DESCRIPTION

The **myme** package provides the commands to create and manipulate MIME
body parts. It is a fork of the **mime** package from tcllib (version
1.7.2), made self-contained: it depends on nothing outside the Tcl core.
See **DIFFERENCES FROM TCLLIB MIME** below.

**myme::initialize** ?**-canonical** *type/subtype* ?**-param** {*key value*}…? ?**-encoding** *value*? ?**-header** {*key value*}…?? (**-file** *name* \| **-string** *value* \| **-parts** {*token1* … *tokenN*})  
Creates a MIME part and returns a token representing it.

- If the **-canonical** option is present, then the body is in canonical
  (raw) form and is found by consulting either the **-file**,
  **-string**, or **-parts** option.

  In addition, both the **-param** and **-header** options may occur
  zero or more times to specify **Content-Type** parameters (e.g.,
  **charset**) and header keyword/values (e.g.,
  **Content-Disposition**), respectively.

  Also, **-encoding**, if present, specifies the
  **Content-Transfer-Encoding** when copying the body. If it is absent,
  an encoding is chosen based on the content.

- If the **-canonical** option is not present, then the MIME part
  contained in either the **-file** or the **-string** option is parsed,
  dynamically generating subordinates as appropriate.

**myme::finalize** *token* ?**-subordinates all** \| **dynamic** \| **none**?  
Destroys the MIME part represented by *token*. It returns an empty
string.

If the **-subordinates** option is present, it specifies which
subordinates should also be destroyed. The default value is **dynamic**,
destroying all subordinates which were created by **myme::initialize**
together with the containing body part.

**myme::getproperty** *token* ?*property* \| **-names**?  
Returns a string or a list of strings containing the properties of a
MIME part. If the command is invoked with the name of a specific
property, then the corresponding value is returned; instead, if
**-names** is specified, a list of all properties is returned;
otherwise, a dictionary of properties and values is returned.

The possible properties are:

**content**  
The type/subtype describing the content

**encoding**  
The “Content-Transfer-Encoding”

**params**  
A list of “Content-Type” parameters

**parts**  
A list of tokens for the part’s subordinates. This property is present
only if the MIME part has subordinates.

**size**  
The approximate size of the content (unencoded)

**myme::getheader** *token* ?*key* \| **-names**?  
Returns the header of a MIME part as a dictionary with
possibly-redundant keys.

If *key* is provided, then a list of values of matching names, without
regard to case, is returned.

If **-names** is provided, a list of all keys is returned.

**myme::setheader** *token* *key value* ?**-mode write** \| **append** \| **delete**?  
Sets, appends to, or deletes the header *key*. Returns a list of strings
containing the previous value associated with the key.

The value for **-mode** is one of:

**write**  
The *key*/*value* is either created or overwritten (the default).

**append**  
A new *value* is appended for the *key* (creating it as necessary).

**delete**  
All values associated with the key are removed (the *value* parameter is
ignored).

**myme::getbody** *token* ?**-decode**? ?**-command** *callback* ?**-blocksize** *octets*??  
Returns a string containing the body of the leaf MIME part represented
by *token* in canonical form.

If the **-command** option is present, then it is repeatedly invoked
with a fragment of the body as this:

    uplevel #0 $callback [list "data" $fragment]

(The **-blocksize** option, if present, specifies the maximum size of
each fragment passed to the callback.)

When the end of the body is reached, the callback is invoked as:

    uplevel #0 $callback "end"

Alternatively, if an error occurs, the callback is invoked as:

    uplevel #0 $callback [list "error" reason]

Regardless, the return value of the final invocation of the callback is
propagated upwards by **myme::getbody**.

If the **-command** option is absent, then the return value of
**myme::getbody** is a string containing the MIME part’s entire body.

If the option **-decode** is absent the return value computed above is
returned as is. This means that it will be in the charset specified for
the token and not the usual utf-8. If the option **-decode** is present
however the command will use the charset information associated with the
token to convert the string from its encoding into utf-8 before
returning it.

**myme::copymessage** *token* *channel*  
Writes the MIME part represented by *token* to *channel*, and returns an
empty string.

Line endings are written as **\n**, so the channel’s **-translation**
determines the line endings of the result: configure it as **crlf** to
produce wire format (as for SMTP). CRLF line endings already present in
the content are normalized first, so they are not doubled. The content
of parts with a **Content-Transfer-Encoding** of **binary** is written
without end-of-line translation.

**myme::buildmessage** *token*  
Returns the MIME part represented by *token* in wire format: as bytes
(the characters encoded in the system encoding), with CRLF line endings.
Line endings in the content are handled as for **myme::copymessage**.

**myme::parseaddress** *string*  
Takes a string containing one or more 822-style address specifications
and returns a list of dictionaries, one element for each address
specified in the argument. If the string contains more than one address
they will be separated by commas.

Each dictionary contains the properties below. Note that one or more of
these properties may be empty.

**address**  
local@domain

**comment**  
822-style comment

**domain**  
the domain part (rhs)

**error**  
non-empty on a parse error

**group**  
this address begins a group

**friendly**  
user-friendly rendering

**local**  
the local part (lhs)

**memberP**  
this address belongs to a group

**phrase**  
the phrase part

**proper**  
822-style address specification

**route**  
822-style route specification (obsolete)

**myme::parsedatetime** (*string* \| **-now**) *property*  
Takes a string containing an 822-style date-time specification and
returns the specified property.

The list of properties and their ranges are:

**hour**  
0 .. 23

**lmonth**  
January, February, …, December

**lweekday**  
Sunday, Monday, … Saturday

**mday**  
1 .. 31

**min**  
0 .. 59

**mon**  
1 .. 12

**month**  
Jan, Feb, …, Dec

**proper**  
822-style date-time specification

**rclock**  
elapsed seconds between then and now

**sec**  
0 .. 59

**wday**  
0 .. 6 (Sun .. Sat)

**weekday**  
Sun, Mon, …, Sat

**yday**  
1 .. 366

**year**  
1900 …

**zone**  
-720 .. 720 (minutes east of GMT)

**myme::mapencoding** *encoding_name*  
Maps Tcl encodings onto the proper names for their MIME charset type.
This is only done for encodings whose charset types were known. The
remaining encodings return ““.

**myme::reversemapencoding** *charset_type*  
Maps MIME charset types onto Tcl encoding names. Those that are unknown
return ““.

# DIFFERENCES FROM TCLLIB MIME

- The package is **myme** and its commands are in the **::myme**
  namespace, so it can be loaded alongside tcllib’s **mime**.

- No dependencies outside the Tcl core: tcllib’s **base64**, **md5** and
  **tcl::chan::memchan** are no longer needed, and **Trf** is no longer
  used when present (so the behaviour doesn’t change depending on
  whether it happens to be installed). Requires Tcl 8.6 or later.

- **copymessage** and **buildmessage** emit a single
  **Content-Transfer-Encoding** header (mime 1.7.2 emitted it twice for
  canonical leaf parts, which strict MTAs such as AWS SES reject).

- **copymessage** and **buildmessage** no longer double CRLF line
  endings in content (tcllib ticket 67ace2b948), and leave the content
  of **binary** parts untranslated.

- Large **-file** bodies encoded as **base64** are emitted as proper 76
  character lines (mime 1.7.2 produced over-length lines at each 32766
  byte read boundary without Trf).

- Multipart boundaries are generated without md5.

# EXAMPLE

``` tcl
package require myme

set msg [myme::initialize -canonical {text/plain; charset="UTF-8"} \
    -encoding 8bit -string "Hello\n"]
myme::setheader $msg From    "Sender <sender@example.com>"
myme::setheader $msg To      "<recipient@example.com>"
myme::setheader $msg Subject "Test"
set wire [myme::buildmessage $msg]
myme::finalize $msg
```

# SEE ALSO

RFC 2045, RFC 2046, RFC 2047, RFC 2049, RFC 822

# KEYWORDS

email, internet, mail, mime, rfc 2045, rfc 2046, rfc 2049, rfc 822

# LICENSE

BSD-style, see the file “license.terms” in the distribution.

Copyright © 1999-2000 Marshall T. Rose, and the other authors credited
in the source.
