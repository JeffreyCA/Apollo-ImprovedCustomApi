#import "ApolloWebTextDecoding.h"

// How far into the document we look for a `<meta charset>` declaration. The
// HTML spec only obliges a page to declare inside its first 1024 bytes, but
// plenty of real pages bury it after a pile of inline script; 64 KB covers
// every page seen in the wild while keeping the ASCII prescan bounded on the
// multi-megabyte documents the fetchers cap at.
static const NSUInteger ApolloWebTextMetaPrescanBytes = 64 * 1024;

#pragma mark - Charset labels

// The WHATWG encoding standard exists because charset labels on the real web
// are systematically narrower than the bytes they describe, so every browser
// decodes these labels with a superset instead. That is not pedantry here: the
// narrow converter *rejects* the extended bytes, and a rejected decode is
// exactly what drops us into the Latin-1 rescue this file exists to avoid.
//
//   euc-kr        Apple's EUC-KR converter refuses CP949-extended hangul, which
//                 Korean pages labelled "euc-kr" legitimately contain. CP949 is
//                 a strict superset, so it reads both.
//   korean        Resolves to *Mac OS* Korean through CFString — a different
//                 encoding entirely — so it has to be overridden, not just
//                 widened.
//   shift_jis     Real pages carry the CP932 (windows-31j) vendor extensions.
//   gb2312 / gbk  Superseded by GB18030, which is backward compatible.
//   big5          Traditional Chinese pages carry HKSCS extensions.
//   iso-8859-1    The single most mislabelled charset on the web: pages declare
//   / us-ascii    it while using the windows-1252 smart quotes, dashes and
//                 ellipses that live in the 0x80–0x9F control range.
static NSStringEncoding ApolloWebTextOverrideEncodingForLabel(NSString *label) {
    static NSDictionary<NSString *, NSNumber *> *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNumber *korean = @(kCFStringEncodingDOSKorean);            // CP949 / UHC
        NSNumber *japanese = @(kCFStringEncodingDOSJapanese);        // CP932 / windows-31j
        NSNumber *simplified = @(kCFStringEncodingGB_18030_2000);
        NSNumber *traditional = @(kCFStringEncodingBig5_HKSCS_1999);
        NSNumber *western = @(kCFStringEncodingWindowsLatin1);       // windows-1252
        overrides = @{
            @"euc-kr": korean,
            @"euckr": korean,
            @"ks_c_5601-1987": korean,
            @"ks_c_5601-1989": korean,
            @"ksc5601": korean,
            @"ksc_5601": korean,
            @"korean": korean,
            @"csksc56011987": korean,
            @"iso-ir-149": korean,

            @"shift_jis": japanese,
            @"shift-jis": japanese,
            @"sjis": japanese,
            @"ms_kanji": japanese,
            @"csshiftjis": japanese,
            @"x-sjis": japanese,

            @"gb2312": simplified,
            @"gb_2312": simplified,
            @"gb_2312-80": simplified,
            @"chinese": simplified,
            @"csgb2312": simplified,
            @"gbk": simplified,
            @"x-gbk": simplified,

            @"big5": traditional,
            @"big5-hkscs": traditional,
            @"cn-big5": traditional,
            @"csbig5": traditional,
            @"x-x-big5": traditional,

            @"iso-8859-1": western,
            @"iso8859-1": western,
            @"iso_8859-1": western,
            @"iso_8859-1:1987": western,
            @"latin1": western,
            @"l1": western,
            @"cp819": western,
            @"ibm819": western,
            @"ascii": western,
            @"us-ascii": western,
            @"ansi_x3.4-1968": western,
        };
    });

    NSNumber *cfEncoding = overrides[label];
    if (!cfEncoding) return 0;
    NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding((CFStringEncoding)cfEncoding.unsignedIntValue);
    return encoding == kCFStringEncodingInvalidId ? 0 : encoding;
}

NSStringEncoding ApolloWebTextEncodingForCharsetLabel(NSString *label) {
    if (![label isKindOfClass:[NSString class]] || label.length == 0) return 0;

    static NSCharacterSet *trimSet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        trimSet = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n\"';"];
    });
    NSString *name = [[label stringByTrimmingCharactersInSet:trimSet] lowercaseString];
    if (name.length == 0) return 0;

    NSStringEncoding override = ApolloWebTextOverrideEncodingForLabel(name);
    if (override != 0) return override;

    CFStringEncoding cfEncoding = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)name);
    if (cfEncoding == kCFStringEncodingInvalidId) return 0;
    NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding);
    return encoding == kCFStringEncodingInvalidId ? 0 : encoding;
}

NSString *ApolloWebTextNameForEncoding(NSStringEncoding encoding) {
    if (encoding == 0) return @"unknown";
    CFStringEncoding cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding);
    if (cfEncoding == kCFStringEncodingInvalidId) return @"unknown";
    // The IANA name ("cp949", "shift_jis") rather than CFStringGetNameOfEncoding's
    // localized prose: the prose comes back empty on iOS for exactly the legacy
    // encodings worth logging, and a stable ASCII identifier is what a future
    // charset report needs to be greppable anyway.
    NSString *name = (__bridge NSString *)CFStringConvertEncodingToIANACharSetName(cfEncoding);
    if (name.length == 0) name = (__bridge NSString *)CFStringGetNameOfEncoding(cfEncoding);
    return name.length > 0 ? name : @"unknown";
}

#pragma mark - Sniffing

// Byte-order marks outrank every other declaration, including a contradicting
// HTTP header. Reports the BOM's own length so the caller can drop it — decoding
// a UTF-8 BOM as UTF-8 otherwise leaves a stray U+FEFF glued to the front of the
// document, which would ride along into a title.
static NSStringEncoding ApolloWebTextEncodingFromBOM(NSData *data, NSUInteger *outBOMLength) {
    const uint8_t *bytes = data.bytes;
    if (data.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        *outBOMLength = 3;
        return NSUTF8StringEncoding;
    }
    if (data.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        *outBOMLength = 2;
        return NSUTF16BigEndianStringEncoding;
    }
    if (data.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        *outBOMLength = 2;
        return NSUTF16LittleEndianStringEncoding;
    }
    *outBOMLength = 0;
    return 0;
}

NSStringEncoding ApolloWebTextEncodingDeclaredInHTMLData(NSData *data) {
    if (data.length == 0) return 0;

    // A charset declaration is itself always ASCII, and every encoding we care
    // about is ASCII-compatible — so a Latin-1 read of the prefix (which cannot
    // fail on any byte) is a faithful view of the declaration even though the
    // document's real encoding is still unknown at this point.
    NSUInteger scanLength = MIN(data.length, ApolloWebTextMetaPrescanBytes);
    NSString *prefix = [[NSString alloc] initWithBytes:data.bytes length:scanLength encoding:NSISOLatin1StringEncoding];
    if (prefix.length == 0) return 0;

    static NSArray<NSRegularExpression *> *declarationPatterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSRegularExpressionOptions options = NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators;
        // Covers both <meta charset="euc-kr"> and the http-equiv spelling
        // <meta http-equiv="Content-Type" content="text/html; charset=euc-kr">.
        NSRegularExpression *meta = [NSRegularExpression regularExpressionWithPattern:@"<meta\\b[^>]*?charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9_.:+-]+)"
                                                                              options:options
                                                                                error:nil];
        NSRegularExpression *xmlPrologue = [NSRegularExpression regularExpressionWithPattern:@"<\\?xml\\b[^>]*?encoding\\s*=\\s*[\"']\\s*([A-Za-z0-9_.:+-]+)"
                                                                                     options:options
                                                                                       error:nil];
        NSMutableArray *patterns = [NSMutableArray array];
        if (meta) [patterns addObject:meta];
        if (xmlPrologue) [patterns addObject:xmlPrologue];
        declarationPatterns = [patterns copy];
    });

    for (NSRegularExpression *pattern in declarationPatterns) {
        NSArray<NSTextCheckingResult *> *matches = [pattern matchesInString:prefix options:0 range:NSMakeRange(0, prefix.length)];
        for (NSTextCheckingResult *match in matches) {
            if (match.numberOfRanges < 2) continue;
            NSStringEncoding encoding = ApolloWebTextEncodingForCharsetLabel([prefix substringWithRange:[match rangeAtIndex:1]]);
            // Keep walking past labels CFString can't resolve rather than
            // giving up — pages sometimes carry a junk declaration ahead of the
            // real one.
            if (encoding != 0) return encoding;
        }
    }
    return 0;
}

static BOOL ApolloWebTextDataContainsNonASCII(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    for (NSUInteger index = 0; index < length; index++) {
        if (bytes[index] & 0x80) return YES;
    }
    return NO;
}

#pragma mark - Decoding

NSString *ApolloWebTextFromData(NSData *data, NSURLResponse *response, NSStringEncoding *outEncoding) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;

    NSUInteger bomLength = 0;
    NSStringEncoding bomEncoding = ApolloWebTextEncodingFromBOM(data, &bomLength);
    if (bomEncoding != 0) {
        NSData *body = [data subdataWithRange:NSMakeRange(bomLength, data.length - bomLength)];
        NSString *decoded = [[NSString alloc] initWithData:body encoding:bomEncoding];
        if (decoded.length > 0) {
            if (outEncoding) *outEncoding = bomEncoding;
            return decoded;
        }
    }

    // Multi-byte-bearing valid UTF-8 outranks the declared charset here, which
    // is a deliberate departure from the spec's "HTTP header always wins".
    //
    // The spec order would regress pages that are genuinely UTF-8 but ship a
    // stale `charset=ISO-8859-1` header (still an Apache default) — the
    // windows-1252 read never fails, so it would win and turn working previews
    // into mojibake. Deciding by the bytes avoids that with no ambiguity cost:
    // legacy multi-byte text essentially cannot be mistaken for UTF-8, because
    // EUC-KR/CP949, Shift_JIS and Big5 all lead their characters with a byte in
    // 0x80–0xBF or 0x81–0x9F, which UTF-8 does not allow in a lead position.
    // So "valid UTF-8 with at least one multi-byte sequence" identifies real
    // UTF-8, and the declared charset still governs everything else.
    BOOL hasNonASCII = ApolloWebTextDataContainsNonASCII(data);
    NSString *utf8Decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (hasNonASCII && utf8Decoded.length > 0) {
        if (outEncoding) *outEncoding = NSUTF8StringEncoding;
        return utf8Decoded;
    }

    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    NSStringEncoding headerEncoding = ApolloWebTextEncodingForCharsetLabel(response.textEncodingName);
    if (headerEncoding != 0) [candidates addObject:@(headerEncoding)];
    NSStringEncoding markupEncoding = ApolloWebTextEncodingDeclaredInHTMLData(data);
    if (markupEncoding != 0 && markupEncoding != headerEncoding) [candidates addObject:@(markupEncoding)];

    for (NSNumber *candidate in candidates) {
        NSStringEncoding encoding = candidate.unsignedIntegerValue;
        if (encoding == NSUTF8StringEncoding) continue; // already tried above
        NSString *decoded = [[NSString alloc] initWithData:data encoding:encoding];
        if (decoded.length > 0) {
            if (outEncoding) *outEncoding = encoding;
            return decoded;
        }
    }

    // Pure-ASCII documents, and documents that declared nothing usable.
    if (utf8Decoded.length > 0) {
        if (outEncoding) *outEncoding = NSUTF8StringEncoding;
        return utf8Decoded;
    }

    // Last resort. Latin-1 maps all 256 byte values, so this always produces a
    // string — mojibake for an undeclared non-UTF-8 page, but that still beats
    // handing the caller nil and losing the page's metadata outright.
    if (outEncoding) *outEncoding = NSISOLatin1StringEncoding;
    return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}
