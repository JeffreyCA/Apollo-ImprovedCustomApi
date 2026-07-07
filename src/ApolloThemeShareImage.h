#import <UIKit/UIKit.h>
#import "ApolloThemeTokens.h"

// "Share a theme as an image" — the social-sharing layer on top of the Theme
// Manager's JSON import/export.
//
// Sharing a theme as a raw .json file is awkward on social media: Reddit and
// the like don't host arbitrary files, so a user would have to find a third-
// party file host first. Instead we render a single portrait IMAGE that (a)
// shows the theme's own compiled colours as a mock Apollo post — so the post
// doubles as a preview — and (b) carries the whole theme inside a QR code
// printed onto the card. Another user saves that image and imports it; we read
// the QR back and reconstruct the exact theme.
//
// Why a *visible* QR rather than hiding the data in the pixels: Reddit (and most
// platforms) re-encode every uploaded image to lossy JPEG and may resize it,
// which destroys steganography / subtle pixel encodings. A QR is high-contrast,
// luminance-only, and carries Reed–Solomon error correction (level H here, ~30%
// recovery), so it survives a JPEG round-trip and is decoded geometrically, not
// pixel-exactly. The payload is tiny (~60–180 bytes via the binary codec below),
// so the QR stays small with large modules.
//
// Payload format: "ApolloTheme/1/" + base64(binary blob). The blob is
// versioned: version 0x02 carries the v2 schema (input keys × light/dark,
// variant, advanced flag); version 0x01 is the legacy Theme Builder layout
// (role.mode colours) from the original share feature — still decoded so cards
// already posted keep importing. Both decode routes converge on
// -[ApolloThemeStore parseImportData:error:], so the QR path inherits every
// validation/normalisation guard the JSON file path has.

__BEGIN_DECLS

// Render the portrait share card for a stored v2 theme dict: a mock Apollo post
// painted in the theme's compiled token colours (mirroring the editor's Preview
// section) with the theme name as the post title, a Dark/Light-mode badge, the
// palette, and the QR. `mode` selects which appearance the card previews (the
// QR payload always carries both). Returns nil only for a non-dictionary theme.
UIImage *ApolloThemeShareRenderCard(NSDictionary *theme, ApolloThemeMode mode);

// Decode a theme back out of a picked image by finding the Apollo Theme QR in it
// (Vision first for recompressed-image robustness, CIDetector fallback) and
// validating its payload through the Store's import parser. Returns a parsed
// import dict (the -[ApolloThemeStore parseImportData:error:] shape, ready for
// -confirmImport:/importParsedTheme:) or nil if the image has no recognisable
// Apollo theme QR.
NSDictionary *ApolloThemeShareDecodeImage(UIImage *image);

// Decode a raw QR payload STRING (as read from a picked image or a live camera
// scan): checks the "ApolloTheme/1/" tag, base64-decodes (size-capped), decodes
// the versioned binary blob, and runs the result through the Store's strict
// import parser. Returns the parsed import dict or nil if the string isn't an
// Apollo theme QR. Lets the camera scanner reuse the exact same decode path.
NSDictionary *ApolloThemeShareDecodePayload(NSString *payload);

__END_DECLS
