// Chrome's canvas, as the reference for the bolts' and seeds' glow (SPEC mode 17).
//
// Measured in Chrome (headless, `--force-device-scale-factor=1` and `=2`) with the statements of
// stage.js `renderSeeds` / `renderBolts`, on a canvas sized `w * dpr` with `setTransform(dpr, 0, 0,
// dpr, 0, 0)` exactly as `layoutRing` sets up the flame canvas, over `rgb(10, 10, 26)`:
//
//     // seed at (50, 50), age t: alpha = 1 - t, core = max(0.8, 2.2 (1 - t) + 0.5)
//     ctx.shadowColor = `rgba(255,220,150,${0.8 * alpha})`; ctx.shadowBlur = 10;
//     ctx.fillStyle = `rgba(255,240,210,${0.95 * alpha})`;
//     ctx.beginPath(); ctx.arc(50, 50, core, 0, 2 * Math.PI); ctx.fill();
//
//     // straight bolt (10,50) -> (90,50) at alpha a
//     ctx.lineCap = ctx.lineJoin = 'round';
//     ctx.strokeStyle = `rgba(200,225,255,${0.85 * a})`; ctx.shadowColor = `rgba(120,180,255,${0.9 * a})`;
//     ctx.shadowBlur = 10; ctx.lineWidth = 2.2; ctx.stroke();
//     ctx.strokeStyle = `rgba(255,255,255,${0.9 * a})`; ctx.shadowBlur = 4; ctx.lineWidth = 1; ctx.stroke();
//
// and read back with `getImageData` in DEVICE pixels: the seed's row from its centre outward
// (red channel: the glow is warm), the bolt's column from its line downward (blue channel: the
// glow is blue). The arrays are those device pixels, `k` pixels from the centre / line. The
// shadow blur is in device pixels whatever `dpr` is (the glow is as many device pixels across at
// dpr 2 as at dpr 1), which `StageBolts.sigma(ofBlur:displayScale:)` accounts for.
//
// Only the numbers are kept here; the page is a dozen lines to re-create.

enum ChromeGlow {
  /// Red channel of the seed's row, key "<age>@<dpr>".
  static let seedRed: [String: [Int]] = [
    "0@1": [244, 244, 166, 33, 30, 26, 22, 19, 16, 14, 12, 11, 10, 10],
    "0.436@1": [142, 85, 12, 12, 11, 11, 10, 10, 10, 10, 10, 10, 10, 10],
    "0@2": [
      247, 247, 246, 246, 246, 116, 55, 45, 36, 30, 23, 18, 15, 12, 11, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10, 10,
    ],
    "0.436@2": [
      148, 147, 147, 72, 19, 17, 16, 14, 12, 11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
      10, 10, 10, 10,
    ],
  ]

  /// Blue channel of the bolt's column, key "<alpha>@<dpr>".
  static let boltBlue: [String: [Int]] = [
    "1.0@1": [241, 77, 68, 58, 49, 42, 37, 34, 32, 30, 28, 26, 26, 26, 26],
    "0.5@1": [158, 39, 36, 33, 30, 29, 28, 27, 26, 26, 26, 26, 26, 26, 26],
    "1.0@2": [
      254, 235, 142, 93, 77, 63, 53, 46, 40, 35, 31, 28, 27, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
      26, 26, 26, 26, 26, 26,
    ],
    "0.5@2": [
      191, 138, 69, 43, 37, 34, 32, 30, 29, 27, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26, 26,
      26, 26, 26, 26, 26, 26,
    ],
  ]
}
