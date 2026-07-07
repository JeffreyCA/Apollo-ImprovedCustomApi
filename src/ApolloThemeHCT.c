// ApolloThemeHCT.c — C port of Material Color Utilities' HCT machinery.
// See ApolloThemeHCT.h for provenance. Function names/structure deliberately
// mirror the TypeScript sources so the two can be diffed side by side; all
// numeric constants are copied verbatim (bit-exact parity with the JS
// reference is a hard requirement — the golden vectors assert it).

#include "ApolloThemeHCT.h"

#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// math_utils.ts
// ---------------------------------------------------------------------------

static double Signum(double x) {
    return x < 0 ? -1.0 : (x == 0 ? 0.0 : 1.0);
}

static double Lerp(double start, double stop, double amount) {
    return (1.0 - amount) * start + amount * stop;
}

static double ClampDouble(double min, double max, double input) {
    return input < min ? min : (input > max ? max : input);
}

static int ClampInt(int min, int max, int input) {
    return input < min ? min : (input > max ? max : input);
}

static double SanitizeDegrees(double degrees) {
    degrees = fmod(degrees, 360.0);
    if (degrees < 0) degrees += 360.0;
    return degrees;
}

static void MatrixMultiply(const double row[3], const double matrix[3][3], double out[3]) {
    double a = row[0] * matrix[0][0] + row[1] * matrix[0][1] + row[2] * matrix[0][2];
    double b = row[0] * matrix[1][0] + row[1] * matrix[1][1] + row[2] * matrix[1][2];
    double c = row[0] * matrix[2][0] + row[1] * matrix[2][1] + row[2] * matrix[2][2];
    out[0] = a; out[1] = b; out[2] = c;
}

// ---------------------------------------------------------------------------
// color_utils.ts
// ---------------------------------------------------------------------------

static const double kSRGBToXYZ[3][3] = {
    {0.41233895, 0.35762064, 0.18051042},
    {0.2126,     0.7152,     0.0722},
    {0.01932141, 0.11916382, 0.95034478},
};

static const double kWhitePointD65[3] = {95.047, 100.0, 108.883};

static double LabF(double t) {
    const double e = 216.0 / 24389.0;
    const double kappa = 24389.0 / 27.0;
    if (t > e) return cbrt(t);
    return (kappa * t + 16.0) / 116.0;
}

static double LabInvF(double ft) {
    const double e = 216.0 / 24389.0;
    const double kappa = 24389.0 / 27.0;
    double ft3 = ft * ft * ft;
    if (ft3 > e) return ft3;
    return (116.0 * ft - 16.0) / kappa;
}

// 0..255 channel -> 0..100 linear.
static double Linearized(int rgbComponent) {
    double normalized = rgbComponent / 255.0;
    if (normalized <= 0.040449936) return normalized / 12.92 * 100.0;
    return pow((normalized + 0.055) / 1.055, 2.4) * 100.0;
}

// 0..100 linear -> 0..255 channel (rounded + clamped).
static int Delinearized(double rgbComponent) {
    double normalized = rgbComponent / 100.0;
    double delinearized;
    if (normalized <= 0.0031308) {
        delinearized = normalized * 12.92;
    } else {
        delinearized = 1.055 * pow(normalized, 1.0 / 2.4) - 0.055;
    }
    // JS Math.round: half-up. Channels are non-negative here, so C round()
    // (half away from zero) is identical.
    return ClampInt(0, 255, (int)round(delinearized * 255.0));
}

static uint32_t RGBFromChannels(int r, int g, int b) {
    return (((uint32_t)r & 0xFF) << 16) | (((uint32_t)g & 0xFF) << 8) | ((uint32_t)b & 0xFF);
}

static uint32_t RGBFromLinrgb(const double linrgb[3]) {
    return RGBFromChannels(Delinearized(linrgb[0]), Delinearized(linrgb[1]), Delinearized(linrgb[2]));
}

static double YFromLstar(double lstar) {
    return 100.0 * LabInvF((lstar + 16.0) / 116.0);
}

static double LstarFromY(double y) {
    return LabF(y / 100.0) * 116.0 - 16.0;
}

static uint32_t RGBFromLstar(double lstar) {
    int component = Delinearized(YFromLstar(lstar));
    return RGBFromChannels(component, component, component);
}

static double LstarFromRGB(uint32_t rgb) {
    double r = Linearized((rgb >> 16) & 0xFF);
    double g = Linearized((rgb >> 8) & 0xFF);
    double b = Linearized(rgb & 0xFF);
    double y = kSRGBToXYZ[1][0] * r + kSRGBToXYZ[1][1] * g + kSRGBToXYZ[1][2] * b;
    return 116.0 * LabF(y / 100.0) - 16.0;
}

// ---------------------------------------------------------------------------
// viewing_conditions.ts — ViewingConditions.DEFAULT (sRGB-like), computed once.
// ---------------------------------------------------------------------------

typedef struct {
    double n, aw, nbb, ncb, c, nc;
    double rgbD[3];
    double fl, fLRoot, z;
} ViewingConditions;

static const ViewingConditions *DefaultViewingConditions(void) {
    static ViewingConditions vc;
    static bool initialized = false;
    if (!initialized) {
        const double *xyz = kWhitePointD65;
        double adaptingLuminance = (200.0 / M_PI) * YFromLstar(50.0) / 100.0;
        double backgroundLstar = 50.0;
        double surround = 2.0;

        double rW = xyz[0] * 0.401288 + xyz[1] * 0.650173 + xyz[2] * -0.051461;
        double gW = xyz[0] * -0.250268 + xyz[1] * 1.204414 + xyz[2] * 0.045854;
        double bW = xyz[0] * -0.002079 + xyz[1] * 0.048952 + xyz[2] * 0.953127;
        double f = 0.8 + surround / 10.0;
        double c = f >= 0.9 ? Lerp(0.59, 0.69, (f - 0.9) * 10.0)
                            : Lerp(0.525, 0.59, (f - 0.8) * 10.0);
        double d = f * (1.0 - (1.0 / 3.6) * exp((-adaptingLuminance - 42.0) / 92.0));
        d = ClampDouble(0.0, 1.0, d);
        double nc = f;
        double rgbD[3] = {
            d * (100.0 / rW) + 1.0 - d,
            d * (100.0 / gW) + 1.0 - d,
            d * (100.0 / bW) + 1.0 - d,
        };
        double k = 1.0 / (5.0 * adaptingLuminance + 1.0);
        double k4 = k * k * k * k;
        double k4F = 1.0 - k4;
        double fl = k4 * adaptingLuminance + 0.1 * k4F * k4F * cbrt(5.0 * adaptingLuminance);
        double n = YFromLstar(backgroundLstar) / xyz[1];
        double z = 1.48 + sqrt(n);
        double nbb = 0.725 / pow(n, 0.2);
        double ncb = nbb;
        double rgbAFactors[3] = {
            pow(fl * rgbD[0] * rW / 100.0, 0.42),
            pow(fl * rgbD[1] * gW / 100.0, 0.42),
            pow(fl * rgbD[2] * bW / 100.0, 0.42),
        };
        double rgbA[3] = {
            400.0 * rgbAFactors[0] / (rgbAFactors[0] + 27.13),
            400.0 * rgbAFactors[1] / (rgbAFactors[1] + 27.13),
            400.0 * rgbAFactors[2] / (rgbAFactors[2] + 27.13),
        };
        double aw = (2.0 * rgbA[0] + rgbA[1] + 0.05 * rgbA[2]) * nbb;

        vc.n = n; vc.aw = aw; vc.nbb = nbb; vc.ncb = ncb; vc.c = c; vc.nc = nc;
        vc.rgbD[0] = rgbD[0]; vc.rgbD[1] = rgbD[1]; vc.rgbD[2] = rgbD[2];
        vc.fl = fl; vc.fLRoot = pow(fl, 0.25); vc.z = z;
        initialized = true;
    }
    return &vc;
}

// ---------------------------------------------------------------------------
// cam16.ts — only the hue/chroma read path (Cam16.fromInt).
// ---------------------------------------------------------------------------

static void Cam16HueChromaFromRGB(uint32_t rgb, double *outHue, double *outChroma) {
    const ViewingConditions *vc = DefaultViewingConditions();
    double redL = Linearized((rgb >> 16) & 0xFF);
    double greenL = Linearized((rgb >> 8) & 0xFF);
    double blueL = Linearized(rgb & 0xFF);
    double x = 0.41233895 * redL + 0.35762064 * greenL + 0.18051042 * blueL;
    double y = 0.2126 * redL + 0.7152 * greenL + 0.0722 * blueL;
    double z = 0.01932141 * redL + 0.11916382 * greenL + 0.95034478 * blueL;

    double rC = 0.401288 * x + 0.650173 * y - 0.051461 * z;
    double gC = -0.250268 * x + 1.204414 * y + 0.045854 * z;
    double bC = -0.002079 * x + 0.048952 * y + 0.953127 * z;

    double rD = vc->rgbD[0] * rC;
    double gD = vc->rgbD[1] * gC;
    double bD = vc->rgbD[2] * bC;

    double rAF = pow(vc->fl * fabs(rD) / 100.0, 0.42);
    double gAF = pow(vc->fl * fabs(gD) / 100.0, 0.42);
    double bAF = pow(vc->fl * fabs(bD) / 100.0, 0.42);

    double rA = Signum(rD) * 400.0 * rAF / (rAF + 27.13);
    double gA = Signum(gD) * 400.0 * gAF / (gAF + 27.13);
    double bA = Signum(bD) * 400.0 * bAF / (bAF + 27.13);

    double a = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    double b = (rA + gA - 2.0 * bA) / 9.0;
    double u = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0;
    double p2 = (40.0 * rA + 20.0 * gA + bA) / 20.0;
    double atanDegrees = atan2(b, a) * 180.0 / M_PI;
    double hue = SanitizeDegrees(atanDegrees);

    double ac = p2 * vc->nbb;
    double j = 100.0 * pow(ac / vc->aw, vc->c * vc->z);
    double huePrime = hue < 20.14 ? hue + 360.0 : hue;
    double eHue = 0.25 * (cos(huePrime * M_PI / 180.0 + 2.0) + 3.8);
    double p1 = 50000.0 / 13.0 * eHue * vc->nc * vc->ncb;
    double t = p1 * sqrt(a * a + b * b) / (u + 0.305);
    double alpha = pow(t, 0.9) * pow(1.64 - pow(0.29, vc->n), 0.73);
    double chroma = alpha * sqrt(j / 100.0);

    *outHue = hue;
    *outChroma = chroma;
}

// ---------------------------------------------------------------------------
// hct_solver.ts
// ---------------------------------------------------------------------------

static const double kScaledDiscountFromLinrgb[3][3] = {
    {0.001200833568784504,   0.002389694492170889,  0.0002795742885861124},
    {0.0005891086651375999,  0.0029785502573438758, 0.0003270666104008398},
    {0.00010146692491640572, 0.0005364214359186694, 0.0032979401770712076},
};

static const double kLinrgbFromScaledDiscount[3][3] = {
    {1373.2198709594231,  -1100.4251190754821, -7.278681089101213},
    {-271.815969077903,   559.6580465940733,   -32.46047482791194},
    {1.9622899599665666,  -57.173814538844006, 308.7233197812385},
};

static const double kYFromLinrgb[3] = {0.2126, 0.7152, 0.0722};

static const double kCriticalPlanes[255] = {
    0.015176349177441876, 0.045529047532325624, 0.07588174588720938,
    0.10623444424209313,  0.13658714259697685,  0.16693984095186062,
    0.19729253930674434,  0.2276452376616281,   0.2579979360165119,
    0.28835063437139563,  0.3188300904430532,   0.350925934958123,
    0.3848314933096426,   0.42057480301049466,  0.458183274052838,
    0.4976837250274023,   0.5391024159806381,   0.5824650784040898,
    0.6277969426914107,   0.6751227633498623,   0.7244668422128921,
    0.775853049866786,    0.829304845476233,    0.8848452951698498,
    0.942497089126609,    1.0022825574869039,   1.0642236851973577,
    1.1283421258858297,   1.1946592148522128,   1.2631959812511864,
    1.3339731595349034,   1.407011200216447,    1.4823302800086415,
    1.5599503113873272,   1.6398909516233677,   1.7221716113234105,
    1.8068114625156377,   1.8938294463134073,   1.9832442801866852,
    2.075074464868551,    2.1693382909216234,   2.2660538449872063,
    2.36523901573795,     2.4669114995532007,   2.5710888059345764,
    2.6777882626779785,   2.7870270208169257,   2.898822059350997,
    3.0131901897720907,   3.1301480604002863,   3.2497121605402226,
    3.3718988244681087,   3.4967242352587946,   3.624204428461639,
    3.754355295633311,    3.887192587735158,    4.022731918402185,
    4.160988767090289,    4.301978482107941,    4.445716283538092,
    4.592217266055746,    4.741496401646282,    4.893568542229298,
    5.048448422192488,    5.20615066083972,     5.3666897647573375,
    5.5300801301023865,   5.696336044816294,    5.865471690767354,
    6.037501145825082,    6.212438385869475,    6.390297286737924,
    6.571091626112461,    6.7548350853498045,   6.941541251256611,
    7.131223617812143,    7.323895587840543,    7.5195704746346665,
    7.7182615035334345,   7.919981813454504,    8.124744458384042,
    8.332562408825165,    8.543448553206703,    8.757415699253682,
    8.974476575321063,    9.194643831691977,    9.417930041841839,
    9.644347703669503,    9.873909240696694,    10.106627003236781,
    10.342513269534024,   10.58158024687427,    10.8238400726681,
    11.069304815507364,   11.317986476196008,   11.569896988756009,
    11.825048221409341,   12.083451977536606,   12.345119996613247,
    12.610063955123938,   12.878295467455942,   13.149826086772048,
    13.42466730586372,    13.702830557985108,   13.984327217668513,
    14.269168601521828,   14.55736596900856,    14.848930523210871,
    15.143873411576273,   15.44220572664832,    15.743938506781891,
    16.04908273684337,    16.35764934889634,    16.66964922287304,
    16.985093187232053,   17.30399201960269,    17.62635644741625,
    17.95219714852476,    18.281524751807332,   18.614349837764564,
    18.95068293910138,    19.290534541298456,   19.633915083172692,
    19.98083495742689,    20.331304511189067,   20.685334046541502,
    21.042933821039977,   21.404114048223256,   21.76888489811322,
    22.137256497705877,   22.50923893145328,    22.884842241736916,
    23.264076429332462,   23.6469514538663,     24.033477234264016,
    24.42366364919083,    24.817520537484558,   25.21505769858089,
    25.61628489293138,    26.021211842414342,   26.429848230738664,
    26.842203703840827,   27.258287870275353,   27.678110301598522,
    28.10168053274597,    28.529008062403893,   28.96010235337422,
    29.39497283293396,    29.83362889318845,    30.276079891419332,
    30.722335150426627,   31.172403958865512,   31.62629557157785,
    32.08401920991837,    32.54558406207592,    33.010999283389665,
    33.4802739966603,     33.953417292456834,   34.430438229418264,
    34.911345834551085,   35.39614910352207,    35.88485700094671,
    36.37747846067349,    36.87402238606382,    37.37449765026789,
    37.87891309649659,    38.38727753828926,    38.89959975977785,
    39.41588851594697,    39.93615253289054,    40.460400508064545,
    40.98864111053629,    41.520882981230194,   42.05713473317016,
    42.597404951718396,   43.141702194811224,   43.6900349931913,
    44.24241185063697,    44.798841244188324,   45.35933162437017,
    45.92389141541209,    46.49252901546552,    47.065252796817916,
    47.64207110610409,    48.22299226451468,    48.808024568002054,
    49.3971762874833,     49.9904556690408,     50.587870934119984,
    51.189430279724725,   51.79514187861014,    52.40501387947288,
    53.0190544071392,     53.637271562750364,   54.259673423945976,
    54.88626804504493,    55.517063457223934,   56.15206766869424,
    56.79128866487574,    57.43473440856916,    58.08241284012621,
    58.734331877617365,   59.39049941699807,    60.05092333227251,
    60.715611475655585,   61.38457167773311,    62.057811747619894,
    62.7353394731159,     63.417162620860914,   64.10328893648692,
    64.79372614476921,    65.48848194977529,    66.18756403501224,
    66.89098006357258,    67.59873767827808,    68.31084450182222,
    69.02730813691093,    69.74813616640164,    70.47333615344107,
    71.20291564160104,    71.93688215501312,    72.67524319850172,
    73.41800625771542,    74.16517879925733,    74.9167682708136,
    75.67278210128072,    76.43322770089146,    77.1981124613393,
    77.96744375590167,    78.74122893956174,    79.51947534912904,
    80.30219030335869,    81.08938110306934,    81.88105503125999,
    82.67721935322541,    83.4778813166706,     84.28304815182372,
    85.09272707154808,    85.90692527145302,    86.72564993000343,
    87.54890820862819,    88.3767072518277,     89.2090541872801,
    90.04595612594655,    90.88742016217518,    91.73345337380438,
    92.58406282226491,    93.43925555268066,    94.29903859396902,
    95.16341895893969,    96.03240364439274,    96.9059996312159,
    97.78421388448044,    98.6670533535366,     99.55452497210776,
};

static double SanitizeRadians(double angle) {
    return fmod(angle + M_PI * 8, M_PI * 2);
}

static double TrueDelinearized(double rgbComponent) {
    double normalized = rgbComponent / 100.0;
    double delinearized;
    if (normalized <= 0.0031308) {
        delinearized = normalized * 12.92;
    } else {
        delinearized = 1.055 * pow(normalized, 1.0 / 2.4) - 0.055;
    }
    return delinearized * 255.0;
}

static double ChromaticAdaptation(double component) {
    double af = pow(fabs(component), 0.42);
    return Signum(component) * 400.0 * af / (af + 27.13);
}

// Hue of a linear RGB colour in CAM16, in radians.
static double HueOf(const double linrgb[3]) {
    double scaledDiscount[3];
    MatrixMultiply(linrgb, kScaledDiscountFromLinrgb, scaledDiscount);
    double rA = ChromaticAdaptation(scaledDiscount[0]);
    double gA = ChromaticAdaptation(scaledDiscount[1]);
    double bA = ChromaticAdaptation(scaledDiscount[2]);
    double a = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    double b = (rA + gA - 2.0 * bA) / 9.0;
    return atan2(b, a);
}

static bool AreInCyclicOrder(double a, double b, double c) {
    double deltaAB = SanitizeRadians(b - a);
    double deltaAC = SanitizeRadians(c - a);
    return deltaAB < deltaAC;
}

static double Intercept(double source, double mid, double target) {
    return (mid - source) / (target - source);
}

static void LerpPoint(const double source[3], double t, const double target[3], double out[3]) {
    out[0] = source[0] + (target[0] - source[0]) * t;
    out[1] = source[1] + (target[1] - source[1]) * t;
    out[2] = source[2] + (target[2] - source[2]) * t;
}

static void SetCoordinate(const double source[3], double coordinate, const double target[3], int axis, double out[3]) {
    double t = Intercept(source[axis], coordinate, target[axis]);
    LerpPoint(source, t, target, out);
}

static bool IsBounded(double x) {
    return 0.0 <= x && x <= 100.0;
}

// Nth possible vertex of the intersection of the y plane and the RGB cube, in
// linear RGB coordinates; [-1,-1,-1] if it lies outside the cube.
static void NthVertex(double y, int n, double out[3]) {
    double kR = kYFromLinrgb[0], kG = kYFromLinrgb[1], kB = kYFromLinrgb[2];
    double coordA = (n % 4) <= 1 ? 0.0 : 100.0;
    double coordB = (n % 2) == 0 ? 0.0 : 100.0;
    if (n < 4) {
        double g = coordA, b = coordB;
        double r = (y - g * kG - b * kB) / kR;
        if (IsBounded(r)) { out[0] = r; out[1] = g; out[2] = b; return; }
    } else if (n < 8) {
        double b = coordA, r = coordB;
        double g = (y - r * kR - b * kB) / kG;
        if (IsBounded(g)) { out[0] = r; out[1] = g; out[2] = b; return; }
    } else {
        double r = coordA, g = coordB;
        double b = (y - r * kR - g * kG) / kB;
        if (IsBounded(b)) { out[0] = r; out[1] = g; out[2] = b; return; }
    }
    out[0] = -1.0; out[1] = -1.0; out[2] = -1.0;
}

static void BisectToSegment(double y, double targetHue, double outLeft[3], double outRight[3]) {
    double left[3] = {-1.0, -1.0, -1.0};
    double right[3] = {-1.0, -1.0, -1.0};
    double leftHue = 0.0, rightHue = 0.0;
    bool initialized = false, uncut = true;
    for (int n = 0; n < 12; n++) {
        double mid[3];
        NthVertex(y, n, mid);
        if (mid[0] < 0) continue;
        double midHue = HueOf(mid);
        if (!initialized) {
            left[0] = mid[0]; left[1] = mid[1]; left[2] = mid[2];
            right[0] = mid[0]; right[1] = mid[1]; right[2] = mid[2];
            leftHue = midHue;
            rightHue = midHue;
            initialized = true;
            continue;
        }
        if (uncut || AreInCyclicOrder(leftHue, midHue, rightHue)) {
            uncut = false;
            if (AreInCyclicOrder(leftHue, targetHue, midHue)) {
                right[0] = mid[0]; right[1] = mid[1]; right[2] = mid[2];
                rightHue = midHue;
            } else {
                left[0] = mid[0]; left[1] = mid[1]; left[2] = mid[2];
                leftHue = midHue;
            }
        }
    }
    outLeft[0] = left[0]; outLeft[1] = left[1]; outLeft[2] = left[2];
    outRight[0] = right[0]; outRight[1] = right[1]; outRight[2] = right[2];
}

static int CriticalPlaneBelow(double x) {
    return (int)floor(x - 0.5);
}

static int CriticalPlaneAbove(double x) {
    return (int)ceil(x - 0.5);
}

// Colour with the given Y and hue on the boundary of the RGB cube, linear RGB.
static void BisectToLimit(double y, double targetHue, double out[3]) {
    double left[3], right[3];
    BisectToSegment(y, targetHue, left, right);
    double leftHue = HueOf(left);
    for (int axis = 0; axis < 3; axis++) {
        if (left[axis] != right[axis]) {
            int lPlane, rPlane;
            if (left[axis] < right[axis]) {
                lPlane = CriticalPlaneBelow(TrueDelinearized(left[axis]));
                rPlane = CriticalPlaneAbove(TrueDelinearized(right[axis]));
            } else {
                lPlane = CriticalPlaneAbove(TrueDelinearized(left[axis]));
                rPlane = CriticalPlaneBelow(TrueDelinearized(right[axis]));
            }
            for (int i = 0; i < 8; i++) {
                if (abs(rPlane - lPlane) <= 1) break;
                int mPlane = (int)floor((lPlane + rPlane) / 2.0);
                double midPlaneCoordinate = kCriticalPlanes[mPlane];
                double mid[3];
                SetCoordinate(left, midPlaneCoordinate, right, axis, mid);
                double midHue = HueOf(mid);
                if (AreInCyclicOrder(leftHue, targetHue, midHue)) {
                    right[0] = mid[0]; right[1] = mid[1]; right[2] = mid[2];
                    rPlane = mPlane;
                } else {
                    left[0] = mid[0]; left[1] = mid[1]; left[2] = mid[2];
                    leftHue = midHue;
                    lPlane = mPlane;
                }
            }
        }
    }
    out[0] = (left[0] + right[0]) / 2;
    out[1] = (left[1] + right[1]) / 2;
    out[2] = (left[2] + right[2]) / 2;
}

static double InverseChromaticAdaptation(double adapted) {
    double adaptedAbs = fabs(adapted);
    double base = 27.13 * adaptedAbs / (400.0 - adaptedAbs);
    if (base < 0) base = 0;
    return Signum(adapted) * pow(base, 1.0 / 0.42);
}

// Colour with the given hue/chroma/Y as 0xRRGGBB, or 0 if the Newton search
// fell out of gamut (caller falls back to BisectToLimit).
static uint32_t FindResultByJ(double hueRadians, double chroma, double y) {
    double j = sqrt(y) * 11.0;
    const ViewingConditions *vc = DefaultViewingConditions();
    double tInnerCoeff = 1.0 / pow(1.64 - pow(0.29, vc->n), 0.73);
    double eHue = 0.25 * (cos(hueRadians + 2.0) + 3.8);
    double p1 = eHue * (50000.0 / 13.0) * vc->nc * vc->ncb;
    double hSin = sin(hueRadians);
    double hCos = cos(hueRadians);
    for (int iterationRound = 0; iterationRound < 5; iterationRound++) {
        double jNormalized = j / 100.0;
        double alpha = (chroma == 0.0 || j == 0.0) ? 0.0 : chroma / sqrt(jNormalized);
        double t = pow(alpha * tInnerCoeff, 1.0 / 0.9);
        double ac = vc->aw * pow(jNormalized, 1.0 / vc->c / vc->z);
        double p2 = ac / vc->nbb;
        double gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11.0 * t * hCos + 108.0 * t * hSin);
        double a = gamma * hCos;
        double b = gamma * hSin;
        double rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
        double gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
        double bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;
        double scaled[3] = {
            InverseChromaticAdaptation(rA),
            InverseChromaticAdaptation(gA),
            InverseChromaticAdaptation(bA),
        };
        double linrgb[3];
        MatrixMultiply(scaled, kLinrgbFromScaledDiscount, linrgb);
        if (linrgb[0] < 0 || linrgb[1] < 0 || linrgb[2] < 0) return 0;
        double kR = kYFromLinrgb[0], kG = kYFromLinrgb[1], kB = kYFromLinrgb[2];
        double fnj = kR * linrgb[0] + kG * linrgb[1] + kB * linrgb[2];
        if (fnj <= 0) return 0;
        if (iterationRound == 4 || fabs(fnj - y) < 0.002) {
            if (linrgb[0] > 100.01 || linrgb[1] > 100.01 || linrgb[2] > 100.01) return 0;
            return RGBFromLinrgb(linrgb);
        }
        j = j - (fnj - y) * j / (2 * fnj);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

uint32_t ApolloHCTToRGB(double hue, double chroma, double tone) {
    if (chroma < 0.0001 || tone < 0.0001 || tone > 99.9999) {
        return RGBFromLstar(tone);
    }
    hue = SanitizeDegrees(hue);
    double hueRadians = hue / 180.0 * M_PI;
    double y = YFromLstar(tone);
    uint32_t exactAnswer = FindResultByJ(hueRadians, chroma, y);
    if (exactAnswer != 0) return exactAnswer;
    // NOTE: FindResultByJ can't legitimately return black (its in-gamut exits
    // return a colour with y > 0), so 0 is unambiguous as "not found" — same
    // sentinel contract as the reference implementation.
    double linrgb[3];
    BisectToLimit(y, hueRadians, linrgb);
    return RGBFromLinrgb(linrgb);
}

ApolloHCT ApolloHCTFromRGB(uint32_t rgb) {
    ApolloHCT hct;
    Cam16HueChromaFromRGB(rgb, &hct.hue, &hct.chroma);
    hct.tone = LstarFromRGB(rgb);
    return hct;
}

ApolloHCT ApolloHCTSolved(double hue, double chroma, double tone) {
    return ApolloHCTFromRGB(ApolloHCTToRGB(hue, chroma, tone));
}

double ApolloHCTRatioOfTones(double toneA, double toneB) {
    toneA = ClampDouble(0.0, 100.0, toneA);
    toneB = ClampDouble(0.0, 100.0, toneB);
    double y1 = YFromLstar(toneA);
    double y2 = YFromLstar(toneB);
    double lighter = y1 > y2 ? y1 : y2;
    double darker = (lighter == y2) ? y1 : y2;
    return (lighter + 5.0) / (darker + 5.0);
}

double ApolloHCTLighterUnsafe(double tone, double ratio) {
    if (tone < 0.0 || tone > 100.0) return 100.0;
    double darkY = YFromLstar(tone);
    double lightY = ratio * (darkY + 5.0) - 5.0;
    double lighter = lightY > darkY ? lightY : darkY;
    double darker = (lighter == darkY) ? lightY : darkY;
    double realContrast = (lighter + 5.0) / (darker + 5.0);
    double delta = fabs(realContrast - ratio);
    if (realContrast < ratio && delta > 0.04) return 100.0;
    // + 0.4 keeps the ratio after gamut mapping (see contrast.ts).
    double returnValue = LstarFromY(lightY) + 0.4;
    if (returnValue < 0 || returnValue > 100) return 100.0;
    return returnValue;
}

double ApolloHCTDarkerUnsafe(double tone, double ratio) {
    if (tone < 0.0 || tone > 100.0) return 0.0;
    double lightY = YFromLstar(tone);
    double darkY = (lightY + 5.0) / ratio - 5.0;
    double lighter = lightY > darkY ? lightY : darkY;
    double darker = (lighter == darkY) ? lightY : darkY;
    double realContrast = (lighter + 5.0) / (darker + 5.0);
    double delta = fabs(realContrast - ratio);
    if (realContrast < ratio && delta > 0.04) return 0.0;
    double returnValue = LstarFromY(darkY) - 0.4;
    if (returnValue < 0 || returnValue > 100) return 0.0;
    return returnValue;
}
