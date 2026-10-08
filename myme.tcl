# myme.tcl - MIME body parts
#
# Forked from tcllib's mime 1.7.2 package, made self-contained (no
# dependencies outside the Tcl core).
#
# (c) 1999-2000 Marshall T. Rose
# (c) 2000      Brent Welch
# (c) 2000      Sandeep Tamhankar
# (c) 2000      Dan Kuchler
# (c) 2000-2001 Eric Melski
# (c) 2001      Jeff Hobbs
# (c) 2001-2008 Andreas Kupries
# (c) 2002-2003 David Welton
# (c) 2003-2008 Pat Thoyts
# (c) 2005      Benjamin Riefenstahl
# (c) 2013-2021 Poor Yorick
#
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#
# Influenced by Borenstein's/Rose's safe-tcl (circa 1993) and Darren New's
# unpublished package of 1999.
#

package require Tcl 8.6-

package provide myme 1.0.0

namespace eval ::myme {
    # Transfer encoders/decoders, called as:
    #   $encoding -mode encode|decode -- $data
    # (the calling convention of the Trf commands mime was written against)

    proc base64 {-mode what -- data} {
        switch -- $what {
            encode {
                binary encode base64 -maxlen 76 $data
            }
            decode {
                # Strict with respect to end of input, yet lax for
                # invalid characters outside of that.
                regsub -all -- {[^A-Za-z0-9+/]} $data {} data
                binary decode base64 -strict $data
            }
            default {
                error "unknown mode \"$what\""
            }
        }
    }

    proc quoted-printable {-mode what -- data} {
        switch -- $what {
            encode  {qp_encode $data}
            decode  {qp_decode $data}
            default {error "unknown mode \"$what\""}
        }
    }

    # tooctets --
    #
    #   Encodes the characters in string in the Tcl encoding enc, raising an
    #   error for characters that the encoding can't represent.

    if {[package vsatisfies [package provide Tcl] 9-]} {
        proc tooctets {enc string} {
            ::encoding convertto -profile strict $enc $string
        }
    } else {
        proc tooctets {enc string} {
            set octets [::encoding convertto $enc $string]
            if {[::encoding convertfrom $enc $octets] ne $string} {
                error "can't represent the characters in encoding $enc"
            }
            set octets
        }
    }

    # octetsP --
    #
    #   Is string a string of octets (no characters above U+00FF)?

    proc octetsP string {
        expr {![regexp {[^\x00-\xFF]} $string]}
    }

    # headerchars --
    #
    #   Decodes the octets of a header field from a message being parsed:
    #   UTF-8 (RFC 6532), or, failing that, octet for character.

    if {[package vsatisfies [package provide Tcl] 9-]} {
        proc headerchars octets {
            if {[catch {::encoding convertfrom -profile strict utf-8 $octets} chars]} {
                return $octets
            }
            set chars
        }
    } else {
        proc headerchars octets {
            set chars [::encoding convertfrom utf-8 $octets]
            if {[::encoding convertto utf-8 $chars] ne $octets} {
                return $octets
            }
            set chars
        }
    }
}

#
# state variables:
#
#     canonicalP: input is in its canonical form
#     content: type/subtype
#     params: dictionary (keys are lower-case)
#     encoding: transfer encoding
#     version: MIME-version
#     header: dictionary (keys are lower-case)
#     lowerL: list of header keys, lower-case
#     mixedL: list of header keys, mixed-case
#     value: either "file", "parts", or "string"
#
#     file: input file
#     fd: cached file-descriptor, typically for root
#     root: token for top-level part, for (distant) subordinates
#     offset: number of octets from beginning of file/string
#     count: length in octets of (encoded) content
#
#     parts: list of bodies (tokens)
#
#     string: input string
#
#     cid: last child-id assigned
#


namespace eval ::myme {
    variable mime
    array set mime {uid 0 cid 0 bid 0}

    # RFC 822 lexemes
    variable addrtokenL
    lappend addrtokenL \; , < > : . ( ) @ \" \[ ] \\
    variable addrlexemeL {
        LX_SEMICOLON LX_COMMA
        LX_LBRACKET  LX_RBRACKET
        LX_COLON     LX_DOT
        LX_LPAREN    LX_RPAREN
        LX_ATSIGN    LX_QUOTE
        LX_LSQUARE   LX_RSQUARE
        LX_QUOTE
    }

    # RFC 2045 lexemes
    variable typetokenL
    lappend typetokenL \; , < > : ? ( ) @ \" \[ \] = / \\
    variable typelexemeL {
        LX_SEMICOLON LX_COMMA
        LX_LBRACKET  LX_RBRACKET
        LX_COLON     LX_QUESTION
        LX_LPAREN    LX_RPAREN
        LX_ATSIGN    LX_QUOTE
        LX_LSQUARE   LX_RSQUARE
        LX_EQUALS    LX_SOLIDUS
        LX_QUOTE
    }

    variable encList {
        ascii US-ASCII
        big5 Big5
        cp1250 Windows-1250
        cp1251 Windows-1251
        cp1252 Windows-1252
        cp1253 Windows-1253
        cp1254 Windows-1254
        cp1255 Windows-1255
        cp1256 Windows-1256
        cp1257 Windows-1257
        cp1258 Windows-1258
        cp437 IBM437
        cp737 {}
        cp775 IBM775
        cp850 IBM850
        cp852 IBM852
        cp855 IBM855
        cp857 IBM857
        cp860 IBM860
        cp861 IBM861
        cp862 IBM862
        cp863 IBM863
        cp864 IBM864
        cp865 IBM865
        cp866 IBM866
        cp869 IBM869
        cp874 {}
        cp932 {}
        cp936 GBK
        cp949 {}
        cp950 {}
        dingbats {}
        ebcdic {}
        euc-cn EUC-CN
        euc-jp EUC-JP
        euc-kr EUC-KR
        gb12345 GB12345
        gb1988 GB1988
        gb2312 GB2312
        iso2022 ISO-2022
        iso2022-jp ISO-2022-JP
        iso2022-kr ISO-2022-KR
        iso8859-1 ISO-8859-1
        iso8859-2 ISO-8859-2
        iso8859-3 ISO-8859-3
        iso8859-4 ISO-8859-4
        iso8859-5 ISO-8859-5
        iso8859-6 ISO-8859-6
        iso8859-7 ISO-8859-7
        iso8859-8 ISO-8859-8
        iso8859-9 ISO-8859-9
        iso8859-10 ISO-8859-10
        iso8859-13 ISO-8859-13
        iso8859-14 ISO-8859-14
        iso8859-15 ISO-8859-15
        iso8859-16 ISO-8859-16
        jis0201 JIS_X0201
        jis0208 JIS_C6226-1983
        jis0212 JIS_X0212-1990
        koi8-r KOI8-R
        koi8-u KOI8-U
        ksc5601 KS_C_5601-1987
        macCentEuro {}
        macCroatian {}
        macCyrillic {}
        macDingbats {}
        macGreek {}
        macIceland {}
        macJapan {}
        macRoman {}
        macRomania {}
        macThai {}
        macTurkish {}
        macUkraine {}
        shiftjis Shift_JIS
        symbol {}
        tis-620 TIS-620
        unicode {}
        utf-8 UTF-8
    }

    variable encodings
    array set encodings $encList
    variable reversemap
    # Initialized at the bottom of the file

    variable encAliasList {
        ascii ANSI_X3.4-1968
        ascii iso-ir-6
        ascii ANSI_X3.4-1986
        ascii ISO_646.irv:1991
        ascii ASCII
        ascii ISO646-US
        ascii us
        ascii IBM367
        ascii cp367
        cp437 cp437
        cp437 437
        cp775 cp775
        cp850 cp850
        cp850 850
        cp852 cp852
        cp852 852
        cp855 cp855
        cp855 855
        cp857 cp857
        cp857 857
        cp860 cp860
        cp860 860
        cp861 cp861
        cp861 861
        cp861 cp-is
        cp862 cp862
        cp862 862
        cp863 cp863
        cp863 863
        cp864 cp864
        cp865 cp865
        cp865 865
        cp866 cp866
        cp866 866
        cp869 cp869
        cp869 869
        cp869 cp-gr
        cp936 CP936
        cp936 MS936
        cp936 Windows-936
        iso8859-1 ISO_8859-1:1987
        iso8859-1 iso-ir-100
        iso8859-1 ISO_8859-1
        iso8859-1 latin1
        iso8859-1 l1
        iso8859-1 IBM819
        iso8859-1 CP819
        iso8859-2 ISO_8859-2:1987
        iso8859-2 iso-ir-101
        iso8859-2 ISO_8859-2
        iso8859-2 latin2
        iso8859-2 l2
        iso8859-3 ISO_8859-3:1988
        iso8859-3 iso-ir-109
        iso8859-3 ISO_8859-3
        iso8859-3 latin3
        iso8859-3 l3
        iso8859-4 ISO_8859-4:1988
        iso8859-4 iso-ir-110
        iso8859-4 ISO_8859-4
        iso8859-4 latin4
        iso8859-4 l4
        iso8859-5 ISO_8859-5:1988
        iso8859-5 iso-ir-144
        iso8859-5 ISO_8859-5
        iso8859-5 cyrillic
        iso8859-6 ISO_8859-6:1987
        iso8859-6 iso-ir-127
        iso8859-6 ISO_8859-6
        iso8859-6 ECMA-114
        iso8859-6 ASMO-708
        iso8859-6 arabic
        iso8859-7 ISO_8859-7:1987
        iso8859-7 iso-ir-126
        iso8859-7 ISO_8859-7
        iso8859-7 ELOT_928
        iso8859-7 ECMA-118
        iso8859-7 greek
        iso8859-7 greek8
        iso8859-8 ISO_8859-8:1988
        iso8859-8 iso-ir-138
        iso8859-8 ISO_8859-8
        iso8859-8 hebrew
        iso8859-9 ISO_8859-9:1989
        iso8859-9 iso-ir-148
        iso8859-9 ISO_8859-9
        iso8859-9 latin5
        iso8859-9 l5
        iso8859-10 iso-ir-157
        iso8859-10 l6
        iso8859-10 ISO_8859-10:1992
        iso8859-10 latin6
        iso8859-14 iso-ir-199
        iso8859-14 ISO_8859-14:1998
        iso8859-14 ISO_8859-14
        iso8859-14 latin8
        iso8859-14 iso-celtic
        iso8859-14 l8
        iso8859-15 ISO_8859-15
        iso8859-15 Latin-9
        iso8859-16 iso-ir-226
        iso8859-16 ISO_8859-16:2001
        iso8859-16 ISO_8859-16
        iso8859-16 latin10
        iso8859-16 l10
        jis0201 X0201
        jis0208 iso-ir-87
        jis0208 x0208
        jis0208 JIS_X0208-1983
        jis0212 x0212
        jis0212 iso-ir-159
        ksc5601 iso-ir-149
        ksc5601 KS_C_5601-1989
        ksc5601 KSC5601
        ksc5601 korean
        shiftjis MS_Kanji
        utf-8 UTF8
    }

    namespace export {*}{
	copymessage finalize getbody getheader getproperty initialize
	mapencoding parseaddress parsedatetime reversemapencoding setheader
	uniqueID
    }
}

# ::myme::initialize --
#
#    Creates a MIME part, and returnes the MIME token for that part.
#
# Arguments:
#    args   Args can be any one of the following:
#                  ?-canonical type/subtype
#                  ?-param    {key value}?...
#                  ?-encoding value?
#                  ?-header   {key value}?... ?
#                  (-file name | -string value | -parts {token1 ... tokenN})
#
#       If the -canonical option is present, then the body is in
#       canonical (raw) form and is found by consulting either the -file,
#       -string, or -parts option.
#
#       In addition, both the -param and -header options may occur zero
#       or more times to specify "Content-Type" parameters (e.g.,
#       "charset") and header keyword/values (e.g.,
#       "Content-Disposition"), respectively.
#
#       Also, -encoding, if present, specifies the
#       "Content-Transfer-Encoding" when copying the body.
#
#       If the -canonical option is not present, then the MIME part
#       contained in either the -file or the -string option is parsed,
#       dynamically generating subordinates as appropriate.
#
# Results:
#    An initialized mime token.

proc ::myme::initialize args {

    variable mime

    set token [namespace current]::[incr mime(uid)]
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    if {[catch [list myme::initializeaux $token {*}$args] result eopts]} {
        catch {myme::finalize $token -subordinates dynamic}
        return -options $eopts $result
    }
    return $token
}

# ::myme::initializeaux --
#
#    Configures the MIME token created in myme::initialize based on
#       the arguments that myme::initialize supports.
#
# Arguments:
#       token  The MIME token to configure.
#    args   Args can be any one of the following:
#                  ?-canonical type/subtype
#                  ?-param    {key value}?...
#                  ?-encoding value?
#                  ?-header   {key value}?... ?
#                  (-file name | -string value | -parts {token1 ... tokenN})
#
# Results:
#       Either configures the mime token, or throws an error.

proc ::myme::initializeaux {token args} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    array set params [set state(params) {}]
    set state(encoding) {}
    set state(version) 1.0

    set state(header) {}
    set state(lowerL) {}
    set state(mixedL) {}

    set state(cid) 0

    set userheader 0

    set argc [llength $args]
    for {set argx 0} {$argx < $argc} {incr argx} {
        set option [lindex $args $argx]
        if {[incr argx] >= $argc} {
            error "missing argument to $option"
        }
        set value [lindex $args $argx]

        switch -- $option {
            -canonical {
                # May include parameters, which -param overrides
                lassign [parsetype $token $value] state(content) inline
                dict for {k v} $inline {
                    if {![info exists params($k)]} {
                        set params($k) $v
                    }
                }
                set state(params) [array get params]
            }

            -param {
                if {[llength $value] != 2} {
		    error "-param expects a key and a value, not $value"
                }
                set lower [string tolower [set mixed [lindex $value 0]]]
                if {[info exists params($lower)]} {
                    error "the $mixed parameter may be specified at most once"
                }

                set params($lower) [lindex $value 1]
                set state(params) [array get params]
            }

            -encoding {
		set value [string tolower $value[set value {}]]

                switch -- $value {
                    7bit - 8bit - binary - quoted-printable - base64 {
                    }

                    default {
                        error "unknown value for -encoding $state(encoding)"
                    }
                }
                set state(encoding) [string tolower $value]
            }

            -header {
                if {[llength $value] != 2} {
                    error "-header expects a key and a value, not $value"
                }
                set lower [string tolower [set mixed [lindex $value 0]]]
                if {$lower eq {content-type}} {
                    error "use -canonical instead of -header $value"
                }
                if {$lower eq {content-transfer-encoding}} {
                    error "use -encoding instead of -header $value"
                }
                if {$lower in {content-md5 mime-version}} {
                    error {don't go there...}
                }
                if {$lower ni $state(lowerL)} {
                    lappend state(lowerL) $lower
                    lappend state(mixedL) $mixed
                }

		set userheader 1

                array set header $state(header)
                lappend header($lower) [lindex $value 1]
                set state(header) [array get header]
            }

            -file {
                set state(file) $value
            }

            -parts {
                set state(parts) $value
            }

            -string {
                set state(string) $value

                set state(lines) [split $value \n]
                set state(lines.count) [llength $state(lines)]
                set state(lines.current) 0
            }

            -root {
                # the following are internal options

                set state(root) $value
            }

            -offset {
                set state(offset) $value
            }

            -count {
                set state(count) $value
            }

            -defaultcontent {
                # Content-Type when the part has none
                set state(defaultcontent) $value
            }

            -lineslist {
                set state(lines) $value
                set state(lines.count) [llength $state(lines)]
                set state(lines.current) 0
                #state(string) is needed, but will be built when required
                set state(string) {}
            }

            default {
                error "unknown option $option"
            }
        }
    }

    #We only want one of -file, -parts or -string:
    set valueN 0
    foreach value {file parts string} {
        if {[info exists state($value)]} {
            set state(value) $value
            incr valueN
        }
    }
    if {$valueN != 1 && ![info exists state(lines)]} {
        error {specify exactly one of -file, -parts, or -string}
    }

    if {[set state(canonicalP) [info exists state(content)]]} {
        switch -- $state(value) {
            file {
                set state(offset) 0
            }

            parts {
                switch -glob -- $state(content) {
                    text/*
                        -
                    image/*
                        -
                    audio/*
                        -
                    video/* {
                        error "-canonical $state(content) and -parts do not mix"
                    }

                    default {
                        if {$state(encoding) ne {}} {
                            error {-encoding and -parts do not mix}
                        }
                    }
                }
            }
            default {# Go ahead}
        }

        # Composite types are only allowed the identity encodings (RFC 2045
        # section 6.4, RFC 2046 section 5.2.1)
        if {
            [string match -nocase {multipart/*} $state(content)]
            ||
            [string match -nocase {message/*} $state(content)]
        } {
            if {$state(encoding) ni {{} 7bit 8bit binary}} {
                error "-encoding $state(encoding) not allowed for $state(content)"
            }
        }

        if {[lsearch -exact $state(lowerL) content-id] < 0} {
            lappend state(lowerL) content-id
            lappend state(mixedL) Content-ID

            array set header $state(header)
            lappend header(content-id) [uniqueID]
            set state(header) [array get header]
        }

        if {$state(value) eq {string}} {
            canonicaloctets $token
        }

        set state(version) 1.0
        return
    }

    if {$state(params) ne {}} {
        error {-param requires -canonical}
    }
    if {$state(encoding) ne {}} {
        error {-encoding requires -canonical}
    }
    if {$userheader} {
        error {-header requires -canonical}
    }
    if {[info exists state(parts)]} {
        error {-parts requires -canonical}
    }
    if {
        [info exists state(string)] && $state(string) ne {}
        && ![octetsP $state(string)]
    } {
        error {-string must be the octets (bytes) of a message, not characters above U+00FF}
    }

    if {[set fileP [info exists state(file)]]} {
        if {[set openP [info exists state(root)]]} {
            # FRINK: nocheck
            variable $state(root)
            upvar 0 $state(root) root

            set state(fd) $root(fd)
        } else {
            set state(root) $token
            set state(fd) [open $state(file) RDONLY]
            set state(offset) 0
            seek $state(fd) 0 end
            set state(count) [tell $state(fd)]

            fconfigure $state(fd) -translation binary
        }
    }

    set code [catch {myme::parsepart $token} result opts]

    if {$fileP} {
        if {!$openP} {
            unset state(root)
            catch {close $state(fd)}
        }
        unset state(fd)
    }

    return -options $opts $result
}

# ::myme::canonicaloctets --
#
#    Converts the -string of a canonical part to the octets of its body.
#    For text/* the string is characters, encoded in the charset parameter
#    (charset=utf-8 is added if there is none and the text isn't ASCII).
#    For other types the string must already be octets.

proc ::myme::canonicaloctets token {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    if {[string match -nocase text/* $state(content)]} {
        set charset {}
        foreach {k v} $state(params) {
            if {$k eq {charset}} {
                set charset $v
            }
        }
        if {$charset eq {}} {
            if {![regexp {[^\x00-\x7F]} $state(string)]} {
                return
            }
            set charset utf-8
            lappend state(params) charset utf-8
        }
        set enc [reversemapencoding $charset]
        if {$enc eq {}} {
            error "unknown charset \"$charset\""
        }
        if {[catch {tooctets $enc $state(string)} octets]} {
            error "-string has characters that charset \"$charset\" can't represent"
        }
        set state(string) $octets
    } elseif {![octetsP $state(string)]} {
        error "-string for $state(content) must be octets (bytes), not characters above U+00FF"
    }
}

# ::myme::parsepart --
#
#       Parses the MIME headers and attempts to break up the message
#       into its various parts, creating a MIME token for each part.
#
# Arguments:
#       token  The MIME token to parse.
#
# Results:
#       Throws an error if it has problems parsing the MIME token,
#       otherwise it just sets up the appropriate variables.

proc ::myme::parsepart {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    if {[set fileP [info exists state(file)]]} {
        seek $state(fd) [set pos $state(offset)] start
        set last [expr {$state(offset) + $state(count) - 1}]
    } else {
        set string $state(string)
    }

    set vline {}
    while 1 {
        set blankP 0
        if {$fileP} {
            if {($pos > $last) || ([set x [gets $state(fd) line]] <= 0)} {
                set blankP 1
            } else {
                incr pos [expr {$x + 1}]
            }
        } else {
	    if {$state(lines.current) >= $state(lines.count)} {
		set blankP 1
		set line {}
	    } else {
		set line [lindex $state(lines) $state(lines.current)]
		incr state(lines.current)
		set x [string length $line]
		if {$x == 0} {set blankP 1}
	    }
        }

         if {!$blankP && [string match *\r $line]} {
             set line [string range $line 0 $x-2]
             if {$x == 1} {
                 set blankP 1
             }
         }

        if {!$blankP && (
	    [string first { } $line] == 0
	    ||
	    [string first \t $line] == 0
	)} {
            # Unfold (RFC 5322 section 2.2.3)
            append vline $line
            continue
        }

        if {$vline eq {}} {
            if {$blankP} {
                break
            }

            set vline $line
            continue
        }

        set vline [headerchars $vline]
        if {
	    [set x [string first : $vline]] <= 0
	    ||
	    [set mixed [string trimright [
		string range $vline 0 [expr {$x - 1}]]]] eq {}
	} {
            error "improper line in header: $vline"
        }
        set value [string trim [string range $vline [expr {$x + 1}] end]]
        switch -- [set lower [string tolower $mixed]] {
            content-type {
                if {[info exists state(content)]} {
                    error "multiple Content-Type fields starting with $vline"
                }

                if {![catch {set x [parsetype $token $value]}]} {
                    set state(content) [lindex $x 0]
                    set state(params) [lindex $x 1]
                }
            }

            content-md5 {
            }

            content-transfer-encoding {
                # Drop comments, e.g. "base64 (encoded)" (RFC 2045 section
                # 6.1, RFC 5322 section 3.2.2)
                set value [string tolower [string trim [
                    regsub -all {\([^()]*\)} $value { }]]]
                if {
		    $state(encoding) ne {}
		    &&
		    $state(encoding) ne $value
		} {
                    error "multiple Content-Transfer-Encoding fields starting with $vline"
                }

                set state(encoding) $value
            }

            mime-version {
                set state(version) $value
            }

            default {
                if {[lsearch -exact $state(lowerL) $lower] < 0} {
                    lappend state(lowerL) $lower
                    lappend state(mixedL) $mixed
                }

                array set header $state(header)
                lappend header($lower) $value
                set state(header) [array get header]
            }
        }

        if {$blankP} {
            break
        }
        set vline $line
    }

    if {![info exists state(content)]} {
        if {[info exists state(defaultcontent)]} {
            set state(content) $state(defaultcontent)
            set state(params) {}
        } else {
            set state(content) text/plain
            set state(params) [list charset us-ascii]
        }
    }

    if {![string match multipart/* $state(content)]} {
        if {$fileP} {
            set x [tell $state(fd)]
            incr state(count) [expr {$state(offset) - $x}]
            set state(offset) $x
        } else {
            # rebuild string, this is cheap and needed by other functions
            set state(string) [join [
                lrange $state(lines) $state(lines.current) end] \n]
        }

        # Only these message/* types contain a message (RFC 2046 section
        # 5.2, RFC 6532 section 3.7, RFC 5537 section 4.3); others
        # (message/partial, message/delivery-status, ...) are leaves
        if {$state(content) in {message/rfc822 message/global message/news}} {
            # FRINK: nocheck
            variable [set child $token-[incr state(cid)]]

            set state(value) parts
            set state(parts) $child
            if {$fileP} {
                myme::initializeaux $child \
                    -file $state(file) -root $state(root) \
                    -offset $state(offset) -count $state(count)
            } else {
                if {[info exists state(encoding)]} {
                    set strng [join [
                        lrange $state(lines) $state(lines.current) end] \n]
                    switch -- $state(encoding) {
                        base64 -
                        quoted-printable {
                            set strng [$state(encoding) -mode decode -- $strng]
                        }
                        default {}
                    }
                    myme::initializeaux $child -string $strng
                } else {
                    myme::initializeaux $child -lineslist [
                        lrange $state(lines) $state(lines.current) end]
                }
            }
        }

        return
    }

    set state(value) parts

    set boundary {}
    foreach {k v} $state(params) {
        if {$k eq {boundary}} {
            set boundary $v
            break
        }
    }
    if {$boundary eq {}} {
        error "boundary parameter is missing in $state(content)"
    }
    if {[string trim $boundary] eq {}} {
        error "boundary parameter is empty in $state(content)"
    }

    if {$fileP} {
        set pos [tell $state(fd)]
            # This variable is like 'start', for the reasons laid out
            # below, in the other branch of this conditional.
            set initialpos $pos
        } else {
            # This variable is like 'start', a list of lines in the
            # part. This record is made even before we find a starting
            # boundary and used if we run into the terminating boundary
            # before a starting boundary was found. In that case the lines
            # before the terminator as recorded by tracelines are seen as
            # the part, or at least we attempt to parse them as a
            # part. See the forceoctet and nochild flags later. We cannot
            # use 'start' as that records lines only after the starting
            # boundary was found.
            set tracelines [list]
    }

    # The default Content-Type of the parts of a multipart/digest is
    # message/rfc822 (RFC 2046 section 5.1.5)
    if {$state(content) eq {multipart/digest}} {
        set childopts {-defaultcontent message/rfc822}
    } else {
        set childopts {}
    }

    set inP 0
    set moreP 1
    set forceoctet 0
    while {$moreP} {
        if {$fileP} {
            if {$pos > $last} {
                # We have run over the end of the part per the outer
                # information without finding a terminating boundary.
                # We now fake the boundary and force the parser to
                # give any new part coming of this a mime-type of
                # application/octet-stream regardless of header
                # information.
                set line "--$boundary--"
                set x [string length $line]
                set forceoctet 1
            } else {
                if {[set x [gets $state(fd) line]] < 0} {
                    error "end-of-file encountered while parsing $state(content)"
                }
            }
            incr pos [expr {$x + 1}]
        } else {
            if {$state(lines.current) >= $state(lines.count)} {
                # No close-delimiter: as for -file above (RFC 2049
                # robustness)
                set line "--$boundary--"
                set forceoctet 1
            } else {
                set line [lindex $state(lines) $state(lines.current)]
                incr state(lines.current)
                set x [string length $line]
            }
            set x [string length $line]
        }
        if {[string last \r $line] == $x - 1} {
            set line [string range $line 0 [expr {$x - 2}]]
            set crlf 2
        } else {
            set crlf 1
        }

        if {[string first --$boundary $line] != 0} {
             if {$inP && !$fileP} {
                 lappend start $line
             }
             continue
        } else {
            lappend tracelines $line
        }
        # Delimiter lines may have transport padding (RFC 2046 section
        # 5.1.1)
        set delim [string trimright $line " \t"]

        if {!$inP} {
            # Haven't seen the starting boundary yet. Check if the
            # current line contains this starting boundary.

            if {$delim eq "--$boundary"} {
                # Yes. Switch parser state to now search for the
                # terminating boundary of the part and record where
                # the part begins (or initialize the recorder for the
                # lines in the part).
                set inP 1
                if {$fileP} {
                    set start $pos
                } else {
                    set start [list]
                }
                continue
            } elseif {$delim eq "--$boundary--"} {
                # We just saw a terminating boundary before we ever
                # saw the starting boundary of a part. This forces us
                # to stop parsing, we do this by forcing the parser
                # into an accepting state. We will try to create a
                # child part based on faked start position or recorded
                # lines, or, if that fails, let the current part have
                # no children.

                # As an example note the test case mime-3.7 and the
                # referenced file "badmail1.txt".

                set inP 1
                if {$fileP} {
                    set start $initialpos
                } else {
                    set start $tracelines
                }
                set forceoctet 1
                # Fall through. This brings to the creation of the new
                # part instead of searching further and possible
                # running over the end.
            } else {
                continue
            }
        }

        # Looking for the end of the current part. We accept both a
        # terminating boundary and the starting boundary of the next
        # part as the end of the current part.

        if {[set moreP [string compare $delim --$boundary--]]
	    && $delim ne "--$boundary"} {

            # The current part has not ended, so we record the line
            # if we are inside a part and doing string parsing.
            if {$inP && !$fileP} {
                lappend start $line
            }
            continue
        }

        # The current part has ended. We now determine the exact
        # boundaries, create a mime part object for it and recursively
        # parse it deeper as part of that action.

        # FRINK: nocheck
        variable [set child $token-[incr state(cid)]]

        lappend state(parts) $child

        set nochild 0
        if {$fileP} {
            if {[set count [expr {$pos - ($start + $x + $crlf + 1)}]] < 0} {
                set count 0
            }
            if {$forceoctet} {
                if {[catch {
                    myme::initializeaux $child {*}$childopts \
                        -file $state(file) -root $state(root) \
                        -offset $start -count $count
                }]} {
                    set nochild 1
                    set state(parts) [lrange $state(parts) 0 end-1]
                } } else {
                myme::initializeaux $child {*}$childopts \
                    -file $state(file) -root $state(root) \
                    -offset $start -count $count
            }
            seek $state(fd) [set start $pos] start
        } else {
            if {$forceoctet} {
                if {[catch {
                    myme::initializeaux $child {*}$childopts -lineslist $start
                }]} {
                    set nochild 1
                    set state(parts) [lrange $state(parts) 0 end-1]
                }
            } else {
                myme::initializeaux $child {*}$childopts -lineslist $start
            }
            set start {}
        }
        if {$forceoctet && !$nochild} {
            variable $child
            upvar 0  $child childstate
            set childstate(content) application/octet-stream
        }
        set forceoctet 0
    }
}

# ::myme::parsetype --
#
#       Parses the string passed in and identifies the content-type and
#       params strings.
#
# Arguments:
#       token  The MIME token to parse.
#       string The content-type string that should be parsed.
#
# Results:
#       Returns the content and params for the string as a two element
#       tcl list.

proc ::myme::parsetype {token string} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    variable typetokenL
    variable typelexemeL

    set state(input)   $string
    set state(buffer)  {}
    set state(lastC)   LX_END
    set state(comment) {}
    set state(tokenL)  $typetokenL
    set state(lexemeL) $typelexemeL

    set code [catch {myme::parsetypeaux $token $string} result opts]

    unset {*}{
	state(input)
	state(buffer)
	state(lastC)
	state(comment)
	state(tokenL)
	state(lexemeL)
    }

    return -options $opts $result
}

# ::myme::parsetypeaux --
#
#       A helper function for myme::parsetype.  Parses the specified
#       string looking for the content type and params.
#
# Arguments:
#       token  The MIME token to parse.
#       string The content-type string that should be parsed.
#
# Results:
#       Returns the content and params for the string as a two element
#       tcl list.

proc ::myme::parsetypeaux {token string} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    if {[parselexeme $token] ne {LX_ATOM}} {
        error [format {expecting type (found %s)} $state(buffer)]
    }
    set type [string tolower $state(buffer)]

    switch -- [parselexeme $token] {
        LX_SOLIDUS {
        }

        LX_END {
            if {$type ne {message}} {
                error "expecting type/subtype (found $type)"
            }

            return [list message/rfc822 {}]
        }

        default {
            error [format "expecting \"/\" (found %s)" $state(buffer)]
        }
    }

    if {[parselexeme $token] ne {LX_ATOM}} {
        error [format "expecting subtype (found %s)" $state(buffer)]
    }
    append type [string tolower /$state(buffer)]

    array set params {}
    while 1 {
        switch -- [parselexeme $token] {
            LX_END {
                return [list $type [decodeparams [array get params]]]
            }

            LX_SEMICOLON {
            }

            default {
                error [format "expecting \";\" (found %s)" $state(buffer)]
            }
        }

        switch -- [parselexeme $token] {
            LX_END {
                return [list $type [decodeparams [array get params]]]
            }

            LX_ATOM {
            }

            default {
                error [format "expecting attribute (found %s)" $state(buffer)]
            }
        }

        set attribute [string tolower $state(buffer)]

        if {[parselexeme $token] ne {LX_EQUALS}} {
            error [format {expecting "=" (found %s)} $state(buffer)]
        }

        switch -- [parselexeme $token] {
            LX_ATOM {
            }

            LX_QSTRING {
                set state(buffer) [
                    string range $state(buffer) 1 [
                        expr {[string length $state(buffer)] - 2}]]
                # Undo the quoted-pairs a sender must use (RFC 2045 section
                # 5.1, RFC 5322 section 3.2.4), only for quotes and backslashes:
                # some senders don't escape backslashes in Windows paths
                set state(buffer) [string map [list \\\" \" \\\\ \\] $state(buffer)]
            }

            default {
                error [format {expecting value (found %s)} $state(buffer)]
            }
        }
        set params($attribute) $state(buffer)
    }
}

# ::myme::finalize --
#
#   myme::finalize destroys a MIME part.
#
#   If the -subordinates option is present, it specifies which
#   subordinates should also be destroyed. The default value is
#   "dynamic".
#
# Arguments:
#       token  The MIME token to parse.
#       args   Args can be optionally be of the following form:
#              ?-subordinates "all" | "dynamic" | "none"?
#
# Results:
#       Returns an empty string.

proc ::myme::finalize {token args} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    array set options [list -subordinates dynamic]
    array set options $args

    switch -- $options(-subordinates) {
        all {
            #TODO: this code path is untested
            if {$state(value) eq {parts}} {
                foreach part $state(parts) {
                    eval [linsert $args 0 myme::finalize $part]
                }
            }
        }

        dynamic {
            for {set cid $state(cid)} {$cid > 0} {incr cid -1} {
                eval [linsert $args 0 myme::finalize $token-$cid]
            }
        }

        none {
        }

        default {
            error "unknown value for -subordinates $options(-subordinates)"
        }
    }

    foreach name [array names state] {
        unset state($name)
    }
    # FRINK: nocheck
    unset $token
}

# ::myme::getproperty --
#
#   myme::getproperty returns the properties of a MIME part.
#
#   The properties are:
#
#       property    value
#       ========    =====
#       content     the type/subtype describing the content
#       encoding    the "Content-Transfer-Encoding"
#       params      a list of "Content-Type" parameters
#       parts       a list of tokens for the part's subordinates
#       size        the approximate size of the content (unencoded)
#
#   The "parts" property is present only if the MIME part has
#   subordinates.
#
#   If myme::getproperty is invoked with the name of a specific
#   property, then the corresponding value is returned; instead, if
#   -names is specified, a list of all properties is returned;
#   otherwise, a dictionary of properties is returned.
#
# Arguments:
#       token      The MIME token to parse.
#       property   One of 'content', 'encoding', 'params', 'parts', and
#                  'size'. Defaults to returning a dictionary of
#                  properties.
#
# Results:
#       Returns the properties of a MIME part

proc ::myme::getproperty {token {property {}}} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    switch -- $property {
        {} {
            array set properties [list content  $state(content) \
                                       encoding $state(encoding) \
                                       params   $state(params) \
                                       size     [getsize $token]]
            if {[info exists state(parts)]} {
                set properties(parts) $state(parts)
            }

            return [array get properties]
        }

        -names {
            set names [list content encoding params]
            if {[info exists state(parts)]} {
                lappend names parts
            }

            return $names
        }

        content
            -
        encoding
            -
        params {
            return $state($property)
        }

        parts {
            if {![info exists state(parts)]} {
                error {MIME part is a leaf}
            }

            return $state(parts)
        }

        size {
            return [getsize $token]
        }

        default {
            error "unknown property $property"
        }
    }
}

# ::myme::getsize --
#
#    Determine the size (in bytes) of a MIME part/token
#
# Arguments:
#       token      The MIME token to parse.
#
# Results:
#       Returns the size in bytes of the MIME token.

proc ::myme::getsize {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    switch -- $state(value)/$state(canonicalP) {
        file/0 {
            set size $state(count)
        }

        file/1 {
            return [file size $state(file)]
        }

        parts/0
            -
        parts/1 {
            set size 0
            foreach part $state(parts) {
                incr size [getsize $part]
            }

            return $size
        }

        string/0 {
            set size [string length $state(string)]
        }

        string/1 {
            return [string length $state(string)]
        }
        default {
            error "Unknown combination \"$state(value)/$state(canonicalP)\""
        }
    }

    if {$state(encoding) eq {base64}} {
        set size [expr {($size * 3 + 2) / 4}]
    }

    return $size
}


# ::myme::decodeparams --
#
#    Decodes RFC 2231 parameters: joins continuations (name*0, name*1, ...)
#    and decodes extended values (name*=charset'lang'%XX...) to characters,
#    returning them under the plain name.  An extended value takes
#    precedence over a plain one of the same name.
#
# Arguments:
#       params     Dictionary of parameters as they appear in the header.
#
# Results:
#       Dictionary of decoded parameters.

proc ::myme::decodeparams params {
    set result {}
    set extended {}
    set segments {}
    dict for {k v} $params {
        if {[regexp {^(.+?)\*([0-9]+)(\*?)$} $k - name n ext]} {
            dict set segments $name [scan $n %d] [list $ext $v]
        } elseif {[regexp {^(.+)\*$} $k - name]} {
            dict set extended $name [decodeextended $v]
        } else {
            dict set result $k $v
        }
    }

    dict for {name segs} $segments {
        set octets  {}
        set charset {}
        foreach n [lsort -integer [dict keys $segs]] {
            lassign [dict get $segs $n] ext v
            if {$ext eq {}} {
                append octets $v
                continue
            }
            if {$n == 0 && [regexp {^([^']*)'[^']*'(.*)$} $v - charset v]} {
                # charset'language' prefix on the first segment only
            }
            append octets [pctdecode $v]
        }
        dict set extended $name [extendedchars $charset $octets]
    }

    dict merge $result $extended
}

proc ::myme::decodeextended value {
    if {![regexp {^([^']*)'[^']*'(.*)$} $value - charset value]} {
        set charset {}
    }
    extendedchars $charset [pctdecode $value]
}

proc ::myme::pctdecode value {
    subst -novariables -nocommands [
        regsub -all {%([0-9A-Fa-f]{2})} [
            string map {\\ \\\\} $value] {\\x\1}]
}

proc ::myme::extendedchars {charset octets} {
    if {$charset eq {}} {
        return [headerchars $octets]
    }
    set enc [reversemapencoding $charset]
    if {$enc eq {}} {
        # Unknown charset: leave the octets as they are
        return $octets
    }
    ::encoding convertfrom $enc $octets
}

# ::myme::formatparam --
#
#    Formats a Content-Type (or Content-Disposition) parameter.  Values
#    that are ASCII and short enough are emitted as quoted-strings, others
#    with RFC 2231 continuations and, if not ASCII, as UTF-8 extended
#    values.  An attribute already ending in "*" is taken as a ready-made
#    extended value and emitted as-is.
#
# Arguments:
#       attribute  The parameter name.
#       value      The value (characters).
#
# Results:
#       A list of attribute=value strings, to be separated by "; ".

proc ::myme::formatparam {attribute value} {
    # Leaves room for the attribute and quotes within a 78 character line
    set max 60

    if {[string index $attribute end] eq "*"} {
        return [list $attribute=$value]
    }

    if {![regexp {[^\x20-\x7E]} $value]} {
        set quoted [string map {\\ \\\\ \" \\\"} $value]
        if {[string length $quoted] <= $max} {
            return [list "$attribute=\"$quoted\""]
        }
        # Continuations, not splitting a quoted-pair
        set result {}
        set n 0
        while {$quoted ne {}} {
            set seg [string range $quoted 0 $max-1]
            if {[regexp {(?:^|[^\\])(?:\\\\)*\\$} $seg]} {
                set seg [string range $seg 0 end-1]
            }
            lappend result "$attribute*$n=\"$seg\""
            set quoted [string range $quoted [string length $seg] end]
            incr n
        }
        return $result
    }

    # Extended value: utf-8, percent-encoding all but attribute-chars
    set pct {}
    foreach c [split [::encoding convertto utf-8 $value] {}] {
        if {[regexp {[A-Za-z0-9!#$&+.^_`|~-]} $c]} {
            append pct $c
        } else {
            append pct [format %%%02X [scan $c %c]]
        }
    }
    set pct "utf-8''$pct"
    if {[string length $pct] <= $max} {
        return [list "$attribute*=$pct"]
    }
    set result {}
    set n 0
    while {$pct ne {}} {
        set seg [string range $pct 0 $max-1]
        # Don't split a %XX
        if {[regexp {%[0-9A-F]?$} $seg tail]} {
            set seg [string range $seg 0 end-[string length $tail]]
        }
        lappend result "$attribute*$n*=$seg"
        set pct [string range $pct [string length $seg] end]
        incr n
    }
    return $result
}

# ::myme::parseparams --
#
#    Parses a header field value consisting of a token followed by
#    parameters, such as Content-Disposition (RFC 2183), decoding RFC 2231
#    parameters.
#
# Arguments:
#       value      The header field value.
#
# Results:
#       A list of the (lower-cased) token and a dictionary of the parameters.

proc ::myme::parseparams value {
    variable mime

    set token [namespace current]::[incr mime(uid)]
    # FRINK: nocheck
    variable $token
    try {
        lassign [parsetype $token x/$value] type params
    } finally {
        unset -nocomplain $token
    }
    list [string range $type 2 end] $params
}

# ::myme::formatparams --
#
#    The inverse of parseparams: formats a header field value from a token
#    and a dictionary of parameters, using RFC 2231 for values that are
#    long or not ASCII.
#
# Arguments:
#       value      The token, e.g. "attachment".
#       params     Dictionary of parameters.
#
# Results:
#       The header field value.

proc ::myme::formatparams {value params} {
    dict for {k v} $params {
        foreach p [formatparam $k $v] {
            append value "; $p"
        }
    }
    set value
}

# ::myme::headerwords --
#
#    Splits a header field value into words (runs of non-whitespace, with
#    quoted-strings kept whole) for folding.
#
# Arguments:
#       value      The header field value.
#
# Results:
#       A list of alternating preceding whitespace and word.

proc ::myme::headerwords value {
    set words  {}
    set ws     {}
    set word   {}
    set quoteP 0
    set escP   0
    foreach c [split $value {}] {
        if {$quoteP} {
            append word $c
            if {$escP} {
                set escP 0
            } elseif {$c eq "\\"} {
                set escP 1
            } elseif {$c eq "\""} {
                set quoteP 0
            }
        } elseif {$c eq { } || $c eq "\t"} {
            if {$word ne {}} {
                lappend words $ws $word
                set ws   {}
                set word {}
            }
            append ws $c
        } else {
            append word $c
            if {$c eq "\""} {
                set quoteP 1
            }
        }
    }
    lappend words $ws $word
}

# ::myme::formatheader --
#
#    Formats a header field for output: validates it, RFC 2047 encodes the
#    value of an unstructured field that isn't ASCII, folds it into lines of
#    at most 78 characters where possible (RFC 5322 section 2.1.1), and
#    encodes it as UTF-8 (RFC 6532).
#
# Arguments:
#       name       The field name.
#       value      The field value (characters).
#
# Results:
#       The field as octets, with \n line endings, including the last.

proc ::myme::formatheader {name value} {
    if {![regexp {^[\x21-\x39\x3B-\x7E]+$} $name]} {
        error "invalid header field name \"$name\""
    }

    # Unfold any folding already present: it is redone below
    regsub -all {\r?\n([ \t])} $value {\1} value
    # As parsing does
    set value [string trim $value]
    if {[regexp {[\r\n]} $value]} {
        error "header field $name: value contains a line break"
    }

    if {
        [string tolower $name] in {subject comments content-description}
        &&
        [regexp {[^\x00-\x7F]} $value]
    } {
        set value [word_encode utf-8 quoted-printable $value]
        regsub -all {\n } $value { } value
    }

    # Fold before whitespace, keeping lines within 78 characters where
    # there is whitespace to fold at
    set line   "$name:"
    set result {}
    foreach {ws word} [headerwords " $value"] {
        if {
            [string length $line] + [string length $ws$word] > 78
            &&
            [string trim $line] ne "$name:"
            &&
            $ws ne {}
        } {
            append result $line\n
            set line {}
        }
        append line $ws$word
    }
    append result $line\n

    set octets [::encoding convertto utf-8 $result]
    foreach l [split $octets \n] {
        if {[string length $l] > 998} {
            error "header field $name: a line is longer than 998 octets, and has no whitespace to fold at"
        }
    }
    set octets
}

proc ::myme::getContentType token {
    variable $token
    upvar 0 $token state
    set res $state(content)

    set boundary {}
    foreach {k v} $state(params) {
        if {$k eq {boundary}} {
	    set boundary $v
	}
        foreach p [formatparam $k $v] {
            append res "; $p"
        }
    }

    # Save boundary separate from the params
    set state(boundary) $boundary

    if {([string match multipart/* $state(content)]) \
        && ($boundary eq {})} {
        # we're doing everything in one pass...
        # The boundary only needs to be unique (not unpredictable), so
        # that it doesn't occur in the content of any of the parts
        variable mime
        set key [binary format IIW [pid] [incr mime(bid)] [clock microseconds]]
        append key [binary format I2 [list \
            [expr {int(rand()*0x100000000)}] \
            [expr {int(rand()*0x100000000)}]]]
        set boundary "=_myme_[base64 -mode encode -- $key]"

	set state(boundary) $boundary

        append res "; boundary=\"$boundary\""
    }
    return $res
}

# ::myme::getheader --
#
#    myme::getheader returns the header of a MIME part.
#
#    A header consists of zero or more key/value pairs. Each value is a
#    list containing one or more strings.
#
#    If myme::getheader is invoked with the name of a specific key, then
#    a list containing the corresponding value(s) is returned; instead,
#    if -names is specified, a list of all keys is returned; otherwise, a
#    dictionary is returned. Note that when a
#    key is specified (e.g., "Subject"), the list returned usually
#    contains exactly one string; however, some keys (e.g., "Received")
#    often occur more than once in the header, accordingly the list
#    returned usually contains more than one string.
#
# Arguments:
#       token      The MIME token to parse.
#       key        Either a key or '-names'.  If it is '-names' a list
#                  of all keys is returned.
#
# Results:
#       Returns the header of a MIME part.

proc ::myme::getheader {token {key {}}} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    array set header $state(header)
    switch -- $key {
        {} {
            set result {}
	    lappend result MIME-Version $state(version)
            foreach lower $state(lowerL) mixed $state(mixedL) {
		foreach value $header($lower) {
		    lappend result $mixed $value
		}
            }
	    set tencoding [getTransferEncoding $token]
	    if {$tencoding ne {}} {
		lappend result Content-Transfer-Encoding $tencoding
	    }
	    lappend result Content-Type [getContentType $token]
            return $result
        }

        -names {
            return $state(mixedL)
        }

        default {
            set lower [string tolower $key]

	    switch $lower {
		content-transfer-encoding {
		    return [getTransferEncoding $token]
		}
		content-type {
		    return [list [getContentType $token]]
		}
		mime-version {
		    return [list $state(version)]
		}
		default {
		    if {![info exists header($lower)]} {
			error "key $key not in header"
		    }
		    return $header($lower)
		}
	    }
        }
    }
}


# ::myme::getTransferEncoding --
#
#    Returns the Content-Transfer-Encoding for the part, or {} if it
#    shouldn't have one.  For a parsed (non-canonical) part this is whatever
#    its header said, since the body is copied verbatim; for a canonical
#    part it is the -encoding given, or one chosen to suit the content.

proc ::myme::getTransferEncoding token {
    variable $token
    upvar 0 $token state

    set encoding $state(encoding)
    if {!$state(canonicalP)} {
        return $encoding
    }

    if {$encoding eq {}} {
        set encoding [encoding $token]
    }
    switch -- $encoding {
        7bit - 8bit - binary - base64 - quoted-printable - {} {
            # Bugfix for [#477088], also [#539952]
        }
        default {
            error "Can't handle content encoding \"$encoding\""
        }
    }
    return $encoding
}

# ::myme::setheader --
#
#    myme::setheader writes, appends to, or deletes the value associated
#    with a key in the header.
#
#    The value for -mode is one of:
#
#       write: the key/value is either created or overwritten (the
#       default);
#
#       append: a new value is appended for the key (creating it as
#       necessary); or,
#
#       delete: all values associated with the key are removed (the
#       "value" parameter is ignored).
#
#    Regardless, myme::setheader returns the previous value associated
#    with the key.
#
# Arguments:
#       token      The MIME token to parse.
#       key        The name of the key whose value should be set.
#       value      The value for the header key to be set to.
#       args       An optional argument of the form:
#                  ?-mode "write" | "append" | "delete"?
#
# Results:
#       Returns previous value associated with the specified key.

proc ::myme::setheader {token key value args} {
    # FRINK: nocheck
    variable internal
    variable $token
    upvar 0 $token state

    array set options [list -mode write]
    array set options $args

    set lower [string tolower $key]
    array set header $state(header)
    if {[set x [lsearch -exact $state(lowerL) $lower]] < 0} {
        #TODO: this code path is not tested
        if {$options(-mode) eq {delete}} {
            error "key $key not in header"
        }

        lappend state(lowerL) $lower
        lappend state(mixedL) $key

        set result {}
    } else {
        set result $header($lower)
    }
    switch -- $options(-mode) {
	append - write {
	    if {!$internal} {
		switch -- $lower {
		    content-md5
			-
		    content-type
			-
		    content-transfer-encoding
			-
		    mime-version {
			set values [getheader $token $lower]
			if {$value ni $values} {
			    error "key $key may not be set"
			}
		    }
		    default {# Skip key}
		}
	    }
	    switch -- $options(-mode) {
		append {
		    lappend header($lower) $value
		}
		write {
		    set header($lower) [list $value]
		}
	    }
	}
        delete {
            unset header($lower)
            set state(lowerL) [lreplace $state(lowerL) $x $x]
            set state(mixedL) [lreplace $state(mixedL) $x $x]
        }

        default {
            error "unknown value for -mode $options(-mode)"
        }
    }

    set state(header) [array get header]
    return $result
}

# ::myme::getbody --
#
#    myme::getbody returns the body of a leaf MIME part in canonical form.
#
#    If the -command option is present, then it is repeatedly invoked
#    with a fragment of the body as this:
#
#        uplevel #0 $callback [list "data" $fragment]
#
#    (The -blocksize option, if present, specifies the maximum size of
#    each fragment passed to the callback.)
#    When the end of the body is reached, the callback is invoked as:
#
#        uplevel #0 $callback "end"
#
#    Alternatively, if an error occurs, the callback is invoked as:
#
#        uplevel #0 $callback [list "error" reason]
#
#    Regardless, the return value of the final invocation of the callback
#    is propagated upwards by myme::getbody.
#
#    If the -command option is absent, then the return value of
#    myme::getbody is a string containing the MIME part's entire body.
#
# Arguments:
#       token      The MIME token to parse.
#       args       Optional arguments of the form:
#                  ?-decode? ?-command callback ?-blocksize octets? ?
#
# Results:
#       Returns a string containing the MIME part's entire body, or
#       if '-command' is specified, the return value of the command
#       is returned.

proc ::myme::getbody {token args} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set decode 0
    if {[set pos [lsearch -exact $args -decode]] >= 0} {
        set decode 1
        set args [lreplace $args $pos $pos]
    }

    array set options [list -command [
        list myme::getbodyaux $token] -blocksize 4096]
    array set options $args
    if {$options(-blocksize) < 1} {
        error "-blocksize expects a positive integer, not $options(-blocksize)"
    }

    set code 0

    switch -- $state(value)/$state(canonicalP) {
        file/0 {
            set fd [open $state(file) RDONLY]

            set code [catch {
                fconfigure $fd -translation binary
                seek $fd [set pos $state(offset)] start
                set last [expr {$state(offset) + $state(count) - 1}]

                set fragment {}
                while {$pos <= $last} {
                    if {[set cc [
                        expr {($last - $pos) + 1}]] > $options(-blocksize)} {
                        set cc $options(-blocksize)
                    }
                    incr pos [set len [
                        string length [set chunk [read $fd $cc]]]]
                    switch -exact -- $state(encoding) {
                        base64
                            -
                        quoted-printable {
                            if {([set x [string last \n $chunk]] > 0) \
                                    && ($x + 1 != $len)} {
                                set chunk [string range $chunk 0 $x]
                                seek $fd [incr pos [expr {($x + 1) - $len}]] start
                            }
                            set chunk [
                                $state(encoding) -mode decode -- $chunk]
                        }
                        7bit - 8bit - binary - {} {
                            # Bugfix for [#477088]
                            # Go ahead, leave chunk alone
                        }
                        default {
                            error "Can't handle content encoding \"$state(encoding)\""
                        }
                    }
                    append fragment $chunk

                    set cc [expr {$options(-blocksize) - 1}]
                    while {[string length $fragment] > $options(-blocksize)} {
                        uplevel #0 $options(-command) [
                            list data [string range $fragment 0 $cc]]

                        set fragment [
                            string range $fragment $options(-blocksize) end]
                    }
                }
                if {[string length $fragment] > 0} {
                    uplevel #0 $options(-command) [list data $fragment]
                }
            } result opts]

            catch {close $fd}
        }

        file/1 {
            set fd [open $state(file) RDONLY]

            set code [catch {
                fconfigure $fd -translation binary

                while {[string length [
                    set fragment [read $fd $options(-blocksize)]]] > 0} {
                        uplevel #0 $options(-command) [list data $fragment]
                    }
            } result opts]

            catch {close $fd}
        }

        parts/0
            -
        parts/1 {
            error {MIME part isn't a leaf}
        }

        string/0
            -
        string/1 {
            switch -- $state(encoding)/$state(canonicalP) {
                base64/0
                    -
                quoted-printable/0 {
                    set fragment [
                        $state(encoding) -mode decode -- $state(string)]
                }

                default {
                    # Not a bugfix for [#477088], but clarification
                    # This handles no-encoding, 7bit, 8bit, and binary.
                    set fragment $state(string)
                }
            }

            set code [catch {
                set cc [expr {$options(-blocksize) -1}]
                while {[string length $fragment] > $options(-blocksize)} {
                    uplevel #0 $options(-command) [
                        list data [string range $fragment 0 $cc]]

                    set fragment [
                        string range $fragment $options(-blocksize) end]
                }
                if {[string length $fragment] > 0} {
                    uplevel #0 $options(-command) [list data $fragment]
                }
            } result opts]
        }
        default {
            error "Unknown combination \"$state(value)/$state(canonicalP)\""
        }
    }

    set code [catch {
        if {$code} {
            uplevel #0 $options(-command) [list error $result]
        } else {
            uplevel #0 $options(-command) [list end]
        }
    } result opts]

    if {$code} {
        return -options $opts $result
    }

    if {$decode} {
        array set params [myme::getproperty $token params]

        if {[info exists params(charset)]} {
            set charset $params(charset)
        } else {
            set charset US-ASCII
        }

        set enc [reversemapencoding $charset]
        if {$enc ne {}} {
            set result [::encoding convertfrom $enc $result]
        } else {
            return -code error "-decode failed: can't reversemap charset $charset"
        }
    }

    return $result
}

# ::myme::getbodyaux --
#
#    Builds up the body of the message, fragment by fragment.  When
#    the entire message has been retrieved, it is returned.
#
# Arguments:
#       token      The MIME token to parse.
#       reason     One of 'data', 'end', or 'error'.
#       fragment   The section of data data fragment to extract a
#                  string from.
#
# Results:
#       Returns nothing, except when called with the 'end' argument
#       in which case it returns a string that contains all of the
#       data that 'getbodyaux' has been called with.  Will throw an
#       error if it is called with the reason of 'error'.

proc ::myme::getbodyaux {token reason {fragment {}}} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    switch $reason {
        data {
            append state(getbody) $fragment
            return {}
        }

        end {
            if {[info exists state(getbody)]} {
                set result $state(getbody)
                unset state(getbody)
            } else {
                set result {}
            }

            return $result
        }

        error {
            catch {unset state(getbody)}
            error $reason
        }

        default {
            error "Unknown reason \"$reason\""
        }
    }
}

# ::myme::copymessage --
#
#    myme::copymessage copies the MIME part to the specified channel.
#
#    Line endings are written as \n, so the channel's -translation
#    determines the line endings of the result (set it to crlf for wire
#    format). The content of parts with a Content-Transfer-Encoding of
#    "binary" bypasses the translation.
#
# Arguments:
#       token      The MIME token to parse.
#       channel    The channel to copy the message to.
#
# Results:
#       Returns nothing unless an error is thrown while the message
#       is being written to the channel.

proc ::myme::copymessage {token channel} {
    # The message is octets
    set encoding [chan configure $channel -encoding]
    chan configure $channel -encoding iso8859-1
    try {
        copypart $token [list ::myme::chansink $channel]
        flush $channel
    } finally {
        chan configure $channel -encoding $encoding
    }
    return
}

# ::myme::buildmessage --
#
#     Like copymessage, but produces a string rather than writing the
#     message into a channel. The result is in wire format: CRLF line
#     endings, encoded as bytes in the system encoding.
#
# Arguments:
#       token      The MIME token to parse.
#
# Results:
#       The message.

proc ::myme::buildmessage token {
    set message {}
    copypart $token [list ::myme::stringsink [info level]]
    set message
}

# ::myme::chansink, ::myme::stringsink --
#
#    Destinations for copypart. Called as {*}$sink kind data, where kind
#    is "text" (line endings are \n, to be converted as appropriate for
#    the destination) or "binary" (to be passed through untouched).

proc ::myme::chansink {channel kind data} {
    if {$kind eq {binary}} {
        set translation [chan configure $channel -translation]
        chan configure $channel -translation lf
        try {
            puts -nonewline $channel $data
        } finally {
            chan configure $channel -translation $translation
        }
    } else {
        puts -nonewline $channel $data
    }
}

proc ::myme::stringsink {level kind data} {
    upvar #$level message message
    if {$kind eq {text}} {
        set data [string map {\n \r\n} $data]
    }
    append message $data
}

# ::myme::copypart --
#
#    Writes the MIME part to the sink, closing any file opened to do so.
#
# Arguments:
#       token      The MIME token to parse.
#       sink       Command prefix to write the message to, see chansink.
#
# Results:
#       Returns nothing unless an error is thrown while the message
#       is being written.

proc ::myme::copypart {token sink} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set openP [info exists state(fd)]

    try {
        copymessageaux $token $sink
    } finally {
        if {!$openP && [info exists state(fd)]} {
            if {![info exists state(root)]} {
                catch {close $state(fd)}
            }
            unset state(fd)
        }
    }
}

# ::myme::copymessageaux --
#
#    myme::copymessageaux writes the MIME part to the sink.
#
# Arguments:
#       token      The MIME token to parse.
#       sink       Command prefix to write the message to, see chansink.
#
# Results:
#       Returns nothing unless an error is thrown while the message
#       is being written.

proc ::myme::copymessageaux {token sink} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    # Includes Content-Transfer-Encoding
    set headers {}
    foreach {mixed value} [getheader $token] {
        append headers [formatheader $mixed $value]
    }
    {*}$sink text $headers

    set boundary $state(boundary) ;# computed by `getheader`

    # Body content in the "text" kind has its line endings normalized to
    # \n, so that existing CRLFs aren't doubled by the sink
    set converter {}
    set kind text
    if {$state(value) ne {parts}} {
        set encoding [getTransferEncoding $token]
        if {$encoding eq {binary}} {
            set kind binary
        } elseif {$state(canonicalP) && $encoding in {base64 quoted-printable}} {
            set converter $encoding
        }
    }
    # In quoted-printable text, line breaks are encoded as (CRLF) hard
    # line breaks, not =0D (RFC 2045 section 6.7 rule 4)
    if {$converter eq {quoted-printable} && [string match -nocase text/* $state(content)]} {
        set crlfP 1
    } else {
        set crlfP 0
    }

    switch -- $state(value) {
        file {
            set closeP 1
            if {[info exists state(root)]} {
                # FRINK: nocheck
                variable $state(root)
                upvar 0 $state(root) root

                if {[info exists root(fd)]} {
                    set fd $root(fd)
                    set closeP 0
                } else {
                    set fd [set state(fd) [open $state(file) RDONLY]]
                }
                set size $state(count)
            } else {
                set fd [set state(fd) [open $state(file) RDONLY]]
                # read until eof
                set size -1
            }
            seek $fd $state(offset) start
            if {$closeP} {
                fconfigure $fd -translation binary
            }

            switch -- $converter {
                base64 {
                    # A whole number of 76 character lines of output
                    # (57 bytes each) per chunk
                    set chunksize [expr {57 * 574}]
                }
                quoted-printable {
                    # In one piece, so that soft line breaks are
                    # consistent
                    set chunksize -1
                }
                default {
                    set chunksize 32766
                }
            }

            {*}$sink text \n

            set sep     {}
            set pending {}
            while {$size != 0 && ![eof $fd]} {
                set n $chunksize
                if {$size >= 0 && ($n < 0 || $n > $size)} {
                    set n $size
                }
                if {$n < 0} {
                    set X [read $fd]
                } else {
                    set X [read $fd $n]
                }
                if {$size > 0} {
                    set size [expr {$size - [string length $X]}]
                }

                if {$converter ne {}} {
                    if {$X eq {}} continue
                    if {$crlfP} {
                        # Only quoted-printable, which is read in one piece
                        set X [string map {\r\n \n} $X]
                    }
                    {*}$sink text $sep[$converter -mode encode -- $X]
                    set sep \n
                } elseif {$kind eq {binary}} {
                    {*}$sink binary $X
                } else {
                    # Hold back a trailing \r: its \n may start the
                    # next chunk
                    set X $pending$X
                    set pending {}
                    if {[string index $X end] eq "\r"} {
                        set pending \r
                        set X [string range $X 0 end-1]
                    }
                    {*}$sink text [string map {\r\n \n} $X]
                }
            }
            if {$pending ne {}} {
                {*}$sink text $pending
            }

            if {$closeP} {
                catch {close $state(fd)}
                unset state(fd)
            }
        }

        parts {
            if {
		![info exists state(root)]
		&&
		[info exists state(file)]
	    } {
                set state(fd) [open $state(file) RDONLY]
                fconfigure $state(fd) -translation binary
            }

            switch -glob -- $state(content) {
                message/* {
                    {*}$sink text \n
                    foreach part $state(parts) {
                        copypart $part $sink
                        break
                    }
                }

                default {
                    # Note RFC 2046:
                    #
                    # The boundary delimiter MUST occur at the
                    # beginning of a line, i.e., following a CRLF, and
                    # the initial CRLF is considered to be attached to
                    # the boundary delimiter line rather than part of
                    # the preceding part.
                    #
                    # - The above means that the CRLF before $boundary
                    #   is needed per the RFC, and the parts must not
                    #   have a closing CRLF of their own. See Tcllib bug
                    #   1213527, and patch 1254934 for the problems when
                    #   both file/string branches added CRLF after the
                    #   body parts.

                    foreach part $state(parts) {
                        {*}$sink text \n--$boundary\n
                        copypart $part $sink
                    }
                    {*}$sink text \n--$boundary--\n
                }
            }

            if {[info exists state(fd)]} {
                catch {close $state(fd)}
                unset state(fd)
            }
        }

        string {
            {*}$sink text \n

            if {$converter ne {}} {
                set X $state(string)
                if {$crlfP} {
                    set X [string map {\r\n \n} $X]
                }
                {*}$sink text [$converter -mode encode -- $X]
            } elseif {$kind eq {binary}} {
                {*}$sink binary $state(string)
            } else {
                {*}$sink text [string map {\r\n \n} $state(string)]
            }
        }
        default {
            error "Unknown value \"$state(value)\""
        }
    }
    return
}

# ::myme::encoding --
#
#     Determines how a token is encoded.
#
# Arguments:
#       token      The MIME token to parse.
#
# Results:
#       Returns the encoding of the message (the null string, base64,
#       or quoted-printable).

proc ::myme::encoding {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    switch -glob -- $state(content) {
        audio/*
            -
        image/*
            -
        video/* {
            return base64
        }

        message/*
            -
        multipart/* {
            return {}
        }
        default {# Skip}
    }

    set asciiP 1
    set lineP 1
    switch -- $state(value) {
        file {
            set fd [open $state(file) RDONLY]
            fconfigure $fd -translation binary

            while {[gets $fd line] >= 0} {
                # CRLF is a line ending, not content
                if {[string index $line end] eq "\r"} {
                    set line [string range $line 0 end-1]
                }
                if {$asciiP} {
                    set asciiP [encodingasciiP $line]
                }
                if {$lineP} {
                    set lineP [encodinglineP $line]
                }
                if {(!$asciiP) && (!$lineP)} {
                    break
                }
            }

            catch {close $fd}
        }

        parts {
            return {}
        }

        string {
            # CRLF is a line ending, not content
            foreach line [split [string map {\r\n \n} $state(string)] \n] {
                if {$asciiP} {
                    set asciiP [encodingasciiP $line]
                }
                if {$lineP} {
                    set lineP [encodinglineP $line]
                }
                if {(!$asciiP) && (!$lineP)} {
                    break
                }
            }
        }
        default {
            error "Unknown value \"$state(value)\""
        }
    }

    switch -glob -- $state(content) {
        text/* {
            if {!$asciiP} {
                foreach {k v} $state(params) {
                    if {$k eq "charset"} {
                        set v [string tolower $v]
                        if {($v ne "us-ascii") \
                                && (![string match {iso-8859-[1-8]} $v])} {
                            return base64
                        }

                        break
                    }
                }
                # Mostly ASCII: without a Content-Transfer-Encoding it
                # would be taken as 7bit (RFC 2045 section 6.1)
                return quoted-printable
            }

            if {!$lineP} {
                return quoted-printable
            }
        }


        default {
            if {(!$asciiP) || (!$lineP)} {
                return base64
            }
        }
    }

    return {}
}

# ::myme::encodingasciiP --
#
#     Checks if a string is a pure ascii string, or if it has a non-standard
#     form.
#
# Arguments:
#       line    The line to check.
#
# Results:
#       Returns 1 if \r only occurs at the end of lines, and if all
#       characters in the line are between the ASCII codes of 32 and 126.

proc ::myme::encodingasciiP {line} {
    foreach c [split $line {}] {
        switch -- $c {
            { } - \t - \r - \n {
            }

            default {
                scan $c %c c
                if {($c < 32) || ($c > 126)} {
                    return 0
                }
            }
        }
    }
    if {
	[set r [string first \r $line]] < 0
	||
	$r == [string length $line] - 1
    } {
        return 1
    }

    return 0
}

# ::myme::encodinglineP --
#
#     Checks if a string is a line is valid to be processed.
#
# Arguments:
#       line    The line to check.
#
# Results:
#       Returns 1 the line is less than 76 characters long, the line
#       contains more characters than just whitespace, the line does
#       not start with a '.', and the line does not start with 'From '.

proc ::myme::encodinglineP {line} {
    if {([string length $line] > 76) \
            || ($line ne [string trimright $line]) \
            || ([string first . $line] == 0) \
            || ([string first {From } $line] == 0)} {
        return 0
    }

    return 1
}

# ::myme::qp_encode --
#
#    Tcl version of quote-printable encode
#
# Arguments:
#    string        The string to quote.
#       encoded_word  Boolean value to determine whether or not encoded words
#                     (RFC 2047) should be handled or not. (optional)
#
# Results:
#    The properly quoted string is returned.

proc ::myme::qp_encode {string {encoded_word 0} {no_softbreak 0}} {
    # 8.1+ improved string manipulation routines used.
    # Replace outlying characters, characters that would normally
    # be munged by EBCDIC gateways, and special Tcl characters "[\]{}
    # with =xx sequence

    if {$encoded_word} {
        # Special processing for encoded words (RFC 2047)
        # Only the characters allowed in an encoded-word in any context
        # (including a phrase) are left literal (RFC 2047 section 5 (3))
        set regexp {[^A-Za-z0-9!*+/ -]}
	lappend mapChars { } _
    } else {
        set regexp {[\x00-\x08\x0B-\x1F\x21-\x24\x3D\x40\x5B-\x5E\x60\x7B-\xFF]}
    }
    regsub -all -- $regexp $string {[format =%02X [scan "\\&" %c]]} string

    # Replace the format commands with their result

    set string [subst -novariables $string]

    # soft/hard newlines and other
    # Funky cases for SMTP compatibility
    lappend mapChars " \n" =20\n \t\n =09\n

    set string [string map $mapChars $string]

    # Break long lines - ugh

    # Implementation of FR #503336
    if {$no_softbreak} {
        set result $string
    } else {
        set result {}
        foreach line [split $string \n] {
            while {[string length $line] > 72} {
                set chunk [string range $line 0 72]
                if {[regexp -- (=|=.)$ $chunk dummy end]} {

                    # Don't break in the middle of a code

                    set len [expr {72 - [string length $end]}]
                    set chunk [string range $line 0 $len]
                    incr len
                    set line [string range $line $len end]
                } else {
                    set line [string range $line 73 end]
                }
                append result $chunk=\n
            }
            append result $line\n
        }

        # Trim off last \n, since the above code has the side-effect
        # of adding an extra \n to the encoded string and return the
        # result.
        set result [string range $result 0 end-1]
    }

    if {!$encoded_word} {
        # Funky cases for SMTP compatibility: lines consisting of a lone
        # ".", or starting with "From ".  Done after the line breaking,
        # since that can produce such lines too
        regsub -all -line {^\.$} $result =2E result
        regsub -all -line {^From } $result {=46rom } result
    }

    # If the string ends in space or tab, replace with =xx

    set lastChar [string index $result end]
    if {$lastChar eq { }} {
        set result [string replace $result end end =20]
    } elseif {$lastChar eq "\t"} {
        set result [string replace $result end end =09]
    }

    return $result
}

# ::myme::qp_decode --
#
#    Tcl version of quote-printable decode
#
# Arguments:
#    string        The quoted-printable string to decode.
#       encoded_word  Boolean value to determine whether or not encoded words
#                     (RFC 2047) should be handled or not. (optional)
#
# Results:
#    The decoded string is returned.

proc ::myme::qp_decode {string {encoded_word 0}} {
    # 8.1+ improved string manipulation routines used.
    # Special processing for encoded words (RFC 2047)

    # smash the white-space at the ends of lines since that must've been
    # generated by an MUA.

    regsub -all -- {[ \t]+(\r?\n)} $string {\1} string
    set string [string trimright $string " \t"]

    if {$encoded_word} {
        # _ == \x20, even if SPACE occupies a different code position.
        # After the white-space smash: an encoded "_" at the end of an
        # encoded word is significant (tcllib ticket d3f66f9a75)
        set string [string map [list _ \u0020] $string]
    }

    # Protect the backslash for later subst and
    # smash soft newlines, has to occur after white-space smash
    # and any encoded word modification.

    #TODO: codepath not tested
    set string [string map [list \\ {\\} =\r\n {} =\n {}] $string]

    # Decode specials

    regsub -all -nocase {=([a-f0-9][a-f0-9])} $string {\\u00\1} string

    # process \u unicode mapped chars

    return [subst -novariables -nocommands $string]
}

# ::myme::parseaddress --
#
#       This was originally written circa 1982 in C. we're still using it
#       because it recognizes virtually every buggy address syntax ever
#       generated!
#
#       myme::parseaddress takes a string containing one or more 822-style
#       address specifications and returns a list of dictionaries, for each
#       address specified in the argument.
#
#    Each dictionary contains these properties:
#
#       property    value
#       ========    =====
#       address     local@domain
#       comment     822-style comment
#       domain      the domain part (rhs)
#       error       non-empty on a parse error
#       group       this address begins a group
#       friendly    user-friendly rendering
#       local       the local part (lhs)
#       memberP     this address belongs to a group
#       phrase      the phrase part
#       proper      822-style address specification
#       route       822-style route specification (obsolete)
#
#    Note that one or more of these properties may be empty.
#
# Arguments:
#    string        The address string to parse
#
# Results:
#    Returns a list of dictionaries, one element for each address
#       specified in the argument.

proc ::myme::parseaddress {string} {

    variable mime

    set token [namespace current]::[incr mime(uid)]
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set code [catch {myme::parseaddressaux $token $string} result opts]

    foreach name [array names state] {
        unset state($name)
    }
    # FRINK: nocheck
    catch {unset $token}

    return -options $opts $result
}

# ::myme::parseaddressaux --
#
#       This was originally written circa 1982 in C. we're still using it
#       because it recognizes virtually every buggy address syntax ever
#       generated!
#
#       myme::parseaddressaux does the actually parsing for myme::parseaddress
#
#    Each dictionary contains these properties:
#
#       property    value
#       ========    =====
#       address     local@domain
#       comment     822-style comment
#       domain      the domain part (rhs)
#       error       non-empty on a parse error
#       group       this address begins a group
#       friendly    user-friendly rendering
#       local       the local part (lhs)
#       memberP     this address belongs to a group
#       phrase      the phrase part
#       proper      822-style address specification
#       route       822-style route specification (obsolete)
#
#    Note that one or more of these properties may be empty.
#
# Arguments:
#    token         The MIME token to work from.
#    string        The address string to parse
#
# Results:
#    Returns a list of dictionaries, one for each address specified in the
#    argument.

proc ::myme::parseaddressaux {token string} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    variable addrtokenL
    variable addrlexemeL

    set state(input)   $string
    set state(glevel)  0
    set state(buffer)  {}
    set state(lastC)   LX_END
    set state(tokenL)  $addrtokenL
    set state(lexemeL) $addrlexemeL

    set result {}
    while {[addr_next $token]} {
        # No domain is invented for a bare local-part
        set address $state(local)
        if {$address ne {} && $state(domain) ne {}} {
            append address @$state(domain)
        }

        if {$state(phrase) ne {}} {
            #TODO: this path is not covered by tests
            set state(phrase) [string trim $state(phrase) \"]
            foreach t $state(tokenL) {
                if {[string first $t $state(phrase)] >= 0} {
                    #TODO:  is this quoting robust enough?
                    set state(phrase) \"$state(phrase)\"
                    break
                }
            }

            set proper "$state(phrase) <$address>"
        } else {
            set proper $address
        }

        if {[set friendly $state(phrase)] eq {}} {
            #TODO: this path is not covered by tests
            if {[set note $state(comment)] ne {}} {
                if {[string first ( $note] == 0} {
                    set note [string trimleft [string range $note 1 end]]
                }
                if {
		    [string last ) $note]
                        == [set len [expr {[string length $note] - 1}]]
		} {
                    set note [string range $note 0 [expr {$len - 1}]]
                }
                set friendly $note
            }

            if {
		$friendly eq {}
		&&
		[set mbox $state(local)] ne {}
	    } {
                #TODO: this path is not covered by tests
                set mbox [string trim $mbox \"]

                if {[string first / $mbox] != 0} {
                    set friendly $mbox
                } elseif {[set friendly [addr_x400 $mbox PN]] ne {}} {
                } elseif {
		    [set friendly [addr_x400 $mbox S]] ne {}
                    &&
		    [set g [addr_x400 $mbox G]] ne {}
		} {
                    set friendly "$g $friendly"
                }

                if {$friendly eq {}} {
                    set friendly $mbox
                }
            }
        }
        set friendly [string trim $friendly \"]
        # Undo quoted-pairs, and decode RFC 2047 encoded-words
        regsub -all {\\(.)} $friendly {\1} friendly
        set friendly [field_decode $friendly]

        lappend result [list address  $address        \
                             comment  $state(comment) \
                             domain   $state(domain)  \
                             error    $state(error)   \
                             friendly $friendly       \
                             group    $state(group)   \
                             local    $state(local)   \
                             memberP  $state(memberP) \
                             phrase   $state(phrase)  \
                             proper   $proper         \
                             route    $state(route)]

    }

    unset {*}{
	state(input)
	state(glevel)
	state(buffer)
	state(lastC)
	state(tokenL)
	state(lexemeL)
    }

    return $result
}

# ::myme::addr_next --
#
#       Locate the next address in a mime token.
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns 1 if there is another address, and 0 if there is not.

proc ::myme::addr_next {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state
    foreach prop {comment domain error group local memberP phrase route} {
        unset -nocomplain state($prop)
    }

    switch -- [set code [catch {myme::addr_specification $token} result opts]] {
        0 {
            if {!$result} {
                return 0
            }

            switch -- $state(lastC) {
                LX_COMMA
                    -
                LX_END {
                }
                default {
                    # catch trailing comments...
                    set lookahead $state(input)
                    myme::parselexeme $token
                    set state(input) $lookahead
                }
            }
        }

        7 {
            set state(error) $result

            while {1} {
                switch -- $state(lastC) {
                    LX_COMMA
                        -
                    LX_END {
                        break
                    }

                    default {
                        myme::parselexeme $token
                    }
                }
            }
        }

        default {

            return -options $opts $result
        }
    }

    foreach prop {comment domain error group local memberP phrase route} {
        if {![info exists state($prop)]} {
            set state($prop) {}
        }
    }

    return 1
}

# ::myme::addr_specification --
#
#   Uses lookahead parsing to determine whether there is another
#   valid e-mail address or not.  Throws errors if unrecognized
#   or invalid e-mail address syntax is used.
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns 1 if there is another address, and 0 if there is not.

proc ::myme::addr_specification {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set lookahead $state(input)
    switch -- [parselexeme $token] {
        LX_ATOM
            -
        LX_QSTRING {
            set state(phrase) $state(buffer)
        }

        LX_SEMICOLON {
            if {[incr state(glevel) -1] < 0} {
                return -code 7 "extraneous semi-colon"
            }

            catch {unset state(comment)}
            return [addr_specification $token]
        }

        LX_COMMA {
            catch {unset state(comment)}
            return [addr_specification $token]
        }

        LX_END {
            return 0
        }

        LX_LBRACKET {
            return [addr_routeaddr $token]
        }

        LX_ATSIGN {
            set state(input) $lookahead
            return [addr_routeaddr $token 0]
        }

        default {
            return -code 7 [
		format "unexpected character at beginning (found %s)" \
		   $state(buffer)]
        }
    }

    switch -- [parselexeme $token] {
        LX_ATOM
            -
        LX_QSTRING {
            append state(phrase) " " $state(buffer)

            return [addr_phrase $token]
        }

        LX_LBRACKET {
            return [addr_routeaddr $token]
        }

        LX_COLON {
            return [addr_group $token]
        }

        LX_DOT {
            set state(local) "$state(phrase)$state(buffer)"
            unset state(phrase)
            myme::addr_routeaddr $token 0
            myme::addr_end $token
        }

        LX_ATSIGN {
            set state(memberP) $state(glevel)
            set state(local) $state(phrase)
            unset state(phrase)
            myme::addr_domain $token
            myme::addr_end $token
        }

        LX_SEMICOLON
            -
        LX_COMMA
            -
        LX_END {
            set state(memberP) $state(glevel)
            if {
		$state(lastC) eq "LX_SEMICOLON"
		&&
		([incr state(glevel) -1] < 0)
	    } {
                #TODO: this path is not covered by tests
                return -code 7 "extraneous semi-colon"
            }

            set state(local) $state(phrase)
            unset state(phrase)
        }

        default {
            return -code 7 [
                format "expecting mailbox (found %s)" $state(buffer)]
        }
    }

    return 1
}

# ::myme::addr_routeaddr --
#
#       Parses the domain portion of an e-mail address.  Finds the '@'
#       sign and then calls myme::addr_route to verify the domain.
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns 1 if there is another address, and 0 if there is not.

proc ::myme::addr_routeaddr {token {checkP 1}} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set lookahead $state(input)
    if {[parselexeme $token] eq "LX_ATSIGN"} {
        #TODO: this path is not covered by tests
        myme::addr_route $token
    } else {
        set state(input) $lookahead
    }

    myme::addr_local $token

    switch -- $state(lastC) {
        LX_ATSIGN {
            myme::addr_domain $token
        }

        LX_SEMICOLON
            -
        LX_RBRACKET
            -
        LX_COMMA
            -
        LX_END {
        }

        default {
            return -code 7 [
                format "expecting at-sign after local-part (found %s)" \
                $state(buffer)]
        }
    }

    if {($checkP) && ($state(lastC) ne "LX_RBRACKET")} {
        return -code 7 [
            format "expecting right-bracket (found %s)" $state(buffer)]
    }

    return 1
}

# ::myme::addr_route --
#
#    Attempts to parse the portion of the e-mail address after the @.
#    Tries to verify that the domain definition has a valid form.
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.

proc ::myme::addr_route {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set state(route) @

    while 1 {
        switch -- [parselexeme $token] {
            LX_ATOM
                -
            LX_DLITERAL {
                append state(route) $state(buffer)
            }

            default {
                return -code 7 \
                       [format "expecting sub-route in route-part (found %s)" \
                               $state(buffer)]
            }
        }

        switch -- [parselexeme $token] {
            LX_COMMA {
                append state(route) $state(buffer)
                while 1 {
                    switch -- [parselexeme $token] {
                        LX_COMMA {
                        }

                        LX_ATSIGN {
                            append state(route) $state(buffer)
                            break
                        }

                        default {
                            return -code 7 \
                                   [format "expecting at-sign in route (found %s)" \
                                           $state(buffer)]
                        }
                    }
                }
            }

            LX_ATSIGN
                -
            LX_DOT {
                append state(route) $state(buffer)
            }

            LX_COLON {
                append state(route) $state(buffer)
                return
            }

            default {
                return -code 7 [
		    format "expecting colon to terminate route (found %s)" \
			$state(buffer)]
            }
        }
    }
}

# ::myme::addr_domain --
#
#    Attempts to parse the portion of the e-mail address after the @.
#    Tries to verify that the domain definition has a valid form.
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.

proc ::myme::addr_domain {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    while 1 {
        switch -- [parselexeme $token] {
            LX_ATOM
                -
            LX_DLITERAL {
                append state(domain) $state(buffer)
            }

            default {
                return -code 7 [
		    format "expecting sub-domain in domain-part (found %s)" \
			$state(buffer)]
            }
        }

        switch -- [parselexeme $token] {
            LX_DOT {
                append state(domain) $state(buffer)
            }

            LX_ATSIGN {
                append state(local) % $state(domain)
                unset state(domain)
            }

            default {
                return
            }
        }
    }
}

# ::myme::addr_local --
#
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.

proc ::myme::addr_local {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set state(memberP) $state(glevel)

    while 1 {
        switch -- [parselexeme $token] {
            LX_ATOM
                -
            LX_QSTRING {
                append state(local) $state(buffer)
            }

            default {
                return -code 7 \
                       [format "expecting mailbox in local-part (found %s)" \
                               $state(buffer)]
            }
        }

        switch -- [parselexeme $token] {
            LX_DOT {
                append state(local) $state(buffer)
            }

            default {
                return
            }
        }
    }
}

# ::myme::addr_phrase --
#
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.


proc ::myme::addr_phrase {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    while {1} {
        switch -- [parselexeme $token] {
            LX_ATOM
                -
            LX_QSTRING {
                append state(phrase) " " $state(buffer)
            }

            default {
                break
            }
        }
    }

    switch -- $state(lastC) {
        LX_LBRACKET {
            return [addr_routeaddr $token]
        }

        LX_COLON {
            return [addr_group $token]
        }

        LX_DOT {
            append state(phrase) $state(buffer)
            return [addr_phrase $token]
        }

        default {
            return -code 7 [
		format "found phrase instead of mailbox (%s%s)" \
		    $state(phrase) $state(buffer)]
        }
    }
}

# ::myme::addr_group --
#
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.

proc ::myme::addr_group {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    if {[incr state(glevel)] > 1} {
        return -code 7 [
	    format "nested groups not allowed (found %s)" $state(phrase)]
    }

    set state(group) $state(phrase)
    unset state(phrase)

    set lookahead $state(input)
    while 1 {
        switch -- [parselexeme $token] {
            LX_SEMICOLON
                -
            LX_END {
                set state(glevel) 0
                return 1
            }

            LX_COMMA {
            }

            default {
                set state(input) $lookahead
                return [addr_specification $token]
            }
        }
    }
}

# ::myme::addr_end --
#
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.

proc ::myme::addr_end {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    switch -- $state(lastC) {
        LX_SEMICOLON {
            if {[incr state(glevel) -1] < 0} {
                return -code 7 "extraneous semi-colon"
            }
        }

        LX_COMMA
            -
        LX_END {
        }

        default {
            return -code 7 [
		format "junk after local@domain (found %s)" $state(buffer)]
        }
    }
}

# ::myme::addr_x400 --
#
#
# Arguments:
#       token         The MIME token to work from.
#
# Results:
#    Returns nothing if successful, and throws an error if invalid
#       syntax is found.

proc ::myme::addr_x400 {mbox key} {
    if {[set x [string first /$key= [string toupper $mbox]]] < 0} {
        return {}
    }
    set mbox [string range $mbox [expr {$x + [string length $key] + 2}] end]

    if {[set x [string first / $mbox]] > 0} {
        set mbox [string range $mbox 0 [expr {$x - 1}]]
    }

    return [string trim $mbox \"]
}

# ::myme::parsedatetime --
#
#    Fortunately the clock command in the Tcl 8.x core does all the heavy
#    lifting for us (except for timezone calculations).
#
#    myme::parsedatetime takes a string containing an 822-style date-time
#    specification and returns the specified property.
#
#    The list of properties and their ranges are:
#
#       property     range
#       ========     =====
#       clock        raw result of "clock scan"
#       hour         0 .. 23
#       lmonth       January, February, ..., December
#       lweekday     Sunday, Monday, ... Saturday
#       mday         1 .. 31
#       min          0 .. 59
#       mon          1 .. 12
#       month        Jan, Feb, ..., Dec
#       proper       822-style date-time specification
#       rclock       elapsed seconds between then and now
#       sec          0 .. 59
#       wday         0 .. 6 (Sun .. Mon)
#       weekday      Sun, Mon, ..., Sat
#       yday         1 .. 366
#       year         1900 ...
#       zone         -720 .. 720 (minutes east of GMT)
#
# Arguments:
#       value       Either a 822-style date-time specification or '-now'
#                   if the current date/time should be used.
#       property    The property (from the list above) to return
#
# Results:
#    Returns the string value of the 'property' for the date/time that was
#       specified in 'value'.

namespace eval ::myme {
        variable WDAYS_SHORT  [list Sun Mon Tue Wed Thu Fri Sat]
        variable WDAYS_LONG   [list Sunday Monday Tuesday Wednesday Thursday \
                                    Friday Saturday]

        # Counting months starts at 1, so just insert a dummy element
        # at index 0.
        variable MONTHS_SHORT [list {} \
                                    Jan Feb Mar Apr May Jun \
                                    Jul Aug Sep Oct Nov Dec]
        variable MONTHS_LONG  [list {} \
                                    January February March April May June July \
                                    August September October November December]
}
proc ::myme::parsedatetime {value property} {
    if {$value eq "-now"} {
        set clock [clock seconds]
        # Local time
        set tzopt {}
        set z [clock format $clock -format %z]
        scan $z %1s%2d%2d sign h m
        set zone [expr {($sign eq "-" ? -1 : 1) * ($h * 60 + $m)}]
    } else {
        lassign [datezone $value] datetime zone
        set clock [expr {[clock scan $datetime -gmt 1] - $zone * 60}]
        # The fields are those of the date-time as given, in its own zone
        set tzopt [list -timezone [format %s%02d%02d \
            [expr {$zone < 0 ? "-" : "+"}] \
            [expr {abs($zone) / 60}] [expr {abs($zone) % 60}]]]
    }

    switch -- $property {
        clock {
            return $clock
        }

        hour {
            set value [clock format $clock -format %H {*}$tzopt]
        }

        lmonth {
            variable MONTHS_LONG
            return [lindex $MONTHS_LONG \
                            [scan [clock format $clock -format %m {*}$tzopt] %d]]
        }

        lweekday {
            variable WDAYS_LONG
            return [lindex $WDAYS_LONG [clock format $clock -format %w {*}$tzopt]]
        }

        mday {
            set value [clock format $clock -format %d {*}$tzopt]
        }

        min {
            set value [clock format $clock -format %M {*}$tzopt]
        }

        mon {
            set value [clock format $clock -format %m {*}$tzopt]
        }

        month {
            variable MONTHS_SHORT
            return [lindex $MONTHS_SHORT [
		scan [clock format $clock -format %m {*}$tzopt] %d]]
        }

        proper {
            # Locale independent day and month names
            variable WDAYS_SHORT
            variable MONTHS_SHORT
            set wday [lindex $WDAYS_SHORT [clock format $clock -format %w {*}$tzopt]]
            set mon [lindex $MONTHS_SHORT [
		scan [clock format $clock -format %m {*}$tzopt] %d]]

            return [
		clock format $clock -format "$wday, %d $mon %Y %H:%M:%S %z" {*}$tzopt]
        }

        rclock {
            return [expr {[clock seconds] - $clock}]
        }

        sec {
            set value [clock format $clock -format %S {*}$tzopt]
        }

        wday {
            return [clock format $clock -format %w {*}$tzopt]
        }

        weekday {
            variable WDAYS_SHORT
            return [lindex $WDAYS_SHORT [clock format $clock -format %w {*}$tzopt]]
        }

        yday {
            set value [clock format $clock -format %j {*}$tzopt]
        }

        year {
            set value [clock format $clock -format %Y {*}$tzopt]
        }

        zone {
            return $zone
        }

        default {
            error "unknown property $property"
        }
    }

    if {[set value [string trimleft $value 0]] eq {}} {
        set value 0
    }
    return $value
}

# ::myme::datezone --
#
#    Separates the zone from an RFC 5322 date-time.
#
# Arguments:
#       value      The date-time.
#
# Results:
#       A list of the date-time without the zone (and comments), and the
#       zone as minutes east of UTC.  Missing, military and other unknown
#       zones are taken as -0000 (RFC 5322 section 4.3), i.e. 0.

proc ::myme::datezone value {
    # Drop comments (CFWS), e.g. "-0700 (PDT)"
    set value [string trim [regsub -all {\([^()]*\)} $value { }]]

    if {[regexp {^(.*)\s([+-])([0-9]{2})([0-5][0-9])$} $value \
        -> datetime sign h m]
    } {
        set zone [expr {[scan $h %d] * 60 + [scan $m %d]}]
        if {$sign eq "-"} {
            set zone [expr {-$zone}]
        }
        return [list [string trim $datetime] $zone]
    }

    if {[regexp {^(.*)\s([A-Za-z]+)$} $value -> datetime name]} {
        set zones {UT 0 GMT 0 EST -5 EDT -4 CST -6 CDT -5 MST -7 MDT -6 PST -8 PDT -7}
        set name [string toupper $name]
        if {[dict exists $zones $name]} {
            set zone [expr {[dict get $zones $name] * 60}]
        } else {
            set zone 0
        }
        return [list [string trim $datetime] $zone]
    }

    list $value 0
}

# ::myme::uniqueID --
#
#    Used to generate a 'globally unique identifier' for the content-id.
#    The id is built from the pid, the current time, the hostname, and
#    a counter that is incremented each time a message is sent.
#
# Arguments:
#
# Results:
#    Returns the a string that contains the globally unique identifier
#       that should be used for the Content-ID of an e-mail message.

proc ::myme::uniqueID {} {
    variable mime

    return <[pid].[clock seconds].[incr mime(cid)]@[info hostname]>
}

# ::myme::parselexeme --
#
#    Used to implement a lookahead parser.
#
# Arguments:
#       token    The MIME token to operate on.
#
# Results:
#    Returns the next token found by the parser.

proc ::myme::parselexeme {token} {
    # FRINK: nocheck
    variable $token
    upvar 0 $token state

    set state(input) [string trimleft $state(input)]

    set state(buffer) {}
    if {$state(input) eq {}} {
        set state(buffer) end-of-input
        return [set state(lastC) LX_END]
    }

    set c [string index $state(input) 0]
    set state(input) [string range $state(input) 1 end]

    if {$c eq "("} {
        set noteP 0
        set quoteP 0

        while 1 {
            append state(buffer) $c

            #TODO: some of these paths are not covered by tests
            switch -- $c/$quoteP {
                (/0 {
                    incr noteP
                }

                \\/0 {
                    set quoteP 1
                }

                )/0 {
                    if {[incr noteP -1] < 1} {
                        if {[info exists state(comment)]} {
                            append state(comment) { }
                        }
                        append state(comment) $state(buffer)

                        return [parselexeme $token]
                    }
                }

                default {
                    set quoteP 0
                }
            }

            if {[set c [string index $state(input) 0]] eq {}} {
                set state(buffer) "end-of-input during comment"
                return [set state(lastC) LX_ERR]
            }
            set state(input) [string range $state(input) 1 end]
        }
    }

    if {$c eq "\""} {
        set firstP 1
        set quoteP 0

        while 1 {
            append state(buffer) $c

            switch -- $c/$quoteP {
                "\\/0" {
                    set quoteP 1
                }

                "\"/0" {
                    if {!$firstP} {
                        return [set state(lastC) LX_QSTRING]
                    }
                    set firstP 0
                }

                default {
                    set quoteP 0
                }
            }

            if {[set c [string index $state(input) 0]] eq {}} {
                set state(buffer) "end-of-input during quoted-string"
                return [set state(lastC) LX_ERR]
            }
            set state(input) [string range $state(input) 1 end]
        }
    }

    if {$c eq {[}} {
        set quoteP 0

        while 1 {
            append state(buffer) $c

            switch -- $c/$quoteP {
                \\/0 {
                    set quoteP 1
                }

                ]/0 {
                    return [set state(lastC) LX_DLITERAL]
                }

                default {
                    set quoteP 0
                }
            }

            if {[set c [string index $state(input) 0]] eq {}} {
                set state(buffer) "end-of-input during domain-literal"
                return [set state(lastC) LX_ERR]
            }
            set state(input) [string range $state(input) 1 end]
        }
    }

    if {[set x [lsearch -exact $state(tokenL) $c]] >= 0} {
        append state(buffer) $c

        return [set state(lastC) [lindex $state(lexemeL) $x]]
    }

    while 1 {
        append state(buffer) $c

        switch -- [set c [string index $state(input) 0]] {
            {} - " " - "\t" - "\n" {
                break
            }

            default {
                if {[lsearch -exact $state(tokenL) $c] >= 0} {
                    break
                }
            }
        }

        set state(input) [string range $state(input) 1 end]
    }

    return [set state(lastC) LX_ATOM]
}

# ::myme::mapencoding --
#
#    myme::mapencodings maps tcl encodings onto the proper names for their
#    MIME charset type.  This is only done for encodings whose charset types
#    were known.  The remaining encodings return {} for now.
#
# Arguments:
#       enc      The tcl encoding to map.
#
# Results:
#    Returns the MIME charset type for the specified tcl encoding, or {}
#       if none is known.

proc ::myme::mapencoding {enc} {

    variable encodings

    if {[info exists encodings($enc)]} {
        return $encodings($enc)
    }
    return {}
}

# ::myme::reversemapencoding --
#
#    myme::reversemapencodings maps MIME charset types onto tcl encoding names.
#    Those that are unknown return {}.
#
# Arguments:
#       mimeType  The MIME charset to convert into a tcl encoding type.
#
# Results:
#    Returns the tcl encoding name for the specified mime charset, or {}
#       if none is known.

proc ::myme::reversemapencoding {mimeType} {

    variable reversemap

    set lmimeType [string tolower $mimeType]
    if {[info exists reversemap($lmimeType)]} {
        return $reversemap($lmimeType)
    }
    return {}
}

# ::myme::word_encode --
#
#    Word encodes strings as per RFC 2047.
#
# Arguments:
#       charset   The character set to encode the message to.
#       method    The encoding method (base64 or quoted-printable).
#       string    The string to encode.
#       ?-charset_encoded   0 or 1      Whether the data is already encoded
#                                       in the specified charset (default 0)
#       ?-maxlength         maxlength   The maximum length of each encoded
#                                       word to return (default 66)
#
# Results:
#    Returns a word encoded string.

proc ::myme::word_encode {charset method string {args}} {

    variable encodings

    if {![info exists encodings($charset)]} {
        error "unknown charset '$charset'"
    }

    if {$encodings($charset) eq {}} {
        error "invalid charset '$charset'"
    }

    if {$method ne "base64" && $method ne "quoted-printable"} {
        error "unknown method '$method', must be base64 or quoted-printable"
    }

    # default to characters (not already encoded in charset) and a length
    # that won't make the Subject header too long
    array set options [list -charset_encoded 0 -maxlength 66]
    array set options $args

    if {$options(-charset_encoded)} {
        set unencoded_string [::encoding convertfrom $charset $string]
    } else {
        set unencoded_string $string
    }

    set string_length [string length $unencoded_string]

    if {!$string_length} {
        return {}
    }

    set string_bytelength \
        [string length [::encoding convertto utf-8 $unencoded_string]]

    # the 7 is for =?, ?Q?, ?= delimiters of the encoded word
    set maxlength [expr {$options(-maxlength) - [string length $encodings($charset)] - 7}]
    switch -exact -- $method {
        base64 {
            if {$maxlength < 4} {
                error "maxlength $options(-maxlength) too short for chosen charset and encoding"
            }
            set count 0
            set maxlength [expr {($maxlength / 4) * 3}]
            while {$count < $string_length} {
                set length 0
                set enc_string {}
                while {$length < $maxlength && $count < $string_length} {
                    set char [string range $unencoded_string $count $count]
                    set enc_char [::encoding convertto $charset $char]
                    if {$length + [string length $enc_char] > $maxlength} {
                        set length $maxlength
                    } else {
                        append enc_string $enc_char
                        incr count
                        incr length [string length $enc_char]
                    }
                }
                set encoded_word [string map [
                    list \n {}] [base64 -mode encode -- $enc_string]]
                append result "=?$encodings($charset)?B?$encoded_word?=\n "
            }
            # Trim off last "\n ", since the above code has the side-effect
            # of adding an extra "\n " to the encoded string.

            set result [string range $result 0 end-2]
        }
        quoted-printable {
            if {$maxlength < 1} {
                error "maxlength $options(-maxlength) too short for chosen charset and encoding"
            }
            set count 0
            while {$count < $string_length} {
                set length 0
                set encoded_word {}
                while {$length < $maxlength && $count < $string_length} {
                    set char [string range $unencoded_string $count $count]
                    set enc_char [::encoding convertto $charset $char]
                    set qp_enc_char [qp_encode $enc_char 1]
                    set qp_enc_char_length [string length $qp_enc_char]
                    if {$qp_enc_char_length > $maxlength} {
                        error "maxlength $options(-maxlength) too short for chosen charset and encoding"
                    }
                    if {
			$length + [string length $qp_enc_char] > $maxlength
		    } {
                        set length $maxlength
                    } else {
                        append encoded_word $qp_enc_char
                        incr count
                        incr length [string length $qp_enc_char]
                    }
                }
                append result "=?$encodings($charset)?Q?$encoded_word?=\n "
            }
            # Trim off last "\n ", since the above code has the side-effect
            # of adding an extra "\n " to the encoded string.

            set result [string range $result 0 end-2]
        }
        {} {
            # Go ahead
        }
        default {
            error "Can't handle content encoding \"$method\""
        }
    }
    return $result
}

# ::myme::word_decode --
#
#    Word decodes strings that have been word encoded as per RFC 2047.
#
# Arguments:
#       encoded   The word encoded string to decode.
#
# Results:
#    Returns the string that has been decoded from the encoded message.

proc ::myme::word_decode {encoded} {

    variable reversemap

    if {[regexp -- {=\?([^?]+)\?(.)\?([^?]*)\?=} $encoded \
	- charset method string] != 1
    } {
        error "malformed word-encoded expression '$encoded'"
    }

    # Drop any language suffix: charset*lang (RFC 2231 section 5)
    regsub {\*.*} $charset {} charset
    set enc [reversemapencoding $charset]
    if {$enc eq {}} {
        error "unknown charset '$charset'"
    }

    switch -exact -- $method {
        b -
        B {
            set method base64
        }
        q -
        Q {
            set method quoted-printable
        }
        default {
            error "unknown method '$method', must be B or Q"
        }
    }

    switch -exact -- $method {
        base64 {
            set result [base64 -mode decode -- $string]
        }
        quoted-printable {
            set result [qp_decode $string 1]
        }
        {} {
            # Go ahead
        }
        default {
            error "Can't handle content encoding \"$method\""
        }
    }

    return [list $enc $method $result]
}

# ::myme::field_decode --
#
#    Word decodes strings that have been word encoded as per RFC 2047
#    and converts the string from the original encoding/charset to UTF.
#
# Arguments:
#       field     The string to decode
#
# Results:
#    Returns the decoded string in UTF.

proc ::myme::field_decode {field} {
    # ::myme::field_decode is broken.  Here's a new version.
    # This code is in the public domain.  Don Libes <don@libes.com>

    # Step through a field for mime-encoded words, building a new
    # version with unencoded equivalents.

    # Sorry about the grotesque regexp.  Most of it is sensible.  One
    # notable fudge: the final $ is needed because of an apparent bug
    # in the regexp engine where the preceding .* otherwise becomes
    # non-greedy - perhaps because of the earlier ".*?", sigh.

    while {[regexp {(.*?)(=\?(?:[^?]+)\?(?:.)\?(?:[^?]*)\?=)(.*)$} $field \
	ignore prefix encoded field]
    } {
        # don't allow whitespace between encoded words per RFC 2047
        if {{} ne $prefix} {
            if {![string is space $prefix]} {
                append result $prefix
            }
        }

        # An encoded-word with an unknown charset (or that is otherwise
        # malformed) is left as it is (RFC 2047 section 6.3)
        if {[catch {word_decode $encoded} decoded]} {
            append result $encoded
            continue
        }
        foreach {charset - string} $decoded break

        append result [::encoding convertfrom $charset $string]
    }
    append result $field
    return $result
}

## One-Shot Initialization

::apply {{} {
    variable encList
    variable encAliasList
    variable reversemap

    foreach {enc mimeType} $encList {
        if {$mimeType eq {}} continue
	set reversemap([string tolower $mimeType]) $enc
    }

    foreach {enc mimeType} $encAliasList {
        set reversemap([string tolower $mimeType]) $enc
    }

    # Drop the helper variables
    unset encList encAliasList

} ::myme}


variable ::myme::internal 0
