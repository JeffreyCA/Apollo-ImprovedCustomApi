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

    // An explicit declaration is honoured as declared, and is never
    // second-guessed by sniffing the bytes for valid UTF-8 first.
    //
    // Sniffing looks tempting — it would rescue a page that is really UTF-8
    // behind a stale `charset=ISO-8859-1` header — but it is not sound, because
    // "valid UTF-8" and "valid legacy text" are not mutually exclusive. The
    // lead-byte ranges overlap: CP949, GB18030 and Big5 lead as high as 0xFE and
    // CP932 as high as 0xFC, well inside UTF-8's own 0xC2–0xF4 lead range. So
    // `C2 81` is both valid UTF-8 (U+0081) and valid CP949 (혖), and `C2 A1` is
    // both valid UTF-8 (U+00A1) and valid Big5 (癒) / GB18030 (隆) / CP932 (ﾂ｡).
    // A page built from those pairs would sniff clean as UTF-8 and decode to
    // entirely the wrong characters — the very bug this file exists to fix.
    // Trusting the declaration is also what browsers do, so a page we get
    // "wrong" is one that renders the same way in Safari.
    NSStringEncoding headerEncoding = ApolloWebTextEncodingForCharsetLabel(response.textEncodingName);
    NSStringEncoding markupEncoding = ApolloWebTextEncodingDeclaredInHTMLData(data);
    NSStringEncoding declared[] = { headerEncoding, markupEncoding };
    for (size_t index = 0; index < sizeof(declared) / sizeof(*declared); index++) {
        NSStringEncoding encoding = declared[index];
        if (encoding == 0) continue;
        if (index > 0 && encoding == declared[0]) continue;
        // A failed decode means the declaration was wrong about its own bytes,
        // so fall through to the next candidate rather than honouring it into
        // mojibake.
        NSString *decoded = [[NSString alloc] initWithData:data encoding:encoding];
        if (decoded.length > 0) {
            if (outEncoding) *outEncoding = encoding;
            return decoded;
        }
    }

    // Nothing usable was declared (or every declaration failed to decode).
    NSString *utf8Decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
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

#pragma mark - Self tests

// Test double for the charset an NSURLResponse reports out of Content-Type.
@interface ApolloWebTextTestResponse : NSURLResponse
@property (nonatomic, copy) NSString *charsetName;
@end
@implementation ApolloWebTextTestResponse
- (NSString *)textEncodingName { return self.charsetName; }
@end

BOOL ApolloWebTextDecodingRunSelfTests(NSString **outFailedCase) {
    __block NSString *failure = nil;
    void (^expect)(BOOL, NSString *) = ^(BOOL condition, NSString *name) {
        if (!condition && !failure) failure = name;
    };
    NSURLResponse *(^declaring)(NSString *) = ^NSURLResponse *(NSString *charset) {
        ApolloWebTextTestResponse *response = [ApolloWebTextTestResponse new];
        response.charsetName = charset;
        return response;
    };
    NSData *(^bytes)(const uint8_t *, NSUInteger) = ^NSData *(const uint8_t *b, NSUInteger n) {
        return [NSData dataWithBytes:b length:n];
    };

    // --- Label mapping. euc-kr must widen to CP949: Apple's EUC-KR converter
    // rejects the CP949-extended hangul that real "euc-kr" pages contain, and
    // "korean" otherwise resolves to Mac OS Korean, a different encoding.
    expect(ApolloWebTextEncodingForCharsetLabel(@"euc-kr") ==
           CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSKorean), @"label euc-kr->cp949");
    expect(ApolloWebTextEncodingForCharsetLabel(@"  \"EUC-KR\" ") ==
           ApolloWebTextEncodingForCharsetLabel(@"euc-kr"), @"label quoted/cased/padded");
    expect(ApolloWebTextEncodingForCharsetLabel(@"korean") ==
           CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSKorean), @"label korean->cp949");
    expect(ApolloWebTextEncodingForCharsetLabel(@"gb2312") ==
           CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000), @"label gb2312->gb18030");
    expect(ApolloWebTextEncodingForCharsetLabel(@"iso-8859-1") ==
           CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsLatin1), @"label latin1->cp1252");
    expect(ApolloWebTextEncodingForCharsetLabel(@"windows-1251") != 0, @"label windows-1251 resolves");
    expect(ApolloWebTextEncodingForCharsetLabel(@"totally-bogus") == 0, @"label bogus->0");
    expect(ApolloWebTextEncodingForCharsetLabel(nil) == 0, @"label nil->0");
    expect(ApolloWebTextEncodingForCharsetLabel(@"") == 0, @"label empty->0");

    // --- Ambiguous bytes: each of these is simultaneously well-formed UTF-8 and
    // well-formed legacy text, so a decoder that sniffs for valid UTF-8 before
    // reading the declaration silently returns the wrong characters. The
    // declaration has to win.
    const uint8_t c281[] = { 0xC2, 0x81 };  // UTF-8 U+0081 | CP949 혖
    const uint8_t c2a1[] = { 0xC2, 0xA1 };  // UTF-8 U+00A1 | Big5 癒 | GB18030 隆 | CP932 ﾂ｡
    expect([[NSString alloc] initWithData:bytes(c281, 2) encoding:NSUTF8StringEncoding] != nil,
           @"fixture C2 81 really is valid UTF-8");
    expect([[NSString alloc] initWithData:bytes(c2a1, 2) encoding:NSUTF8StringEncoding] != nil,
           @"fixture C2 A1 really is valid UTF-8");
    expect([ApolloWebTextFromData(bytes(c281, 2), declaring(@"euc-kr"), NULL) isEqualToString:@"혖"],
           @"ambiguous C2 81 honours euc-kr");
    expect([ApolloWebTextFromData(bytes(c2a1, 2), declaring(@"big5"), NULL) isEqualToString:@"癒"],
           @"ambiguous C2 A1 honours big5");
    expect([ApolloWebTextFromData(bytes(c2a1, 2), declaring(@"gb2312"), NULL) isEqualToString:@"隆"],
           @"ambiguous C2 A1 honours gb2312");
    expect([ApolloWebTextFromData(bytes(c2a1, 2), declaring(@"shift_jis"), NULL) isEqualToString:@"ﾂ｡"],
           @"ambiguous C2 A1 honours shift_jis");

    // A whole document of ambiguous pairs — the document-level version of the
    // above, since a single pair could be dismissed as a corner case.
    NSMutableData *ambiguousPage = [NSMutableData dataWithData:
        [@"<html><head><title>" dataUsingEncoding:NSASCIIStringEncoding]];
    for (int repeat = 0; repeat < 64; repeat++) [ambiguousPage appendBytes:c281 length:2];
    [ambiguousPage appendData:[@"</title></head></html>" dataUsingEncoding:NSASCIIStringEncoding]];
    expect([[NSString alloc] initWithData:ambiguousPage encoding:NSUTF8StringEncoding] != nil,
           @"fixture whole ambiguous page is valid UTF-8");
    expect([ApolloWebTextFromData(ambiguousPage, declaring(@"euc-kr"), NULL) containsString:@"혖혖"],
           @"whole ambiguous page honours euc-kr");

    // --- Declaration sources and precedence.
    const uint8_t hangul[] = { 0xBE, 0xC6, 0xC0, 0xCC };  // 아이 in EUC-KR
    expect([ApolloWebTextFromData(bytes(hangul, 4), declaring(@"euc-kr"), NULL) isEqualToString:@"아이"],
           @"header charset decodes");

    NSMutableData *metaOnly = [NSMutableData dataWithData:[
        @"<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=euc-kr\"><title>"
        dataUsingEncoding:NSASCIIStringEncoding]];
    [metaOnly appendBytes:hangul length:4];
    [metaOnly appendData:[@"</title></head>" dataUsingEncoding:NSASCIIStringEncoding]];
    expect([ApolloWebTextFromData(metaOnly, nil, NULL) containsString:@"아이"], @"meta charset, nil response");

    NSMutableData *xmlPrologue = [NSMutableData dataWithData:
        [@"<?xml version=\"1.0\" encoding=\"euc-kr\"?><t>" dataUsingEncoding:NSASCIIStringEncoding]];
    [xmlPrologue appendBytes:hangul length:4];
    [xmlPrologue appendData:[@"</t>" dataUsingEncoding:NSASCIIStringEncoding]];
    expect([ApolloWebTextFromData(xmlPrologue, nil, NULL) containsString:@"아이"], @"XHTML encoding prologue");

    // Header outranks a contradicting markup declaration.
    NSMutableData *headerVsMeta = [NSMutableData dataWithData:
        [@"<html><head><meta charset=\"utf-8\"><title>" dataUsingEncoding:NSASCIIStringEncoding]];
    [headerVsMeta appendBytes:hangul length:4];
    [headerVsMeta appendData:[@"</title></head>" dataUsingEncoding:NSASCIIStringEncoding]];
    expect([ApolloWebTextFromData(headerVsMeta, declaring(@"euc-kr"), NULL) containsString:@"아이"],
           @"header outranks markup");

    // A header that cannot decode its own bytes is abandoned in favour of the
    // markup's declaration. Real shape: the server says utf-8 while serving
    // EUC-KR, and only the page itself tells the truth.
    NSMutableData *lyingHeader = [NSMutableData dataWithData:
        [@"<html><head><meta charset=\"euc-kr\"><title>" dataUsingEncoding:NSASCIIStringEncoding]];
    [lyingHeader appendBytes:hangul length:4];
    [lyingHeader appendData:[@"</title></head>" dataUsingEncoding:NSASCIIStringEncoding]];
    expect([[NSString alloc] initWithData:lyingHeader encoding:NSUTF8StringEncoding] == nil,
           @"fixture lying-header body really is invalid UTF-8");
    expect([ApolloWebTextFromData(lyingHeader, declaring(@"utf-8"), NULL) containsString:@"아이"],
           @"undecodable header falls through to markup");

    // --- BOM outranks a contradicting declaration, and is stripped.
    NSMutableData *bom = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [bom appendData:[@"<title>안녕</title>" dataUsingEncoding:NSUTF8StringEncoding]];
    expect([ApolloWebTextFromData(bom, declaring(@"euc-kr"), NULL) isEqualToString:@"<title>안녕</title>"],
           @"UTF-8 BOM wins and is stripped");

    // --- CP949-extended hangul under a plain "euc-kr" label: nil through
    // Apple's narrow EUC-KR converter, which is what the widening prevents.
    const uint8_t cp949Extended[] = { 0x81, 0x41, 0xBE, 0xC6 };
    expect([[NSString alloc] initWithData:bytes(cp949Extended, 4)
                                 encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR)] == nil,
           @"fixture CP949-extended really is rejected by EUC-KR");
    expect([ApolloWebTextFromData(bytes(cp949Extended, 4), declaring(@"euc-kr"), NULL) containsString:@"아"],
           @"CP949-extended bytes under euc-kr label");

    // --- windows-1252 punctuation under an iso-8859-1 label (0x93/0x94 are
    // undefined C1 controls in true ISO-8859-1).
    const uint8_t smartQuotes[] = { 'C', 'a', 'f', 0xE9, ' ', 0x93, 'h', 'i', 0x94 };
    expect([ApolloWebTextFromData(bytes(smartQuotes, 9), declaring(@"iso-8859-1"), NULL)
            isEqualToString:@"Café “hi”"], @"windows-1252 punctuation under iso-8859-1");

    // --- Undeclared, pure ASCII, and degenerate inputs.
    expect(ApolloWebTextFromData(bytes(hangul, 4), nil, NULL).length > 0,
           @"undeclared non-UTF-8 never returns nil");
    expect([ApolloWebTextFromData([@"<p>hi</p>" dataUsingEncoding:NSASCIIStringEncoding],
                                  declaring(@"shift_jis"), NULL) isEqualToString:@"<p>hi</p>"],
           @"pure ASCII under a legacy label");
    expect([ApolloWebTextFromData([@"<p>Café 안녕</p>" dataUsingEncoding:NSUTF8StringEncoding], nil, NULL)
            containsString:@"Café 안녕"], @"undeclared UTF-8");
    expect(ApolloWebTextFromData(nil, nil, NULL) == nil, @"nil data->nil");
    expect(ApolloWebTextFromData([NSData data], nil, NULL) == nil, @"empty data->nil");

    NSStringEncoding untouched = 0xDEAD;
    (void)ApolloWebTextFromData([NSData data], nil, &untouched);
    expect(untouched == 0xDEAD, @"outEncoding untouched on empty input");

    NSStringEncoding reported = 0;
    (void)ApolloWebTextFromData(bytes(hangul, 4), declaring(@"euc-kr"), &reported);
    expect([ApolloWebTextNameForEncoding(reported) isEqualToString:@"cp949"], @"reported encoding name");

    if (outFailedCase) *outFailedCase = failure;
    return failure == nil;
}
