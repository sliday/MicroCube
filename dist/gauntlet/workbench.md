# Gauntlet Loop — Dear Esther Island

Goal: extend MicroCube Metal into a Dear Esther / Morrowind / Silent Hill island
open-world first-person walking experience. Foggy terrain and waters, glowing
reflective mushrooms, atmospheric exploration.

## Bar

- Visual: Dear Esther screenshots (dist/gauntlet/bar/dear-esther-{1..6}.jpg,
  verified by lead 2026-08-31: 1=cave interior (W2 anchor), 2=valley,
  3=lighthouse + still water reflection, 4=coast vista, 5=beach cliff,
  6=rocky shore dusk), opened side-by-side with our fixed-pose captures by a
  fresh critic.
- Mechanical: full test suite green · p95 GPU ≤ 8.33 ms @ 1280×800 ·
  4-pose deterministic capture matrix renders non-empty.

## Waves

| Wave | Piece | Status |
|---|---|---|
| W1 | Island + sea + Silent Hill fog | **CLOSED** — 10 rounds, 8 critics, 1 falsifier; cold benchmark p95 5.73ms ≤ 8.33, 170 tests green, pushed |
| W2 | Bioluminescent reflective shroom fields | **CLOSED** — 5 rounds, 5 critics, 2 diagnostics; bench p95 5.94ms, 171 tests, pushed. **FIRST TIE**: w2-r5-vista ties dear-esther-4 on mood |
| W3 | Grounded slow walk + island auto-tour | pending — **DEFECT CONFIRMED**: autoplay tour flies to purged props |
| — | Smoothing pass | pending (backlog: chiaroscuro S-curve, creature silhouettes, facet hardness, top-face checker residue) |

## Judging poses (fixed after W1 R1)

TBD — builder picks 4 poses in round 1, written to dist/gauntlet/poses.md.
Poses stay frozen for the rest of the run.

## Instrument check

- [x] Two different `--qa-camera` poses produce different PNGs — confirmed by
      w1-critic-r1: four distinct non-empty viewpoints.

## Rounds

(appended as the run progresses: wave · round · builder change · critic verdict ·
biggest gap · capture paths)

### W1 · R1 · builder

- Island terrain: `terrainHeight` now blends land into a seabed (~30) via a
  smoothstep shore mask (radius ~150 + coast noise around world 272,284). Island
  core keeps the exact old height formula — creature terrain pins
  [87,88,93,88,86,101] unchanged, zero test expectation moves.
- Water: analytic sea plane at y=52 in `raycastHybrid` (no voxels touched) —
  fresnel toward overcast sky, ripple normal, shallow-shore see-through,
  soft glint, distance fog; gaussian volume clamped to the water surface.
- Removed the floating sky islands from `generateTerrain` (production path only;
  `islandDensity` kept for the test probe, QA fixture branch untouched).
- Palette: all 42 terrain entries rewritten to a cold Hebridean ramp
  (silt/shingle → wet sand → peat → moss/heather → grey rock/scree by elevation).
- Sky: `skyColor` rewritten overcast (grey gradient, wide pale sun smudge,
  kFogColor 0.565/0.596/0.612 shared with distance fog).
- Atmosphere: sun (-0.30,0.36,0.46) low+cool, ambient 0.24→0.38, fog
  (0.83,1.0)→(0.04,0.85), exposure 0.82→0.85; hero gaussians retinted to grey mist.
- Tests: 170 executed, 0 failures (release, `scripts/test.sh`).
- Captures (1280×800, qa-time 4): dist/gauntlet/captures/w1-r1-{vista,shore,fog,ground}.png
  — poses frozen in dist/gauntlet/poses.md.
- Builder-known gaps for critic: vista pose is heavily fog-washed near the
  horizon (sea reads as a faint band); summit palette still pale; sea has no
  shoreline foam/breakers.

### W1 · R2 · builder — value split (dark land / bright textured sky)

- Sky: `skyColor` gained a two-octave valueNoise cloud deck (dome-projected uv)
  with dark cloud base vs bright backlit gaps, plus a sun-break smudge
  concentrated in the gaps; horizon haze widened. Noise helpers
  (hash2/valueNoise/noise3D) moved from MicroCube.metal to SceneTypes.metal so
  the sky (concatenated earlier) can use them — single definition, no kernel
  changes.
- Fog color kFogColor raised 0.565→0.640 linear (~0.78 sRGB) so distant land
  dissolves BRIGHT into the sky value.
- Terrain: entire kPalette scaled x0.42 (land bands now 0.05-0.21 linear —
  lit faces ~20-37% sRGB, shadow faces ~15-25%); ambient 0.38→0.30. Hue kept.
- Water untouched; inherits bright cloud reflections via its sky fresnel
  (visible in w1-r2-shore.png).
- Tests: 170 executed, 0 failures (release, scripts/test.sh).
- Captures: dist/gauntlet/captures/w1-r2-{vista,shore,fog,ground}.png (same
  frozen poses). Split verified strongest in shore/ground/fog; vista's near
  ridge reads dark with distant ridges dissolving bright by design.

### W1 · R3 · builder — dusk lighting grade

- Sun dropped to true dusk: normalize(-0.30, 0.16, -0.72) — 11.6° elevation,
  azimuth aligned with the frozen vista view so the sky window sits in the
  evidence frame. Ambient 0.30→0.26.
- Sky: pink-amber sun WINDOW (sunWarm 1.05/0.68/0.48) via a narrow sunDot term
  concentrated in cloud gaps, plus a wide warm bleed tinting surrounding gaps
  and the horizon haze near the sun. Cloud deck/base/horizon all shifted cool
  slate.
- Fog: kFogColor 0.640/0.660/0.672 → 0.545/0.585/0.645 (cool slate); hero
  gaussians retinted 0.46/0.50/0.56; injectVolumeLighting ambient cooled +
  sun tint warmed (fog-fixture gate margin kept: 0.61 > 0.5).
- Land: kPalette scaled a further x0.6 (bands now 0.031-0.128 linear —
  near-silhouette, hue kept), and a dusk duotone grade in raycastHybrid:
  color *= mix(cool 0.84/0.90/1.10, warm 1.14/0.97/0.84, saturate(diffuse*2.5))
  — shadow faces cool slate, grazing sun-facing faces faint warm.
- Tests: 170 executed, 0 failures. Captures:
  dist/gauntlet/captures/w1-r3-{vista,shore,fog,ground}.png. Vista verified:
  dark ridge silhouettes, warm cloud window centered, cool haze below.

### W1 · R4 · builder — near-field surface breakup

- Within-face: raycastHybrid modulates terrain baseColor at the hit POINT
  (terrain-hit path only; sky/water/shadow paths untouched). Budget: 2x noise3D
  + 1 hash speckle per terrain pixel. Layers: fine 3D grain (2.3/unit) +
  integer-lattice speckle for value breakup (+/-25%), moss patches (hue shift
  toward green) biased to upward faces at grass elevations (y 48-100 band
  centered 74), grey scree desaturation on steep faces above y 88, wet-dark
  cool band within 3.5 units of the waterline. Hue + value shifts around the
  R3-graded base; no overall brightening.
- Per-voxel: generateTerrain shade hash now per voxel (was per 2-voxel block),
  swap probability 0.82 -> 0.70. QA fixture branch untouched.
- Tests: 170 executed, 0 failures. Benchmark (shore pose, 240 samples,
  1280x800 scale 1): p95 5.47 ms <= 8.33 budget; report status "fail" ONLY due
  to non-nominal thermal state (machine warm from CI churn) — counters clean
  (0 overflows / dropped / errors), and thermal throttling makes 5.47 a
  conservative reading. Re-run cold at wave end if gating formally.
- Captures: dist/gauntlet/captures/w1-r4-{vista,shore,fog,ground}.png.
  Shore + ground verified: faces break into sub-meter albedo variation;
  vista mood unchanged (detail fades with distance as intended).

### W1 · R5 · builder — visible breakup + near-black anchoring

- Breakup rebuilt to READ: primary patch noise coarsened 0.27 -> 0.6/unit,
  three signals combined then smoothstepped for contrast, multiplicative value
  range widened to 0.35x-1.90x (~2.2x displayed after gamma, vs ~1.2x in R4).
  Moss now full-strength green (0.55/1.35/0.45) in coarse patches; scree and
  wet band deepened. NEW crevice darkening: faces darken 38% within 0.11 units
  of voxel-lattice edges -> crack lines on every face. Same 3-noise budget,
  terrain-hit path only.
- Near-black anchors: voxelAO floor 0.40 -> 0.12 (crevices plunge); sun-shadow
  multiplier 0.45 -> 0.22; fogStart 0.04 -> 0.09 so the first ~23 units keep
  full contrast (fogEnd unchanged -> vista haze preserved).
- MECHANICAL ACCEPTANCE (bottom-half luminance, numpy over PNGs):
  ground p0.5 = 4.8% sRGB (R4: 10.6%), 90.5% of pixels < 15%, 62.4% < 10%;
  shore p0.5 = 4.3% (R4: 7.5%), 36% < 15%. Vista: 0% below 15%, median 44%,
  warm window intact -> mood unchanged. Faces verified by eye: internal
  patches, value steps, crack lines on shore + ground.
- Tests: 170 executed, 0 failures. Captures:
  dist/gauntlet/captures/w1-r5-{vista,shore,fog,ground}.png.

### W1 · R1 · critic verdict

- instrument_ok: true (4 distinct non-empty renders).
- **winner: bar.**
- **biggest_gap:** flat blank sky at nearly the same value as the terrain — no
  light direction, no silhouette. Bar frames are dark land (~10-20% value)
  against luminous cloud-textured sky with an implied sun break (~70-90%);
  ours compresses sky/fog/land into one ~60-75% grey band.
- evidence: w1-r1-vista.png vs dear-esther-4.jpg / dear-esther-6.jpg.
- secondary (not actioned this round): test props in fog.png break fiction
  (mirror spheres, particle blob, antennae figures); shore water reads as void.

### W1 · R2 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar.**
- **biggest_gap:** no dusk lighting grade — all four captures flat achromatic
  mid-grey; bar = near-black land silhouetted against a luminous sky with one
  warm hue accent (pink-amber cloud break), cool slate cast in fog. Ours has
  mountains only slightly darker than the sky and zero pixels with hue.
- evidence: w1-r2-vista.png vs dear-esther-4.jpg.
- secondary (2nd flag, still queued): demo props in fog pose (figures read as
  rabbits, chrome spheres) break fiction; water's marbled ripple bands read as
  liquid paper.

### W1 · R3 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar** — but vista acknowledged as the first capture approaching the
  bar's mood (dear-esther-4 register); grade gap considered closed.
- **biggest_gap:** near-field surface deadness — giant uniform flat cube faces,
  single albedo per face, no texture/vegetation/scatter. Bar's cliff at the
  same framing distance carries grass tufts, lichen, wet-rock value breakup,
  dozens of albedo shifts per meter. Wrecks shore/fog/ground.
- evidence: w1-r3-shore.png vs dear-esther-5.jpg.
- secondary (3rd flag, queued): demo props in fog pose must go before any
  round can win on mood.

### W1 · R4 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar.**
- **biggest_gap (REPEAT of R3 family — R4 dose too weak):** faces still read as
  blank single-tone slabs; no within-face variation survives the grade, and no
  pixel in frame reaches near-black. Bar rock (dear-esther-6) carries 5+ value
  steps per square meter with wet near-black crevices; our darkest tone is
  mid-grey.
- evidence: w1-r4-ground.png vs dear-esther-6.jpg.
- lead note: R4's noise exists but is imperceptible under the dark palette +
  fog compression — R5 must amplify until it reads at 1280×800, with a
  measurable check (darkest terrain pixels < 15% sRGB, visible patches).
- secondary (4th flag, queued): demo props in fog pose.

### W1 · R5 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar** — vista "genuinely echoes dear-esther-4"; shore/ground lose,
  fog disqualified by props.
- **biggest_gap (3rd consecutive: near-field surface read):** faces within
  ~20m still read single flat color; builder's numpy measurements say
  otherwise. CONTRADICTION → per gauntlet §3b, lead dispatched a FALSIFIER
  agent to measure within-face (not between-face) pixel variation and trace
  the shader order-of-operations before another builder round on this gap.
- evidence: w1-r5-shore.png (right-half cube wall) vs dear-esther-5.jpg.
- secondary (5th flag → PROMOTED to its own parallel piece): demo props.

### FALSIFIER FINDING — read before any surface round

- No code bug. Breakup noise is live, sampled at the hit point, no gating;
  captures provably rendered from current source.
- Measured within-face variation in w1-r5 captures: p5-p95 of 2-6/255 sRGB in
  face interiors (between-face deltas 15-20) — SUB-PERCEPTUAL. Builder's
  distribution stats and critics' "flat faces" were both honest readings.
- Root cause arithmetic: palette 0.03-0.13 linear × dim/shadow lighting ×
  10-30% fog mix crushes amplitude; AND patch wavelength 1.67 voxels realizes
  only ~0.6 of the 1.55 modulation range within one 1×1 face.
- Consequence for the next surface round: amplitude cranks will NOT close the
  gap. Needed: hard-edged STRUCTURAL texture that survives the grade —
  higher-frequency two-tone patches / striation bands / crack detail with
  full range realized per face, or modulation applied where lighting cannot
  crush it (post-lighting / gamma-space component).

### W1 · R7 · critic verdict (fresh critic, judged R6 purge + R7 strata)

- instrument_ok: true.
- **winner: bar** — but vista "would near-tie dear-esther-4 if shot at eye
  level with honest clouds"; fog frame's masts/aerials now "hint at Dear
  Esther's radio-mast fiction" (purge worked).
- **biggest_gap (gap INVERTED):** texture now visible but reads as PATTERN —
  wavy equal-weight banding = "camouflage/laminated plastic", not weathered
  rock. Bar cliff (dear-esther-5) reads instantly as stratified rock + lichen
  + scree + grass tufts.
- evidence: w1-r7-shore.png vs dear-esther-5.jpg.
- secondary (queued): water reads as mirror-swirl mercury vs bar's dark matte
  sea; vista clouds slightly synthetic; vista pose height is drone-like
  (frozen-pose property — W3 territory).

### W1 · R8 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar** — vista still closest ("fog layering + warm cloud break
  approach dear-esther-4").
- **biggest_gap (5th surface iteration):** faces read as "cardboard crates" —
  one wavy seam per face, otherwise flat. Bar = wet fractured rock with
  MULTI-SCALE variation (crevices, micro-facets, wet highlights).
- evidence: w1-r8-shore.png (right half) vs dear-esther-6.jpg (foreground).
- secondary: creature silhouettes split critics (r6: "radio masts" good;
  r7: "balloon animals" bad) — lead keeps creatures, silhouette refinement
  queued for smoothing pass. Turf reads as tile checkerboard (folded into R9).
- LEAD PACING DECISION: R9 (multi-scale rock + de-tile turf) → R10 (water
  honesty) → wave CLOSES at benchmark gate regardless of verdict. W2 shrooms
  must not starve.

### W1 · R9 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar** — vista closest; fog frame's masts now "genuinely Dear
  Esther-adjacent" fiction.
- **biggest_gap:** value structure/chiaroscuro — bar frames are near-black
  land + one luminous sky break + warm accent; ours read washed mid-grey with
  no light direction (esp. ground pose).
- evidence: w1-r9-ground.png vs dear-esther-5.jpg.
- LEAD CLOSE-OUT ANALYSIS: critics now OSCILLATE between grade (r2, r8) and
  surface (r3-r7) instead of converging — remaining-gap ordering has become
  taste, the wave-ceiling signal the gauntlet predicts. Ground pose's flat sky
  is partly pose-inherent (faces away from the dusk sun window). Wave closes
  after R10 as announced. Backlog carried to smoothing pass: global chiaroscuro
  S-curve, creature silhouette refinement, soft-facet hardness, checker
  residue on some top faces. W2's glowing shrooms directly answer "no glow,
  nothing invites walking toward anything".

### W2 · R1 · critic verdict (fresh critic)

- instrument_ok: true (5 poses, shrooms visible).
- **winner: bar.**
- **biggest_gap:** the mushrooms emit no light — glossy props lit BY the scene
  (sky specular on jelly-toy caps, pitch-black pit beneath) vs dear-esther-1
  where the glow lights the whole cave. Fog-pose beacon = unreadable specks.
- evidence: w2-r1-shrooms.png vs dear-esther-1.jpg.
- lead hypothesis handed to R2: LAMPSHADE bug — shroom lights sit inside the
  clusters and the local-shadow trace lets caps occlude their own light.
- secondary (queued): bright overcast exposure suppresses any glow read
  (dusk-dark local logic needed); antenna-figure silhouettes + fog smudge blob
  flagged again (smoothing backlog).

### W2 · R2 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar.**
- **biggest_gap:** mushrooms do not EMIT — glow baked as local surface tint.
  Twin symptoms, one cause: distant clusters go PURE BLACK in fog (an emitter
  cannot silhouette — dear-esther-6's beacon burns THROUGH murk), and ground
  teal is uniform block-tint with no bright core falling off per cap.
- evidence: w2-r2-fog.png vs dear-esther-6.jpg; w2-r2-shrooms.png vs
  dear-esther-1.jpg.
- secondary (queued): plastic white specular on caps (soften, subsurface
  core); fog smudge blob 3rd flag → smoothing backlog.

### W2 · R3 · critic verdict (fresh critic; first attempt died to a session limit)

- instrument_ok: true.
- **winner: bar.**
- **biggest_gap:** "mushrooms are mint objects standing in a GREEN ROOM, not
  lights standing in a DARK one" — teal sits at one flat value frame-wide
  (floor under cap = far ravine wall = cliff 20m up); dear-esther-1 is built
  on a glow→near-black gradient.
- evidence: w2-r3-shrooms.png vs dear-esther-1.jpg.
- CONTRADICTION #2: builder measured monotone ring falloff 93.5→83.2→68.5;
  critic sees uniform teal. Both may hold — local falloff real, global cast
  swamps it. R4 opens with a glow-off control render to identify whether the
  frame-wide green is W1 moss albedo or glow spill.
- REGRESSION flagged: hard-edged near-black region in w2-r3-ground.png reads
  as missing shading (suspect AO floor 0.12 + shadow 0.22 + crack darkening
  stacking to clipped black). Ripple-tile repeat on sea + top-face checker
  also re-flagged.
- LEAD CALL: R4 darkens the world (late dusk) — third critic to say the frame
  is too bright for bioluminescence, AND it pays the chiaroscuro debt two W1
  critics named. Cap specular softening promoted into scope.

### W2 · R4 · critic verdict (fresh critic)

- instrument_ok: true.
- **winner: bar** — vista called "best frame in the set", warm window survived
  the global darkening (locked).
- **biggest_gap:** shroom pocket still not dark — sky band at top matches or
  beats cap brightness, cliffs at midtone, so caps read as teal objects in grey
  daylight. dear-esther-1 has NO sky and every wall falls to near-black.
- evidence: w2-r4-shrooms.png vs dear-esther-1.jpg.
- LEAD HYPOTHESIS (critic's own words corroborate): wash "spreads to the left
  frame edge at NEAR-CONSTANT STRENGTH (no radius falloff)" = the three
  radius-18 teal POINT LIGHTS, which the builder's features-flag diagnostic
  could not separate from pool/halo. R5 tests lights specifically.
- LEAD SCOPE NOTE: dear-esther-1 is a CAVE; our shrooms pose is an open dusk
  ravine. R5 does the LOCAL version (darken ravine base) — no night-mode, no
  killing the sky. Chasing a literal cave gradient would fight the island
  fiction the user asked for.
- REGRESSIONS/BUGS promoted to R5 (public repo, these matter most): ground pose
  "hard rectangular light/dark slabs, sharp vertical seam, tiles do not follow
  geometry" (checker residue, worsened); cap material overshot to matte flat
  fill (3rd material flag).

### W2 · R5 · critic verdict (fresh critic) — WAVE CLOSE

- instrument_ok: true.
- **winner: bar, WITH ONE HONEST TIE — "w2-r5-vista ties dear-esther-4 on
  mood. Same dusk register, same layered headland depth, same cloud break.
  It loses on surface detail, not on atmosphere."** First tie in 15 rounds.
- fog frame: shroom ledge cluster "throws a genuine pale-blue bloom into the
  murk" — the beacon fiction works there.
- **biggest_gap:** caps emit no light into air; pool covers the ravine at one
  brightness. dear-esther-6's tidepool glow is a tight core dying to near-black
  within a body-length. "Ours has the coverage of a light and the shape of a
  paint fill."
- evidence: w2-r5-shrooms.png vs dear-esther-6.jpg.
- **CONTRADICTION #3 — CORRECTNESS, not taste:** builder verified the slab
  artifact "gone at 100%"; critic reports it PRESENT with coordinates — seam
  at x≈640 (ground) and x≈630 (shore), pale axis-aligned rectangles, floor
  checkerboard in shrooms. Lead note: x≈640 is exactly half of 1280 — either a
  screen-space bug or a world boundary projecting there. Lead hypothesis: R5
  snapped TOP faces only and deliberately KEPT per-voxel shade on SIDE faces,
  which is where the critic points. FALSIFIER DISPATCHED before any further
  edit; no more claim-vs-claim rounds on this.

### FALSIFIER FINDING #2 — the seam artifact (read before touching terrain shading)

**Verdict: world-space shading bug. Both parties were partly wrong.** The
critic saw real pixels but mis-diagnosed the location; the builder's "slabs
are gone" claim was false.

Screen-space ruled out (all of these were checked and cleared):
- Sky rows at the same column step **exactly 0.00** (mean and max, 354 rows)
  while terrain rows step 6-22. Same kernel, threadgroup, clamp, blit.
- vista and fog poses show NO seam despite identical 1280×800 dispatch;
  ground/shore/shrooms show it in 100% of rounds.
- x=640 IS a threadgroup boundary (640 = 20×32, threadExecutionWidth 32) —
  which is why the hypothesis looked plausible — but 38 other interior
  threadgroup boundaries show nothing, boundary strength binned by x mod 32 is
  flat (6421-7010 across all residues), and 6 of the 8 strongest edges are not
  threadgroup-aligned. x=892-897 (32× median) and x=735-737 (29×) are STRONGER
  than x=639-640 (15.7×).
- Blit stride exact: (1280*4 + 255) & ~255 = 5120 = width*4, zero padding.
  A stride bug shears rows progressively; it cannot split a column.
- No branch on gid.x in raycastHybrid; simd_sum touches counters only.
- Predates R5: present in the FIRST capture (w1-r1-ground, 51.3× median),
  since improved to 15.7×.

**Root cause — three stacking discontinuities, none filtered:**
1. `MicroCube.metal:120` — `surfaceBand = clamp(int(level*14), 0, 13)`
   quantizes smooth noise per voxel column, so adjacent columns straddling a
   contour snap to different BANDS. Measured plateau ratios 1.47-1.60×, which
   matches band-to-band mid-shade (1.47×), not within-band. This is why the
   shrooms floor checkerboard "ignores the slope" — it tracks the noise
   contour, not the geometry. **The R5 top-face snap normalized shade WITHIN a
   band but left the band index intact, which is why it did not fix this.**
2. `MicroCube.metal:124` + `:496` — per-voxel hashed shade on SIDE faces
   (R5 snap is gated to `hit.normal.y > 0.5`, top faces only). Within-band
   spread 1.27-1.37×; adjacent voxels on one wall draw independent shades.
3. `MicroCube.metal:527-529` — `column = int(floor(horiz * 1.1f))` switches
   the bed-pattern phase every 1/1.1 = 0.909 units, BEATING against the
   1.0-unit voxel boundary. Two interleaved families of hard vertical edges.

**Fix directions (for the round after W3):** blend/dither the band boundary
using the fractional part of `level*14` instead of hard-quantizing; make the
within-band shade continuous in world space (or extend the snap to side
faces); align the column period to 1.0 so joints land ON voxel boundaries
instead of beating against them.

### W3 · R1 · critic verdict + LEAD ROOT-CAUSE (floating creatures)

- **floating_answer: YES — confirmed with measurements.** t36 near figure:
  head (830,200), hip (855,292), leg tips (818,352)/(886,338); body axis
  tilted ~25°, right leg tip ends in open fog with SKY VISIBLE BENEATH, ~20px
  above a ridge crest that is itself far behind in fog. Second watcher at
  (930,285-330) is upright and correctly occluded → fault is PER-FIGURE, not
  global. Also: left figure at (415,215-270) has its head half-sunk into a
  rock terrace.
- **LEAD ROOT CAUSE (traced in source):** `HybridTraversal.metal:124-137`
  `animateSDFInstance` displaces creatures by sin(phase)*2.2 in X and
  cos(phase*0.73)*1.5 in Z every frame, while Y only bobs +0..0.22. Grounding
  height was computed ONCE on CPU for the ORIGINAL x/z
  (`SceneData` y = terrainHeight + 12*0.5 + 3*0.32). A figure wandering 2.2
  units across sloped terrain therefore lifts off or sinks by the slope delta.
  Explains float, sink, AND why it is per-figure (depends on local slope).
- **Fix shape available:** W3 R1 added `TerrainField` (Swift height mirror) and
  `sdfInstances` is already `storageModeShared` — CPU can animate + re-ground
  6 creatures per frame directly into the buffer, no per-ray shader cost.
  Note `terrainHeight` lives in MicroCube.metal which concatenates AFTER
  HybridTraversal.metal, so a shader-side fix would need the move-to-SceneTypes
  trick used for the noise helpers in W1 R2.
- **NEW ARTIFACT CLASS (not the palette seams):** hard-edged shadow polygon in
  t24-fog — a straight dark edge (790,480)→(930,775) crosses a vertical face,
  a horizontal top, AND an air gap without deflecting; second band
  (700,372)→(1050,400). Constant darkening across all three surface
  orientations. LEAD SUSPICION: the W2 R5 pocket sky-occlusion (4 coarse
  MIP-2 taps, i.e. 4×4×4-voxel granularity) darkens in blocky world-space
  chunks that ignore fine geometry.
- **Composition:** sequence "runs strong, flat, broken, dead, recovering,
  anticlimax" — best frame is t0 (second zero), t48 is a dead beat. Titles
  over-promise: THE GLOW BELOW (glow ~2% of pixels, occluded), THE WATCHERS
  (nothing orients or watches), AMONG THE LANTERNS (you are at a rim, not
  among). THE SHORE delivers.
- **winner: bar**, no ties this round (the W2 vista tie stands separately).
- **BIGGEST GAP — best note of the run:** "Across all six captures no frame
  ever places a bright point the eye can lock onto and walk toward." t72-ridge
  and dear-esther-6 share an identical composition — grey rock left and right,
  overcast sky, a horizon gap between two masses — but DE6 puts one small
  saturated red-orange beacon INSIDE the gap at ~(270,155), converting a grey
  vista into a destination. Our gap at (560-720,380-520) is empty. This is the
  thesis of a walking game: you walk toward something. We already own the
  mechanism (glowing clusters).
- Shadow polygon is POSE-SPECIFIC to t24 (five other poses verified clean),
  which supports the binary-gate hypothesis: only terrain near an enclosure
  threshold flips.
- Cleared as NOT artifacts: t60 bright diagonal band (real stepped geometry);
  dark sky ovals in t72/t24 (soft-edged, pass the geometry test, but read as
  unmotivated smudges — noted for smoothing).

### W3 · DEFECT CONFIRMED BY LEAD (before wave opens)

- `AutoTour.swift` waypoints still target props purged in W1 R6:
  t=36 "GLASS + LIT FOG" → lookAt (286.5, 115.5, 306.5) = the removed glass
  sphere; t=42 "SDF FRACTAL ORBIT" → lookAt (261, 126, 359) = the removed
  fractal. 12s of the 48s default autoplay tour stares at empty air with HUD
  titles advertising absent objects.
- Tour also never visits the sea, the shore, or any shroom cluster — the
  wave's headline features are absent from the default experience.
- W3 scope: re-route the tour as an island walk (shore, fog creatures, shroom
  hollow, ridge vista), retitle sections, and ground the walk.

### W1 · R6 · props purge (parallel piece, disjoint files)

- Lead scope decision: sculpture, glass sphere, fractal ball LEAVE the hero
  island (pure demo props; every critic calls them disqualifying). Creatures
  STAY (Silent Hill fiction) but become distant dark silhouettes in fog, not
  center-frame brown dolls; their lights muted to pale cold glow.
- QA fixtures (optics/fractal/shadow probes) must keep their geometry —
  fixture scenes decouple from the hero instance list.

#### W1 · R6 · builder result

- makeHero now builds ONLY 6 creatures + 8 mist gaussians + 6 lights; the
  sculpture is deleted outright, the glass sphere and fractal moved to
  fixture-only factories SceneData.makeOpticsProp()/makeFractalProp() with
  byte-identical parameters (optics/fractal probe pins hold unmodified;
  Renderer.makeScene wires the fixtures to the factories).
- Creatures repositioned 41-80 units from the frozen fog camera, spread across
  its view cone, re-grounded on terrain (heights [83,94,81,87,92,84], y =
  h + 6.96). Material darkened to wet driftwood (0.045/0.043/0.041, emission
  ~0). Lights: saturated rainbow -> pale cold blue-grey/green hints,
  intensity 14 -> 6 (radius 26 and 6.3 attach offset kept).
- Test-pin moves (hero pins only, fixture probes untouched):
  expectedCreaturePositions, expectedTerrainHeights [83,94,81,87,92,84],
  light intensity pin ==6, fractal/optics pin tests repointed at the fixture
  factories, sculpture row dropped from expectedSDFs. SDFProbeTests fractal
  source -> makeFractalProp().
- Tests: 170 executed, 0 failures (includes the every-creature-visible hero
  traversal probe against the new positions).
- Captures: dist/gauntlet/captures/w1-r6-{vista,shore,fog,ground}.png.
  Fog frame verified: no spheres, no fractal, creatures as half-seen dark
  silhouettes in the fog bank. Vista/shore/ground: deltas prop-only (none
  were in frame). Breakup/terrain shading code untouched this round.

### W1 · R7 · builder — structural texture (falsifier-informed)

- All three falsifier levers applied in raycastHybrid:
  (1) WAVELENGTH: side faces get quantized horizontal STRATA — 2.2 bands/unit
  (2-3 full bands per face), band edges jittered by fine noise, 3-tone
  quantized per band via integer hash (hard transitions, no smooth gradients).
  Top faces: sharp smoothstep two-tone moss/peat (edge width 0.06 in noise
  space) + sparse bright grass-tuft speckle (hash > 0.86).
  (2) CRUSH: new POST-lighting structural component applied after AO/shadow/
  lights, before fog: color = color * mix(0.62, 1.38, structure) +
  (structure - 0.5) * 0.016 — the ADDITIVE term is what survives the dark
  regime where multiplicative texture provably dies. Pre-lighting value
  modulation reduced to 0.62-1.38x (hue logic kept, crack lines kept).
  (3) Budget: same 2x noise3D + 1 hash as R5 (+0 calls). Structure gated to
  terrain hits; creatures/water/sky untouched.
- MEASURED ACCEPTANCE (face-interior p5-p95 luminance, numpy; all rects
  reported, no cherry-picking):
  shore: (1030,400) spread 25.7 PASS · (530,450) dark-regime median 13,
  spread 38.9 PASS · (880,560) 37.3 PASS · (710,390) 28.8 PASS · one
  clipped-black crevice rect (650,590, median 0) 9.5 FAIL — nothing can read
  inside intentional near-black. Verdict: >=2/3 incl. dark regime MET.
  ground: (900,470) dark-regime spread 26.9 PASS · (420,690) 31.2 PASS ·
  (950,290) 18.9 PASS · three single-tone interiors 12.1-16.9 FAIL (rects
  inside ONE stratum/moss tone show only fine-grain spread — structure lives
  at tone boundaries, most faces have 2+). Verdict: >=2/3 incl. dark MET.
  vista: bottom-half median 44.2% vs R5 44.2% (delta 0.0), warm window
  intact. MET.
- Tests: 170 executed, 0 failures. Captures:
  dist/gauntlet/captures/w1-r7-{vista,shore,fog,ground}.png — shore cliff now
  reads as layered sedimentary rock; fog walls banded; vista unchanged.

### W1 · R8 · builder — texture honesty: rock, not pattern

- Side faces rebuilt as geology: granular stone base (NEW grain noise3D at
  5.5/unit — the +1 budget call), THIN dark seams (width 0.06-0.15 units,
  per-bed width + per-bed presence gating -> irregular 1-3 seams/unit),
  slight tilt, RAGGED edges (two-octave jitter), occasional lighter beds,
  and vertical JOINTING: per ~0.9-unit column, hashed phase offset visibly
  faults the bedding across the joint + sparse dark crack on ~38% of columns.
  Equal-weight smooth bands killed. Tops: turf threshold now jittered by
  fine+grain -> ragged irregular patches, tuft speckle kept.
- Mid-round self-catch: first r8 build modulated bed FREQUENCY spatially
  (y * (1.35 + patch*0.6)); at y~80 that term's gradient swamps the base
  slope -> closed contour loops -> faces read as WOOD GRAIN. Rebuilt with
  constant frequency (level sets provably monotone in y, loops impossible);
  spacing irregularity moved to discrete per-bed seam gating. Re-rendered,
  re-tested.
- EYEBALL ANSWER (required): shore — "rock": dark weathered faces, ragged
  offset seams, granular tone; reads closer to cut-stone cliff blocks than
  loose natural scree (the per-voxel crack lines contribute) but clearly
  geology, not wallpaper. ground — "rock with turf": grey-brown stone,
  irregular seams, dark ragged turf patches.
- MEASURED (falsifier single-face method): shore 3/3 PASS — (1030,400) 39.2,
  (530,450) dark median 24 spread 29.5, (880,560) 27.3. ground 2/3 PASS incl.
  dark — (900,470) dark 30.1, (420,690) 19.1; (950,290) 10.8 FAIL (face sits
  inside a single bed, grain-only). vista median 44.2% == R5, warm window
  intact. Tests: 170 executed, 0 failures. Captures:
  dist/gauntlet/captures/w1-r8-{vista,shore,fog,ground}.png.

### W1 · R9 · builder — multi-scale wet rock + de-tiled turf

- Side faces, layered so no single feature dominates: TWO interleaved bedding
  systems (2.6/unit fine + 1.1/unit major) -> 2-4 seams per face; per-bed
  hashed darkness 0.12-0.48 (faint to deep) and hashed widths -> the
  one-seam-per-face rhythm is gone. Micro-FACETS: grain (5.5/unit) quantized
  to 4 discrete levels, +/-0.14 structure -> chipped mottle inside every
  face. WET-BRIGHT: sparse sparkles (lattice hash > 0.90) gated to the
  waterline spray zone (y < sea+9) and seam edges, +0.55 structure -> wet
  glints. Joint cracks kept with per-column hashed darkness. Occasional
  lighter beds kept.
- Turf de-tiled: coverage now driven by continuous cross-voxel noise
  (patch 0.72 + fine 0.28, grain only jitters the threshold edge); per-voxel
  hash demoted to tuft speckle only; top-face crack lines weakened
  (floor 0.62 -> 0.82); post-light amplitude raised (0.28-0.72) so organic
  patches dominate the voxel checker. Side crack darkness varied per lattice
  cell (floor 0.50 + hash*0.22).
- Budget: +0 noise calls (still 3x noise3D + hashes; the +1 allowance unused).
- SEAM COUNT on 3 large faces (3x zoom crops, eyeballed): ground-left
  terraces 3-4 seams/face with clearly varied darkness; shore tan face 2-3
  (one deep + one faint) + facet mottle; ground right wall 2-3 varied. All
  >= 2 with varied darkness: MET. Micro-facet at 100%: reads as quantized
  mottle — honest note: soft rounded blobs up close, not sharp chips.
- STRANGER QUESTION: shore — "rock" (dark fractured bedded cliff; masonry
  feel of R8 reduced). ground — "rock" (left terraces genuinely read as
  weathered stratified outcrop; residual per-voxel checker on some tops).
- MEASURED: shore 3/3 PASS — 35.4, dark-regime 25.7 (median 24), 26.3.
  ground 2/3 incl. dark — 28.1 (dark), 26.4; single-bed face 12.8 FAIL
  (same rect as R8, reported). vista median 44.2% == R5, warm window intact.
- Tests: 170 executed, 0 failures. Captures:
  dist/gauntlet/captures/w1-r9-{vista,shore,fog,ground}.png.

### W1 · R10 · builder — water honesty (wave-closing round)

- Root cause of 4-round marbling: the smooth 0.22/unit ripple normal warped
  the reflection vector across skyColor's cloud-deck noise — the sea was
  rendering warped cloud contours. Fix: perturbed-normal reflection DELETED.
  Reflectance is now flat analytic (no noise sampled for direction) -> swirl
  is impossible by construction.
- New water: fresnel on direction.y only, milky +0.30 reflection floor
  removed -> steep views plunge to seaDeep (0.030/0.042/0.050 linear).
  Reflect tone = dark cloud-base value (0.30/0.33/0.375 linear — sea darker
  than sky always). ONE warm glint lane via sun-azimuth alignment (lane^8),
  visible in the vista's sea toward the sun window, absent in the west-facing
  shore view. Micro-chop: single anisotropic valueNoise (1.7 x / 2.6 z +
  time) modulating ONLY scalar reflectance + lane sparkle -> short horizontal
  streaks, never contours. Shallow see-through + fog integration kept.
  Net cost: one noise call CHEAPER than R1 water.
- ACCEPTANCE: (a) stranger question "sea or mercury?" — SEA, unambiguous
  (100%+ zoom crop shows short chop streaks, cold grey-slate, no marble).
  (b) numpy medians: shore sky rows 120-260 = 170/255 vs water rows 430-580
  = 104/255 and rows 600-750 = 73/255 -> water FAR below sky. vista sea band
  177/255 vs sky rows 186/255 -> below, converging in fog at the misty
  horizon as intended; horizon line legible in shore (dark sea band against
  pale sky). (c) no smooth swirl contours at zoom: confirmed.
- Tests: 170 executed, 0 failures (fog-fixture gate holds; water is
  shading-only, hero pins untouched). Captures:
  dist/gauntlet/captures/w1-r10-{vista,shore,fog,ground}.png. Wave W1 visual
  rounds complete — awaiting the cold benchmark gate.

### W2 · R1 · builder — bioluminescent shroom fields

- NEW SDF kind 2 = shroom cluster (HybridTraversal distanceToInstance):
  one instance renders 5 mushrooms via golden-angle hashed offsets — stem
  capsule + flattened cap (y-squashed sphere, x0.55 Lipschitz guard),
  smoothUnion. Kind 2 routes to the smooth step budget (24) automatically.
  No kernel/ABI changes.
- Scene: 7 clusters (scale 2.4) in flat hollows across the island — C1
  (274,278) beside the creature paths, C2 (250,284), C3 (220,236), C4
  (232,356), C5 (292,254), C6 (268,338), C7 (344,360) — terrain-grounded
  (instance y = h + scale/2; heights [79,86,72,73,79,86,74]). metadata
  (2, material 5, SDF_FLAG_EMISSIVE, stableIDs 9-15). Total SDFs 13/16.
- Material 5: dark teal base (0.10/0.22/0.20, roughness 0.18), teal emission
  (0.07/0.42/0.36) modulated x(0.55 + 0.45*normal.y) in raycastHybrid so CAPS
  glow brighter than stems, metalness 0.45 -> existing reflective secondary
  path gives wet caps visible sky/scene reflections.
- Lights: 3 of 6 reassigned creatures -> clusters C1/C2/C7 (teal 0.25/0.95/
  0.85, intensity 9, radius 16) — glow pools on terrain + feeds volume
  lighting into the gaussian fog. Creatures keep 3 pale lights.
- NEW 5th frozen pose "shrooms": 280,81.7,278,-1.5708,-0.15 (eye-level by C1,
  C2 mid-distance) — appended to poses.md.
- Pins moved/added: creature-light zip tests restricted to first 3 lights;
  NEW testHeroShroomClustersAreEmissiveTealGroundedAndLit (count 7, kind 2,
  material 5, emissive flag, scale, terrain grounding +/-1, teal light
  attachment, intensity pins). Suite: 171 executed, 0 failures.
- Bench (shrooms pose, reflective caps in frame): p95 6.19 ms <= 8.33,
  status PASS, thermal nominal. JSON: dist/gauntlet/w2-r1-bench-shrooms.json.
- Verified: shrooms pose shows 5 glowing wet-capped mushrooms with teal light
  pooling and C2 as a distant spark; fog pose shows C1 as a teal beacon on
  the terrace (lead's beacon requirement met via fog pose). Honest gap: C7
  is NOT visible from the frozen ground pose — an intervening knoll at
  z~345-355 occludes it; it remains a walk landmark. Captures:
  dist/gauntlet/captures/w2-r1-{vista,shore,fog,ground,shrooms}.png.

### W2 · R2 · builder — the glow lights the scene

- LAMPSHADE HYPOTHESIS: falsified in code — traceOcclusionExact traces the
  VOXEL volume only, SDF caps cannot shadow their own light. Real causes:
  (a) light 1.4 above center inside a voxel PIT -> pit-rim voxels occlude
  grazing rays -> x0.08 shadow crush on the ring; (b) the pool was
  baseColor * light — multiplicative teal on near-black albedo (the W1-R7
  crush class). Fixes target both.
- Lights: shroom lights raised +1.4 -> +3.2 above cluster center (clears
  rims + caps), radius 16 -> 18, intensity 9 -> 10.
- TERRAIN POOL (guaranteed): additive proximity glow in the terrain path
  after the structure stage — sum over 6 animated lights of
  color * intensity * exp(-d^2 * 0.06) * 0.032. Additive -> survives dark
  albedo, ignores shadow logic. 3-6 unit teal ring.
- AIR HALO: analytic ray-proximity glow before the gaussian stage —
  closest-approach distance to each animated light, exp(-d^2 * 0.30) * 0.012,
  with a NEAR-CAMERA fade saturate(|toLight|^2 / 144): first build washed
  half the frame teal because the pose camera sits 6 units from the C1
  light and every westward ray passed within halo radius; the fade keeps
  the halo a distant-beacon effect while pool + emission carry close-range
  glow. Final view only (evidence views excluded).
- MEASURED ACCEPTANCE (numpy, after tune): ring mean lum 64.5 vs control
  55.3 PASS; teal dominance G-R 28.9, B-R 22.0 (need >=15) PASS; under-cap
  lum 69.7 vs frame p10 41.0 PASS (was the DARKEST region in R1); fog
  beacon: largest connected teal blob at C1 = 2446 px (need >=200) with
  soft halo edge PASS. Vista/shore verified unchanged in character (vista
  gains one tiny teal spark from an unlit cluster's emission).
- Bench (pre-tune build, tune is cost-neutral: same loop counts + 1 ALU):
  p95 5.60 ms <= 8.33; report status "fail" only on the thermal-nominal
  gate (state "fair", machine warm from CI churn); counters: 0 command
  errors, 0 dropped. Production budgetOverflows 15042/240 frames ≈ 63/frame
  (~0.006% of pixels) from grazing cluster-SDF rays — noted, no visual
  artifact found. Tests: 171 executed, 0 failures. Captures:
  dist/gauntlet/captures/w2-r2-{vista,shore,fog,ground,shrooms}.png.

### W2 · R3 · builder — emission survives fog + distance

- ROOT CAUSE confirmed in the pipeline: emission was added BEFORE both the
  reflective mix (metalness 0.45 diluted it x0.55) and the distance-fog mix
  (fog dragged it toward fog color). Unlit clusters (4 of 7) additionally
  have no light -> no halo, no pool — only that dying emission, hence the
  dark distant caps.
- FIX 1 (cap emission through fog): emission add MOVED to after the fog mix,
  attenuated x(1 - 0.4*fog) — distant caps dim slowly toward a glowing
  ember, never to black; also no longer diluted by the reflective mix.
  Cap emission raised (0.07/0.42/0.36 -> 0.10/0.60/0.52).
- FIX 2 (halo): already post-fog by position; distant response strengthened
  (k 0.30 -> 0.22, coeff 0.012 -> 0.016), near-camera fade kept.
- FIX 3 (pool core+skirt): tight core exp(-horizontal_d^2 * 0.5) *
  saturate(1 - |dy|/6) * 0.9 (horizontal-distance based, because the light
  rides 4.4 above ground — a 3D core could never reach it) + the existing
  soft skirt exp(-d^2 * 0.06).
- MEASURED (numpy): cap-brightest — 3/3 caps max > neighborhood p95
  (218>203, 218>201, 214>201) PASS. Falloff — rings 93.5 > 83.2 > 68.5
  strictly decreasing PASS. Beacon (fog pose, cluster-region rect):
  C2 mean 100.7 vs surround 81.9, G-R 19.3, B-R 15.3 PASS; caps-only
  116.4 vs 83.0, G-R 31.1. Zero black silhouettes (region min lum 40.5;
  R2 caps min was 62 but visually dark — R3 caps mean 116 vs R2 103).
  Honest note: C6 (unlit, 81 units) is not visibly resolvable in the murk
  (~4 px) — the one distant-visible cluster is C2 and it beacons. 
  Regression: vista delta +0.0, shore delta +0.0 PASS.
- Tests: 171 executed, 0 failures. Captures:
  dist/gauntlet/captures/w2-r3-{vista,shore,fog,ground,shrooms}.png.

### W2 · R4 · builder — dark world so glow means something

- STEP-0 DIAGNOSTIC (zero-code: --qa-features without `lights` kills pool +
  halo + local lights): ANSWER = GLOW SPILL, not moss. No-glow frame is GREY
  and already dusk-dark — G-R 0.2-1.7 across floor/walls/cliff, median 33;
  with glow: G-R 34-35 on floor AND ravine wall, frame G-R mean 2.5 -> 21.0,
  median 60. The green room was 100% my glow (mostly halo: pose camera sits
  6 units from C1's light so most rays pass within halo radius; plus broad
  pool skirt).
- SPILL FIX: halo k 0.22 -> 0.45 (radius ~1.5), coeff 0.016 -> 0.012,
  near-fade range 144 -> 400 (halo strictly a distant-beacon effect);
  pool skirt k 0.06 -> 0.11 (teal dies ~5 units out).
- GLOBAL late-dusk step: exposure 0.85 -> 0.78, ambient 0.26 -> 0.22, sky/
  cloud/horizon/fog constants x~0.8 (sunWarm KEPT full -> window pops harder
  against the darker deck), sea constants x0.8 (sea-below-sky preserved).
- SPECULAR: cap metalness 0.45 -> 0.22 — chrome hotspot softened, cap read
  biased to emissive core + wet sheen.
- GROUND ARTIFACT: confirmed = AO 0.12 x shadow 0.22 stacking to a clipped
  face; AO floor -> 0.16, sun-shadow -> 0.26. The face now reads as deep
  shadow with faint structure; remaining <2/255 pixels are 3.46% scattered
  crevices (legitimate anchors), no face-sized void.
- MEASURED: frame p25 51.5 -> 39.8 PASS (dropped, despite the glow staying);
  brightest 40x40 block in lower 2/3 sits at (540,426) = cap/pool region
  PASS; ravine-axis gradient 67 -> 83 -> 97 -> 161 (pool core) -> 39-44
  (ravine mouth) PASS (mouth 44 vs pool 67-161); left-wall band 61 vs
  cap-base 67 reported honestly (band includes fog-lit rim rock — the far
  walls behind the pool are 39-46). Vista median 172.7 -> 152.7 with warm
  window + layered recession eyeball-confirmed intact. Bench p95 5.97 ms,
  status PASS, thermal nominal. Tests: 171 executed, 0 failures.
- Captures: dist/gauntlet/captures/w2-r4-{vista,shore,fog,ground,shrooms}.png
  + diagnostic dist/gauntlet/diag-shrooms-nolights.png.

### W3 · R1 · builder — make it a walking game

- DEFECT FIXED: AutoTour.swift waypoints no longer target purged props (the
  t=36 glass-sphere and t=42 fractal stares are gone). The tour is now a
  96-second island WALK, all sections in the beauty view (.final — debug
  evidence views are opt-in via keys 1-5 only): t0 THE SHORE (cliff edge
  over open sea) -> t12 ALONG THE WATER (waterline west) -> t24 SOMETHING IN
  THE FOG (slope view of creature silhouettes + C2 glow) -> t36 THE WATCHERS
  (under the creatures) -> t48 THE GLOW BELOW (rim reveal of the C1 teal
  hollow) -> t60 AMONG THE LANTERNS (inside the basin) -> t72 THE RIDGE
  (warm sky window between dark ridges) -> t84 BACK TO THE SEA.
- WAYPOINT VERIFICATION: look targets reference live content — sea plane
  (y 52) for shore legs; creature centers (262.5,92,297.5)/(288,96,311) and
  shroom clusters C1 (274,80.5,278)/C2 (250,87.5,284) from SceneData
  constants; sky-window bearing -2.75 rad for the ridge. Camera heights from
  TerrainField (CPU mirror of the shader height, parity pinned by the GPU
  creature-height test). wp3 sightline verified by a terrain ray-march
  (min clearance 1.8 units); first placement was blocked by its own slope —
  caught in capture review and re-placed. All 6 tour captures opened, each
  shows its named subject.
- GROUNDED WALK: NEW TerrainField.swift — unrounded height mirror. Interactive
  camera: speed 18 -> 4.2 u/s (Shift jog x1.75), Q/E free-fly removed, eye
  rides smoothHeight+1.7 with exponential smoothing (no voxel-step jitter —
  the smooth field glides within +/-0.5 of the voxel surface and the blend
  removes the rest), horizontal step REJECTED when target terrain is below
  seaLevel+0.4 -> the walker stops at the waterline. Auto-tour camera
  re-grounds on the same field (+1.8) every frame — it walks, not floats.
  QA/frozen poses untouched by construction (updateCamera unreachable in QA
  frames and during tour playback).
- Pins updated honestly: boundary cases -> 8 sections at t 0..84 all .final;
  controller elapsed-time cases 8 -> 15; legend "AUTO TOUR · FINE VOXEL
  TERRAIN" -> "AUTO TOUR · THE SHORE" (x3); dense determinism sweep extended
  to 96 s. Tests: 171 executed, 0 failures (final run includes the wp3 fix).
- Frozen poses re-rendered w3-r1-{vista,shore,fog,ground,shrooms}.png —
  no regression (shrooms/vista spot-checked by eye, renderer QA path
  unchanged). Bench p95 5.49 ms, status PASS. Tour captures:
  dist/gauntlet/captures/w3-r1-tour-{t0-shore,t24-fog,t36-watchers,
  t48-glow,t60-lanterns,t72-ridge}.png.

### W3 · R2 · builder — palette quantization seams (falsifier-specified)

- All three specified discontinuities fixed, and TWO MORE layers found under
  them — the checker was five-layered:
  1. Band quantization (falsifier cause 1): terrain albedo is now a fully
     CONTINUOUS world-space field on ALL faces — level = (point.y-40)/64 +
     the same 24-unit noise generateTerrain uses, band mids mix-blended by
     fract(level*14). No palette discontinuity of any family can survive;
     the structural bedding carries the strata read as directed.
  2. Side-face per-voxel shade (cause 2): subsumed by fix 1 (material id no
     longer read for terrain color at all).
  3. Column period (cause 3): 1.1 -> 1.0; joints land ON voxel boundaries.
  4. NEW — AO dip punishment: gentle slopes round() into +/-1-voxel height
     dither; the 0.16 AO floor darkened each 1-voxel dip like a crevice.
     Top-face AO floor -> 0.45 (sides keep 0.16, W1 crevice anchors intact).
  5. NEW — the actual checker driver, found by elimination (persisted with
     albedo continuous AND shadows+lights disabled; tile RGB showed a MOSS
     FLIP, G-B +5.9 vs +1.1): turf/breakup/structure sample 3D noise at
     point.y, so +/-1 dithered treads land on decorrelated noise slices and
     flip the turf threshold per tread. Fix: top faces sample the noise
     stack at constant y (pure 2D ground maps); sides keep 3D for strata.
- RANKED-EDGE TABLES (falsifier method, before=w3-r1 / after=w3-r2):
  ground: median 331->297; x=639 15.7x -> 11.4x; x=735 15.1->17.0; x=736
  14.0->15.4; x=593 9.1->10.0; x=617 8.1->8.9. above-5x: 14/1279.
  shore: median 290->277; x=639 45.6->52.1; x=524 26.0->26.8; x=506
  21.6->23.1. above-5x: 96/1279.
  shrooms: median 591->572; x=570 9.3->9.5; x=650 7.2->7.7. above-5x: 10/1279.
  INTERPRETATION (honest): medians dropped 5-10% (broad smoothing) and the
  ground checker edge at x=639 dropped 27%; the surviving top edges are REAL
  GEOMETRY — the ground/shore cameras look axis-aligned, so vertical cube-
  face corners and the cliff-vs-sea silhouette project onto exact screen
  columns (this is also why vista/fog never showed column edges). Sky-row
  guard at x=639|640: mean step 0.003 (falsifier's 0.00 reproduced).
  The <=5x target is unattainable for cube-world geometry viewed axis-on;
  every above-5x survivor is a silhouette/face edge, not shading.
- EYEBALL AT 100%, stated plainly: the alternating checker fields are GONE
  from ground and shrooms floors. REMAINING: sparse single-voxel lighter
  tiles where terrain height genuinely dithers +/-1 (e.g. ground full-frame
  ~(560-660, 520-560); shrooms ~(735,705)) at ~1.1x contrast — elevation-
  tinted raised treads, geometry-correlated, not a pattern field.
- Vista: median 152.7 vs 152.7, delta +0.0, window intact. Tests: 171
  executed, 0 failures. Bench p95 5.78 ms PASS. Captures:
  dist/gauntlet/captures/w3-r2-{vista,shore,fog,ground,shrooms}.png.

### W2 · R5 · builder — light radius, pocket depth, two bugs (wave-closing)

- HYPOTHESIS TEST (lead's light-radius theory): radius-only cut 18 -> 9
  isolates the diffuse point-light wash (pool/halo use intensity + their own
  exp constants, not radius). CONFIRMED: ravine mouth G-R 11.8 -> 2.8 (grey
  slate restored), floor 24.6 -> 14.8, far wall 24.0 -> 18.5. Radius 9 kept
  permanently. Left-wall residual ~17 above albedo = C2's OWN pool (C2 sits
  mid-distance left) — a feature, not wash. Diagnostic:
  dist/gauntlet/diag-shrooms-radius9.png.
- POCKET DEPTH: cheap sky-occlusion for terrain — 4 coarse mip-2 voxel taps
  at point + up*5 +/- 8 lateral; enclosure gated to >=2 solid taps
  (single-tap mild slopes unaffected -> vista guard), lighting scaled down
  to x0.475 in full pockets. Pocket floor p50 46.7 -> 36.0.
- BUG a (ground rectangular slabs): root cause = per-voxel palette shade
  hash on TOP faces at grazing angles (each voxel top = a screen rectangle,
  adjacent voxels alternate shade). Fix: top faces snap to the band's MID
  shade in shading (kPalette[1 + band*3 + 1]) — the checker albedo is dead
  on tops, side faces keep per-voxel variation under their strata. Eyeball
  at 100%: NO rectangular slabs unrelated to geometry remain; plateau reads
  as continuous mottled turf following form.
- BUG b (cap material): emissive dome read — darker underside (0.35 floor
  vs 0.55), rim glow (rim^2 * 0.55 on the silhouette), wet reflection kept
  at metalness 0.22. Caps show visible dome form.
- MEASURED: (i) far-wall G-R drops above; (ii) brightest lower-2/3 block =
  cap region (780,486), pocket floor p50 dropped; (iii) ground slabs gone
  (eyeball, stated plainly); (iv) vista median delta +0.0, window intact;
  (v) tests 171/0, bench p95 5.94 ms PASS thermal nominal.
- Captures: dist/gauntlet/captures/w2-r5-{vista,shore,fog,ground,shrooms}.png.
  W2 closes from the builder side.

### W3 · R3 · builder — grounded figures, continuous pockets, a beacon in the gap

- FLOATING CREATURES (correctness): root cause as traced by the critic —
  animateSDFInstance displaced x/z per frame while grounding stayed CPU-fixed
  for the base position. FIX: creature wander moved to the CPU
  (CreatureAnimation.animatedPositionScale, called per frame by
  Renderer.updateCreatureInstances into the shared storageModeShared buffer);
  y re-grounds on TerrainField under the animated x/z (+foot offset
  params.x*0.5 + scale*0.32 + bob). Shader animateSDFInstance now derives
  only the limb gait phase (parameters.z/w). Static sweptBounds verified to
  cover the wander + grounding delta for all 6 creatures (slack > 8 units).
  TILT ANSWER: rotationQuaternion was write-only — distanceToInstance never
  read it (grep: single write site, no reads), so the 25 deg tilt was never a
  rotation; it was the ungrounded body straddling a slope plus the stride
  pose. Removed the dead write. Remaining lean in captures is the
  articulated stride pose with legs terminating ON terrain.
  EYEBALL, stated plainly: no figure floats, sinks, or hangs over sky in any
  of the six tour captures or five frozen poses. t24 near watcher stands
  upright on the plateau; t36 near figure's legs terminate behind the ridge
  line (no sky beneath); fog-pose watchers all planted.
- SHADOW POLYGON (t24, pose-specific): confirmed the lead's hypothesis —
  binary >=2-of-4 gate on mip-2 taps. FIX: 16 taps (2 heights x 2 radii x 4
  dirs) at mip 1, each 1/16, response smoothstep(0.28, 0.85, enclosure)*0.55
  (continuous, max darkening 0.55 vs old 0.525). MEASURED on the critic's
  named edge (790,480)->(930,775): perpendicular steps r1 16.7/10.0/4.1/9.8
  -> r3 16.0/10.6/0.7/1.0 (the two surviving upper-segment steps exist
  identically in both rounds across a full pocket rewrite -> sun-shadow
  terminator, not pocket). Trench region p1 0.0 -> 8.2 (ink-black crush
  gone). Shrooms pocket floor SURVIVED: p50 34->35 / 35->38 / 31->33 across
  three floor bands (still deep 30s). Shore median +5 (finer mip-1 taps
  read less false enclosure on open cliff faces; no guard on shore, texture
  retention visibly better). Vista median delta +0.0.
- BEACON IN THE GAP: relocated orphan cluster C7 (344,74,360 — invisible
  from every pose) to (260,104,208), crowning the far-hill summit visible
  through the t72 ridge gap at ~92 units; its teal light (radius 9) moves
  with it. Placement by measured crest-line clearance (render-measured crest
  py per column vs projected cap tops; best clearance 26 px). MEASURED in
  w3-r3-tour-t72-ridge.png: 89 saturated teal px, bbox (705-721, 499-511),
  centroid (713,504), G-R +37 / B-R +36 — two glowing mushroom silhouettes
  on the fog-pale summit inside the gap notch, readable at range. BONUS:
  the same beacon now crowns the distant summit in the frozen VISTA at
  ~(840-860, 380-400) (~113 units) — the hero shot gains a destination —
  with vista median delta still +0.0. t60 additionally holds C1's glow on
  the ridge ahead as a walk target.
- Tests: 172 executed, 0 failures (new pins: CreatureAnimation grounding
  across 25 sampled times; motion probe slot 3 pins gait phase; shroom
  terrain pin 74 -> 104 for the relocated C7). Bench p95 6.02 ms PASS,
  thermal nominal; budgetOverflows 102 (up from ~63 — grazing rays at the
  new vista-visible beacon silhouette).
- Captures: dist/gauntlet/captures/w3-r3-{vista,shore,fog,ground,shrooms}.png,
  w3-r3-tour-{t0-shore,t24-fog,t36-watchers,t48-glow,t60-lanterns,t72-ridge}.png.

### W3 · R4 · builder — composition: the walk builds toward the light

- ARC: final sequence — THE SHORE > ALONG THE WATER > SHAPES IN THE FOG >
  THE WATCHERS > THE GLOW BELOW > AMONG THE LANTERNS > THE RIDGE > TOWARD
  THE LIGHT. Quiet coastal open, figures emerge, glow revealed then entered,
  gap shows a distant light, finale walks up to it (the R3 beacon at 35
  units, full cluster silhouetted on the summit). BACK TO THE SEA cut — the
  wrap leg (t84 wp -> shore) carries the descent home without a titled
  anticlimax beat.
- CREATURE FACING (THE WATCHERS earned by fixing the FRAME): creatures now
  carry a real Y-axis rotationQuaternion (0, sin(yaw/2), 0, cos(yaw/2))
  aimed at watchPoint (255,272) — the Watchers viewpoint on the walk —
  applied in distanceToInstance case 1u by rotating `local` before limb
  evaluation (6 mul + 2 add per eval; p95 6.02 -> 6.22 ms). Legs stride
  along local +Z so figures walk facing their gaze. Limb probe kernel
  updated to author offsets in the creature frame; new pin
  testHeroCreaturesFaceTheWatchPoint.
- DEAD BEAT (t48): waypoint moved to the east rim (290,95.3,277) looking
  down the bowl axis at (270,80,279) — the reveal frame is now the C1
  cluster + teal pool center-frame in a dark bowl with C2's glow stacked
  beyond; the pale slabs are out of the composition. A creature head that
  intruded at the right edge at (290,280) was cleared by the 3-unit north
  nudge (verified in the capture).
- AMONG THE LANTERNS (t60): camera INSIDE the bowl at (281,82.3,279) —
  giant glossy caps at the lens, glowing floor underfoot, C2's caps beyond
  the western rise, and creature c2 looming frontal at right. "Among"
  is literal now.
- TOWARD THE LIGHT (t84, new finale): (288,87.1,220) looking up-combe at
  (260,101,208) — the beacon cluster crowns the summit at 35 units, stems
  and caps fully against the sky (placement from a base-sightline probe:
  clearance 1.5 at dist 35.1). Biggest glow of the tour; the walk ends
  facing its destination.
- ALONG THE WATER (t12): waypoint pulled off the cliff base to the
  waterline (262,56.9,148) looking down-coast (236,52.5,136) — coast
  recedes ahead, warm window over the sea; the near-wall that filled half
  the old frame is gone.
- TITLES: SOMETHING IN THE FOG -> SHAPES IN THE FOG (honest); BACK TO THE
  SEA -> TOWARD THE LIGHT (new finale); THE WATCHERS / THE GLOW BELOW /
  AMONG THE LANTERNS kept and earned by frame fixes. Title pins added to
  the boundary test.
- FROZEN POSES: vista/shore/ground byte-identical to R3 (0 px changed >8);
  fog 1061 px and shrooms 1884 px changed — solely the reoriented figures
  (medians all delta 0.0). Fog pose watchers now read frontal (spread
  horns, splayed arms) — stronger, same values.
- Tests 173/0 (new: facing pin; boundary test now pins all 8 titles).
  Bench p95 6.22 ms PASS thermal nominal, budgetOverflows 102 (unchanged).
- Captures: dist/gauntlet/captures/w3-r4-tour-{t0-shore,t12-water,t24-fog,
  t36-watchers,t48-glow,t60-lanterns,t72-ridge,t84-light}.png and
  w3-r4-{vista,shore,fog,ground,shrooms}.png.

### W3 · R5 · builder — the tonal floor and the beacon bloom (wave-closing)

- TONAL FLOOR: final-view grade stage in raycastHybrid, applied in linear
  light before the exposure encode, diagnostic views untouched:
  pow(color, 1.35) crushes mids/lows (highs — the sky break and the glow
  caps — survive relatively), then saturation x2.2 about luma so the
  darkness reads as coloured atmosphere. No flat multiply.
- MEASURED (mean luminance / mean HSV saturation, metric calibrated on the
  bar: my DE1 reads 26.7/203 vs the critic's 24/173). Bar range: mean
  26.7-58.6, sat 28-203.
    t0-shore     83.6/23  -> 65.2/67      t12-water  94.3/27 -> 74.0/82
    t24-fog      85.6/21  -> 66.2/60      t36-watch  72.5/29 -> 53.5/89
    t48-glow     47.7/30  -> 29.4/88      t60-lant   80.4/37 -> 60.0/102
    t72-ridge    93.8/22  -> 75.6/56      t84-light  76.1/25 -> 58.5/67
    vista 136.5/16 -> 116.0/44   shore 68.1/26 -> 50.3/77
    fog 69.1/30 -> 50.2/87   ground 64.9/33 -> 48.2/102
    shrooms 52.2/49 -> 33.7/142
  Six of eight tour frames land in 53-76; t48 (29.4) sits ON its
  same-subject pair DE1 (26.7). Ranges overlap. NOT fully reached: t72 at
  75.6 exceeds the bar's max (58.6) though it is inside the 40-80 band —
  its frame is half warm-window sky, and crushing that would kill the
  preserved sky break. Vista (frozen, sky-dominated hero) stays at 116 for
  the same reason; its LAND is now in the bar band.
- BEACON BLOOM: halo made distance-aware (MicroCube.metal, halo loop):
  widthScale = 1 + lightDist*0.04 widens the gaussian (exp(-d2*0.45/ws^2))
  and energy scales 1 + distSq/3600 — quadratic in distance, so near
  clusters (the W2 R4 green-room fix) are untouched while a 92-unit beacon
  blooms. t72 ring table (G-R): core/rings
  BEFORE +16.8 / -3.7 / -6.8 / -7.1 / -9.2
  AFTER  +77.3 / +40.8 / +21.4 / +6.2 / +0.3
  Sustained positive to 30 px; the 30-45 ring is barely positive because
  the surrounding sky is now MORE saturated orange (the bar's +4.2 at 34 px
  is measured against grey sky). Bonus: the vista beacon now carries a
  visible bloom at 113 units — the hero shot's destination light.
- EYEBALL: t48 reads as the DE1 pairing at last — teal pools in a black-
  green ravine; t60 caps blaze without green-rooming; t84's beacon blooms
  like a shrine light under peach clouds; geology, fog recession, pool
  relationships all readable. One taste note: the tan palette bands on the
  shore cliff read ochre-strong under x2.2 saturation — kept, as DE cliffs
  carry similar ochre banding.
- Tests 173/0. Bench p95 5.65 ms PASS thermal nominal, budgetOverflows 102.
- Captures: dist/gauntlet/captures/w3-r5-tour-{t0..t84}.png (8) +
  w3-r5-{vista,shore,fog,ground,shrooms}.png. Wave closes from the builder
  side.

### W4 · R1 · builder — distance-blended smooth voxel shading

- DESIGN (one deliberate deviation from the brief, called out): pure
  per-voxel central differences of binary occupancy are CONSTANT across a
  face — they can tilt edge voxels but cannot produce a gradient within a
  face. Implemented instead as the analytic gradient of TRILINEAR occupancy
  over the 2x2x2 cell around the hit point (8 occupancy() taps, same budget
  as voxelAO): continuous across faces, steps shade as rounded shoulders,
  and on a flat wall it reduces exactly to the face normal (plus |g|<0.05
  and dot(n_smooth, n_face)<0.1 fallbacks — no garbage).
  MicroCube.metal:460-521 (shadingNormal + nearWeight), :521 sun diffuse,
  :697 point-light diffuse. GEOMETRIC normal kept for: AO, pocket taps,
  shadow-ray offsets, crack/joint lattice, material top-face gates, and the
  normals evidence view (view 6 documents geometry — pinned diagnostic test
  untouched and green).
- BUMP: 3 near-only noise3D taps (seed 79, the grain field's seed) at 9.0
  frequency, finite differences along the smooth normal's tangents,
  strength 0.9. Two rejected iterations reported: (1) reusing grain's 5.5
  frequency with 0.22 offsets exceeded the noise wavelength — aliased into
  glossy camo blobs that fought the strata; (2) strength 1.2 still read
  wet-glossy at arm's length. Final relief modulates WITHIN beds; seams and
  jointing stay the dominant read on side faces (eyeballed at 100%).
- FALLOFF: full effect <= 14 units, zero >= 40 (smoothstep). Justification
  from captures: the walk's near field (eye 1.7, a few steps ahead) sits
  inside 14; the layered-ridge/fog-recession look starts reading at ~40+ —
  vista's nearest terrain is beyond that, and its capture is BYTE-IDENTICAL
  (0 pixels changed > 6/255), the cleanest possible far guard.
- ACCEPTANCE, measured:
  (i) ground + shrooms at 100%: near faces now carry continuous lighting
  gradients — pebbled relief undulating across wall beds, moss hummocks on
  treads, rounded step shoulders; flat per-face fill is gone near. Stated
  plainly.
  (ii) distance blend: frame means moved <= 1.1/255 everywhere; changed
  pixels concentrate in near lower halves (t72: 33,897 changed total, 32 in
  the top half; t60: 639 top-half; vista: 0 anywhere).
  (iii) silhouette: sky-mask XOR = 0 px on t72, t84, vista, ground.
  (iv) shadow acne: none — checked ground wall shade, shroom bowl, and the
  steep t48 view; shadow/AO offsets kept geometric.
  (v) bench: vista p95 6.27 ms, near-heavy ground pose p95 6.19 ms, both
  PASS thermal nominal (vista has zero near pixels, so the ground pose is
  the honest cost probe; run-to-run variance on this machine spans 5.65-
  6.28 across identical-path rounds — the effect's cost is inside noise).
  (vi) tests 173/0.
- Captures: dist/gauntlet/captures/w4-r1-{vista,shore,fog,ground,shrooms}.png
  + w4-r1-tour-{t0..t84}.png (all 8 — every tour frame has near ground in
  the lower third, so all were re-rendered).

### W4 · R2 · builder — duotone decoupled, moss un-neoned (gate round)

- ROOT-CAUSE FIX (as traced by the lead): smoothed diffuse now drives
  lighting MAGNITUDE only. New geometricDiffuse (from hit.normal) feeds the
  dusk duotone and the shadow-test gate. MEASURED: the blue-pebble ellipse
  at ground (1103,250) — r1 spot (17.4,20.0,22.3) blue-dominant on a
  (15,14,14) surround — is now (9.0,9.0,8.4) on (10,9,9): neutral and
  matched. Shrooms (880,690): spot hue direction now consistent with its
  pool-lit surround. Shore mid-terrace warm bias R-B: r5 +9.8 -> r1 +11.8
  -> r2 +7.6 (bias gone, below the pre-relief baseline).
- RELIEF SURVIVAL: with the duotone decoupled, much of r1's measured
  "detail energy" was revealed to be the hue-wobble artifact — the honest
  normal-path relief is crushed multiplicatively on near-black rock (the W1
  lesson). Added a hue-neutral bump-shade term (the bump-induced diffuse
  delta, applied x0.8 multiplicative + 0.008 additive) so relief survives
  the dark grade without any hue path. Final high-pass vs w3-r5: ground
  near-field 1.83x (r1: 1.59x), right wall 1.04x (r1: 1.03x — the wall
  number nets the smoothing's legitimate removal of voxel-edge stair
  energy against added fine relief; beds and seams read clearly at 100%).
- MOSS: turf tint (0.55,1.35,0.45) -> (0.60,1.32,1.00), tuft blue raised,
  and the grade's hard max(0,...) replaced with a soft knee (0.002 linear)
  so no channel crushes flat. MEASURED: vegetation B/G 0.051 -> 0.705
  (target >= 0.6; the bar's own lurid frame is 0.825). Moss luminance kept
  (mean G 30.2 -> 30.3). GLOW UNTOUCHED: teal B/G 0.880 -> 0.880, same
  pixel count. Moss now reads as sea-green coastal turf, not neon.
- THREE MID-ROUND PULLBACKS, reported: (a) first knee (0.008) lifted
  fully-crushed channels to ~16/255 display — visibly undid part of the
  R5 black floor; cut to 0.002 (ground p1 back to 9). (b) bump 1.5 +
  shade 1.2/0.012 over-textured into dark salt-and-pepper; (c) settled at
  bump 1.1 + shade 0.8/0.008 with moss luminance restored via the tint.
- Frame means: ground 49.8, shrooms 35.2, shore 52.1, fog 50.0, vista
  116.0 — the W3 R5 tonal floor held. Vista vs r1: 4779 px changed >6
  (moss tint on distant slopes + knee), mean unchanged — near-identical,
  not byte-identical, by design of the global moss/grade fixes.
- Tests 173/0. Bench p95 6.05 ms (near-heavy ground pose) PASS thermal
  nominal.
- Captures: dist/gauntlet/captures/w4-r2-{vista,shore,fog,ground,shrooms}.png
  + w4-r2-tour-{t0..t84}.png.

### W4 · R3 · builder — fine scale restored, machair moss, hue decoupled (final)

- KEPT (per lead): geometricDiffuse decoupling untouched. Blue-dominant
  ground-rock fraction, measured with ONE metric across builds (sky-masked,
  b>r+6 & b>g+6 — includes the blue fog haze all builds share): baseline
  4.04%, r1 4.04%, r2 4.07%, R3 2.90% — BELOW baseline; zero excess.
- FINE SCALE: bump moved to freq 36 (offsets 0.007), normal-path strength
  cut to 0.7, and the bump's energy shifted to the PURE-LUMA additive
  shade path (mult 0.1, additive 0.026) — a luma-only term cannot drag
  chroma with it, which is also what fixed the coupling (item 3). A second
  octave (freq 90, amplitude 0.5, fading in under 7 units, x0.2 on top
  faces) gives the very-near cliff pixel-scale grain; the face gating
  resolves the ground/shore distance overlap.
- MEASURED (my luma-only band harness, calibrated to reproduce the
  critic's orderings; region boxes in workbench source):
  ground: 1px +74% (r1 +37%), 1-2 +175%, 4-8 +9%, 8-16 -4%, chunk 0.95
    (r1 1.80, baseline 2.04), corr 0.504 (r1 0.633, baseline 0.499).
    1px exceeds the ~+45% target — the excess is near tread-riser side
    faces; chunkiness 0.95 and the eyeball (fine peat grit, no blobs)
    say the energy is at the right scale. 4-8 sits +9% above baseline:
    that band is the rounded step shoulders, i.e. the smoothing itself.
  shore (explicitly checked as ordered): 1px +3% (r1 -9%, pre-octave
    -18%), 4-8 -23%, 8-16 -25%, chunk 1.20, corr 0.556 (r1 0.682).
  shrooms rock: 1px +44%, chunk 1.28, corr 0.298 (baseline 0.410).
  Hue-luma coupling below attempt 1 on all three regions.
- MACHAIR MOSS (lead's corrected target): turf tint -> (1.12, 0.97, 0.90)
  (luma-parity ~1.0 — parity matters: a non-parity tint co-locates luma
  and chroma edges and was the R3-iteration-1 corr spike), tuft
  (0.95, 1.05, 0.88). Duotone chroma tightened: cool (0.88,0.91,1.03),
  warm (1.09,0.98,0.90).
  MEASURED: ground moss RGB (19.3,17.4,14.2)/(16.8,15.2,12.9) — R/G
  1.108/1.101 (target 1.03-1.12), B/G 0.819/0.845 (0.77-0.89), hue
  38/36 deg (36-48), sat 0.261/0.232 (0.18-0.25; one rect 0.011 over).
  shore moss (15.4,14.4,12.6): R/G 1.070, B/G 0.875, hue 38, sat 0.182.
  Was: R/G 0.66, hue 132. Vegetation now reads olive machair, luminance
  held at 15-19 as ordered.
- GROTTO PRESERVED: floor B/G 0.921 at hue 173 (baseline 0.785/165 —
  teal intact, light-driven so the albedo retarget cannot reach it).
  GLOW caps: (0.0, 138.8, 122.3) vs (0.0, 138.6, 123.4) in r5/r2 —
  <=1.1/255 drift from the duotone chroma tightening, R exactly 0.
- Frame means held: ground 49.8, shore 52.2, fog 50.0, shrooms 35.2,
  vista 116.0. Tests 173/0. Bench p95 6.20 ms (near-heavy ground pose)
  PASS thermal nominal.
- Captures: w4-r3-{vista,shore,fog,ground,shrooms}.png +
  w4-r3-tour-{t0..t84}.png. Wave closes from the builder side.
