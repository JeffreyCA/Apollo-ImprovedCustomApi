#import <Foundation/Foundation.h>

// Charset-aware decoding for bytes fetched from arbitrary third-party web
// pages (link-preview metadata, AI article extraction).
//
// Assuming UTF-8 with a Latin-1 rescue is wrong for the large slice of the web
// that still ships legacy encodings: Korean news (EUC-KR/CP949), Japanese
// (Shift_JIS), Chinese (GB18030/Big5), and older Western/Cyrillic pages
// (windows-1252/1251). Their bytes are not valid UTF-8, so the UTF-8 read
// returns nil, the Latin-1 rescue succeeds on every byte, and every og: tag
// comes out as mojibake — issue #945, where news.nate.com's EUC-KR title
// rendered as "¡®¾ÆÀ°´ë¡¯ ¿ÃÇØ Ãß¼®…".
//
// Deliberately Foundation-only and free of any tweak dependency, so it can be
// compiled straight into a host-side harness and checked against real captured
// pages.
//
// Bug: https://github.com/Apollo-Reborn/Apollo-Reborn/issues/945

__BEGIN_DECLS

/// Maps an IANA charset label ("euc-kr", "Shift_JIS", "windows-1251", quoted or
/// not, any case) to the `NSStringEncoding` to decode with, or 0 when the label
/// is empty or unrecognised.
NSStringEncoding ApolloWebTextEncodingForCharsetLabel(NSString *label);

/// Sniffs the charset an HTML byte stream declares in its own markup — either
/// `<meta charset=…>` / `<meta http-equiv="Content-Type" content="…charset=…">`
/// or an XHTML `<?xml … encoding="…"?>` prologue. Returns 0 when nothing usable
/// is declared inside the scanned prefix.
NSStringEncoding ApolloWebTextEncodingDeclaredInHTMLData(NSData *data);

/// Decodes web-fetched bytes into a string using the charset the page actually
/// declares, in this order:
///
///   1. a byte-order mark, which outranks every declaration;
///   2. UTF-8, when the bytes are valid UTF-8 *and* carry at least one
///      multi-byte sequence (see the note in the implementation on why this
///      sits ahead of the declared charset);
///   3. the response's `Content-Type: …; charset=…`;
///   4. the charset declared inside the markup;
///   5. UTF-8, covering pure-ASCII pages and pages that declare nothing;
///   6. Latin-1, which cannot fail and so guarantees a non-nil result for any
///      non-empty input.
///
/// `response` may be nil. Pass a non-NULL `outEncoding` to learn which encoding
/// won, for logging; it is left untouched when the input is empty.
/// Returns nil only for nil/empty `data`.
NSString *ApolloWebTextFromData(NSData *data, NSURLResponse *response, NSStringEncoding *outEncoding);

/// Human-readable name for an encoding returned above ("Korean (Windows, DOS)"),
/// for log lines. Returns @"unknown" for 0 / unmappable values.
NSString *ApolloWebTextNameForEncoding(NSStringEncoding encoding);

__END_DECLS
