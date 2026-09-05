#ifndef ApolloNavigationTitleGeometry_h
#define ApolloNavigationTitleGeometry_h

#include <CoreGraphics/CoreGraphics.h>
#include <math.h>

typedef struct {
    CGFloat center;
    CGFloat maximumContentWidth;
} ApolloNavigationTitleGeometry;

// Coordinates are physical left/right in barBounds' space; callers resolve RTL.
// Edges come from buttons or safe-area boundaries on empty sides. Use the
// collapsed pill edge so expansion never changes the title's centered base size.
// center is the bar midpoint. Enforce maximumContentWidth before centering;
// it excludes capsule padding, and zero means hide the content and capsule.
// Invalid/negative sizes and padding become zero; invalid edges use bar boundaries.
static inline ApolloNavigationTitleGeometry ApolloNavigationTitleCenteredGeometry(
    CGRect barBounds, CGFloat leftEdge, CGFloat rightEdge,
    CGFloat capsulePadding, CGFloat edgePadding) {
    CGFloat barMin = isfinite(barBounds.origin.x) ? barBounds.origin.x : 0.0;
    CGFloat barWidth = isfinite(barBounds.size.width) && barBounds.size.width > 0.0
        ? barBounds.size.width : 0.0;
    CGFloat barMax = barMin + barWidth;
    // Even individually finite caller values can overflow when combined.
    if (!isfinite(barMax)) {
        barWidth = 0.0;
        barMax = barMin;
    }
    CGFloat barCenter = barMin + barWidth * 0.5;

    CGFloat left = isfinite(leftEdge) ? fmin(fmax(leftEdge, barMin), barMax) : barMin;
    CGFloat right = isfinite(rightEdge) ? fmin(fmax(rightEdge, barMin), barMax) : barMax;
    CGFloat sidePadding = isfinite(edgePadding) && edgePadding > 0.0 ? edgePadding : 0.0;
    CGFloat glassPadding = isfinite(capsulePadding) && capsulePadding > 0.0 ? capsulePadding : 0.0;

    ApolloNavigationTitleGeometry result = { barCenter, 0.0 };
    CGFloat availableHalfWidth = fmin(barCenter - left, right - barCenter);
    // Use the tighter side symmetrically; subtract padding before doubling to avoid overflow.
    if (availableHalfWidth <= 0.0 || sidePadding >= availableHalfWidth) return result;
    availableHalfWidth -= sidePadding;
    if (glassPadding >= availableHalfWidth) return result;

    result.maximumContentWidth = (availableHalfWidth - glassPadding) * 2.0;
    return result;
}

// For expanded right-hand actions, shift the full title capsule left only enough
// to clear the pill, bounded by the left controls/safe area. Never resize it;
// the caller handles any remaining overlap. Collapse targets an offset of zero.
// Use the unshifted title frame and final expanded edge, not animated frames.
// Coordinates are physical in barBounds' space. Nonfinite/empty frames don't move;
// invalid edges use bar boundaries, and negative/invalid padding becomes zero.
static inline CGFloat ApolloNavigationTitleExpandedActionsOffset(
    CGRect barBounds, CGRect centeredTitleFrame, CGFloat leftEdge,
    CGFloat expandedActionsLeftEdge, CGFloat edgePadding) {
    CGFloat barMin = barBounds.origin.x;
    CGFloat barWidth = barBounds.size.width;
    CGFloat titleMin = centeredTitleFrame.origin.x;
    CGFloat titleWidth = centeredTitleFrame.size.width;
    if (!isfinite(barMin) || !isfinite(barWidth) || barWidth <= 0.0 ||
        !isfinite(titleMin) || !isfinite(titleWidth) || titleWidth <= 0.0) return 0.0;

    CGFloat barMax = barMin + barWidth;
    CGFloat titleMax = titleMin + titleWidth;
    if (!isfinite(barMax) || !isfinite(titleMax)) return 0.0;

    CGFloat left = isfinite(leftEdge) ? fmin(fmax(leftEdge, barMin), barMax) : barMin;
    CGFloat right = isfinite(expandedActionsLeftEdge)
        ? fmin(fmax(expandedActionsLeftEdge, barMin), barMax) : barMax;
    CGFloat padding = isfinite(edgePadding) && edgePadding > 0.0 ? edgePadding : 0.0;
    CGFloat leftTravel = titleMin - left - padding;
    CGFloat neededTravel = titleMax - right + padding;
    if (!isfinite(leftTravel) || !isfinite(neededTravel) ||
        leftTravel <= 0.0 || neededTravel <= 0.0) return 0.0;

    return -fmin(leftTravel, neededTravel);
}

#endif
