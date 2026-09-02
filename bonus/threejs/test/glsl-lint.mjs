#!/usr/bin/env node
//
// glsl-lint.mjs - mechanical checks on the fragment shader src/shaders/voxel.js
//                 assembles, for the failures that are cheap to catch without a GPU.
//
//   run:  node test/glsl-lint.mjs
//   exit: 0 = every check passed, 1 = first failure printed
//
// WHAT THIS PROVES
//   The assembled string is structurally coherent: brackets balance, no chunk
//   redeclares another chunk's function, nothing is called before it is declared,
//   no JS-only literal (Infinity, NaN) leaked into GLSL, no stray #version, and the
//   JS uniform object and the GLSL uniform declarations name exactly the same set.
//
// WHAT THIS DOES NOT PROVE
//   It is not a compiler and it is not a renderer. It does no type checking, no
//   scope analysis inside function bodies, no swizzle validation, no const-expression
//   folding, no precision-range analysis, no linking, and it never touches a GL
//   context. A shader that passes every check here can still fail to compile on a
//   real driver, and one that compiles can still render garbage. The identifier
//   scan is textual, so a builtin missing from the whitelist below reports as an
//   undeclared call (a false positive to be fixed by extending the list, not by
//   loosening the check).
//
// It DOES exercise the real code path: buildVoxelMaterial() is imported and called,
// with the `three` specifier redirected to test/three-stub.mjs, so the linted string
// is the one the browser would compile rather than a re-implementation of it.

import { registerHooks } from 'node:module';

const STUB = new URL('./three-stub.mjs', import.meta.url).href;
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === 'three') return { url: STUB, shortCircuit: true };
    return nextResolve(specifier, context);
  },
});

const { buildVoxelMaterial, VERTEX_GLSL } = await import('../src/shaders/voxel.js');
const { pyramidLayout } = await import('../src/gpu.js');

// ── the subject ──────────────────────────────────────────────────────────────
// A minimal stand-in for World: buildVoxelMaterial reads only N, LMAX and pal.
// N = 256 is the port's default. PAL_LEN comes out of pal.length / 3 and must be
// 43 or common.glsl.js's `uniform vec3 uPal[43]` disagrees with it.
const N = 256;
const world = { N, LMAX: Math.log2(N) | 0, pal: new Float32Array(43 * 3) };
const layout = pyramidLayout(N);
const textures = { volumeTex: { __stub: 'vol' }, pyrTex: { __stub: 'pyr' } };

const built = buildVoxelMaterial(world, layout, textures);
const SRC = built.fragmentSource;
const UNIFORM_KEYS = Object.keys(built.uniforms);

// ── helpers ──────────────────────────────────────────────────────────────────

// Comments are where the words "Infinity", "for(;;)" and half the punctuation in
// these files live, so every structural check runs on a comment-free copy. Spaces
// replace the removed text so byte offsets stay usable for line numbers.
function stripComments(src) {
  let out = '';
  let i = 0;
  while (i < src.length) {
    if (src[i] === '/' && src[i + 1] === '/') {
      while (i < src.length && src[i] !== '\n') { out += ' '; i++; }
    } else if (src[i] === '/' && src[i + 1] === '*') {
      const end = src.indexOf('*/', i + 2);
      const stop = end === -1 ? src.length : end + 2;
      for (; i < stop; i++) out += src[i] === '\n' ? '\n' : ' ';
    } else {
      out += src[i];
      i++;
    }
  }
  return out;
}

const CODE = stripComments(SRC);

// Preprocessor lines blanked out, offsets preserved. `#define TRACE_MAX_STEPS (8 * N)`
// otherwise reads as a call to TRACE_MAX_STEPS, and a macro body is not a call site.
const CODE_NOPP = CODE.split('\n')
  .map((line) => (/^[ \t]*#/.test(line) ? ' '.repeat(line.length) : line))
  .join('\n');

const lineOf = (src, index) => src.slice(0, index).split('\n').length;

const failures = [];
let checkNo = 0;
function check(label, fn) {
  checkNo++;
  let problems;
  try {
    problems = fn() || [];
  } catch (err) {
    problems = [`check threw: ${err && err.stack ? err.stack : err}`];
  }
  const tag = String(checkNo).padStart(2, ' ');
  if (problems.length === 0) {
    console.log(`ok  ${tag}  ${label}`);
  } else {
    console.log(`FAIL ${tag}  ${label}`);
    for (const p of problems) console.log(`        ${p}`);
    failures.push(label);
  }
}

// ── 1. balanced brackets ─────────────────────────────────────────────────────

check('brackets balance: {} () []', () => {
  const pairs = { '}': '{', ')': '(', ']': '[' };
  const open = new Set(['{', '(', '[']);
  const stack = [];
  const bad = [];
  for (let i = 0; i < CODE.length; i++) {
    const ch = CODE[i];
    if (open.has(ch)) stack.push({ ch, i });
    else if (pairs[ch]) {
      const top = stack.pop();
      if (!top) { bad.push(`line ${lineOf(CODE, i)}: stray '${ch}'`); break; }
      if (top.ch !== pairs[ch]) {
        bad.push(`line ${lineOf(CODE, i)}: '${ch}' closes '${top.ch}' opened at line ${lineOf(CODE, top.i)}`);
        break;
      }
    }
  }
  if (bad.length === 0 && stack.length) {
    const t = stack[stack.length - 1];
    bad.push(`unclosed '${t.ch}' opened at line ${lineOf(CODE, t.i)} (${stack.length} still open)`);
  }
  return bad;
});

// ── 2. no JS-only numeric literals ───────────────────────────────────────────
// GLSL ES 3.00 has no Infinity and no NaN literal. traverse.glsl.js substitutes
// 1e30 / -1e30 and says so in a comment, which is why this runs on CODE.

check("no 'Infinity' or 'NaN' literal outside comments", () => {
  const bad = [];
  for (const word of ['Infinity', 'NaN']) {
    const re = new RegExp(`\\b${word}\\b`, 'g');
    let m;
    while ((m = re.exec(CODE)) !== null) bad.push(`line ${lineOf(CODE, m.index)}: '${word}'`);
  }
  return bad;
});

// ── 3. no #version ───────────────────────────────────────────────────────────
// three.js prepends '#version 300 es' itself; a second one is a compile error and
// a #version anywhere but the first line is a compile error regardless.

check('no #version directive (three.js prepends it)', () => {
  const bad = [];
  SRC.split('\n').forEach((line, i) => {
    if (/^\s*#\s*version\b/.test(line)) bad.push(`line ${i + 1}: ${line.trim()}`);
  });
  return bad;
});

// ── 4. function declarations: collect, then check for duplicates ─────────────

// Matches a definition at column 0: `<type> <name>(<params>) {`. Every function in
// these chunks is written that way; an indented definition would be a nested
// function, which GLSL does not have.
const DECL_RE = /^([A-Za-z_]\w*)[ \t]+([A-Za-z_]\w*)[ \t]*\(([^)]*)\)[ \t]*\{/gm;

const decls = [];
{
  let m;
  while ((m = DECL_RE.exec(CODE)) !== null) {
    const params = m[3]
      .split(',')
      .map((p) => p.trim())
      .filter(Boolean)
      // keep the type words, drop the parameter name and any in/out/inout qualifier
      .map((p) => p.split(/\s+/).slice(0, -1).filter((w) => w !== 'in' && w !== 'out' && w !== 'inout').join(' '))
      .join(', ');
    decls.push({ ret: m[1], name: m[2], params, index: m.index, line: lineOf(CODE, m.index) });
  }
}

check('function definitions found', () => (decls.length >= 10
  ? []
  : [`only ${decls.length} definitions matched; the declaration regex has probably stopped matching`]));

check('no duplicate function signature', () => {
  const seen = new Map();
  const bad = [];
  for (const d of decls) {
    const sig = `${d.name}(${d.params})`;
    if (seen.has(sig)) bad.push(`line ${d.line}: '${sig}' already defined at line ${seen.get(sig)}`);
    else seen.set(sig, d.line);
  }
  return bad;
});

// ── 5. every call resolves to something declared earlier ─────────────────────

// GLSL ES 3.00 builtins, constructors and keywords that parse as `name(`.
// Deliberately explicit: an unknown name should surface as a failure, not be
// waved through by a permissive pattern.
const BUILTINS = new Set([
  // control flow that looks like a call
  'if', 'for', 'while', 'switch', 'return',
  // scalar / vector / matrix constructors
  'float', 'int', 'uint', 'bool', 'double',
  'vec2', 'vec3', 'vec4', 'ivec2', 'ivec3', 'ivec4',
  'uvec2', 'uvec3', 'uvec4', 'bvec2', 'bvec3', 'bvec4',
  'mat2', 'mat3', 'mat4', 'mat2x2', 'mat2x3', 'mat2x4',
  'mat3x2', 'mat3x3', 'mat3x4', 'mat4x2', 'mat4x3', 'mat4x4',
  // angle / trig
  'radians', 'degrees', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan',
  'sinh', 'cosh', 'tanh', 'asinh', 'acosh', 'atanh',
  // exponential
  'pow', 'exp', 'log', 'exp2', 'log2', 'sqrt', 'inversesqrt',
  // common
  'abs', 'sign', 'floor', 'trunc', 'round', 'roundEven', 'ceil', 'fract',
  'mod', 'modf', 'min', 'max', 'clamp', 'mix', 'step', 'smoothstep',
  'isnan', 'isinf', 'floatBitsToInt', 'floatBitsToUint',
  'intBitsToFloat', 'uintBitsToFloat',
  // geometric
  'length', 'distance', 'dot', 'cross', 'normalize', 'faceforward',
  'reflect', 'refract',
  // matrix
  'matrixCompMult', 'outerProduct', 'transpose', 'determinant', 'inverse',
  // vector relational
  'lessThan', 'lessThanEqual', 'greaterThan', 'greaterThanEqual',
  'equal', 'notEqual', 'any', 'all', 'not',
  // texture
  'textureSize', 'texture', 'textureProj', 'textureLod', 'textureOffset',
  'texelFetch', 'texelFetchOffset', 'textureProjOffset', 'textureLodOffset',
  'textureProjLod', 'textureProjLodOffset', 'textureGrad', 'textureGradOffset',
  'textureProjGrad', 'textureProjGradOffset',
  // fragment derivatives / packing
  'dFdx', 'dFdy', 'fwidth',
  'packSnorm2x16', 'unpackSnorm2x16', 'packUnorm2x16', 'unpackUnorm2x16',
  'packHalf2x16', 'unpackHalf2x16',
  // qualifiers whose argument list parses as a call
  'layout',
]);

const declaredNames = new Map();   // name -> first definition index
for (const d of decls) if (!declaredNames.has(d.name)) declaredNames.set(d.name, d.index);

// Skip the '(' of a definition itself, otherwise every definition counts as a
// self-call at its own offset.
const defParenOffsets = new Set(decls.map((d) => CODE.indexOf('(', d.index)));

check('every function call is declared earlier in the source', () => {
  const bad = [];
  const CALL_RE = /([A-Za-z_]\w*)[ \t]*\(/g;
  let m;
  while ((m = CALL_RE.exec(CODE_NOPP)) !== null) {
    const name = m[1];
    const parenAt = m.index + m[0].length - 1;
    if (defParenOffsets.has(parenAt)) continue;
    if (BUILTINS.has(name)) continue;
    // a struct name used as a constructor, e.g. Hit(...)
    if (new RegExp(`\\bstruct[ \\t]+${name}\\b`).test(CODE)) continue;
    if (!declaredNames.has(name)) {
      bad.push(`line ${lineOf(CODE, m.index)}: call to undeclared '${name}'`);
    } else if (declaredNames.get(name) > m.index) {
      bad.push(`line ${lineOf(CODE, m.index)}: '${name}' called before its definition at line ${lineOf(CODE, declaredNames.get(name))}`);
    }
  }
  return bad;
});

// ── 6. const arrays are declared before they are indexed ─────────────────────
// PYR_OFF comes from gpu.js's shaderDefines() and is read by common.glsl.js's
// pyrAt(). If the concatenation order ever flips, the shader stops compiling.

check('no const array indexed before its declaration', () => {
  const bad = [];
  const ARR_RE = /\bconst[ \t]+[A-Za-z_]\w*[ \t]+([A-Za-z_]\w*)[ \t]*\[/g;
  let m;
  while ((m = ARR_RE.exec(CODE)) !== null) {
    const name = m[1];
    const declAt = m.index;
    const useRe = new RegExp(`\\b${name}[ \\t]*\\[`, 'g');
    let u;
    while ((u = useRe.exec(CODE)) !== null) {
      if (u.index < declAt) {
        bad.push(`line ${lineOf(CODE, u.index)}: '${name}[' used before its declaration at line ${lineOf(CODE, declAt)}`);
      }
    }
  }
  return bad;
});

// ── 7. GLSL uniforms and the JS uniform object agree, both ways ──────────────

const glslUniforms = [];
{
  // `uniform [highp|mediump|lowp] <type> <name>[ '[' N ']' ] ;`
  const RE = /\buniform[ \t]+(?:(?:highp|mediump|lowp)[ \t]+)?[A-Za-z_]\w*[ \t]+([A-Za-z_]\w*)/g;
  let m;
  while ((m = RE.exec(CODE)) !== null) glslUniforms.push(m[1]);
}

check('GLSL uniform declarations found', () => (glslUniforms.length >= 20
  ? []
  : [`only ${glslUniforms.length} uniforms matched; the uniform regex has probably stopped matching`]));

check('no duplicate uniform declaration', () => {
  const seen = new Set();
  const bad = [];
  for (const u of glslUniforms) {
    if (seen.has(u)) bad.push(`'${u}' declared more than once`);
    seen.add(u);
  }
  return bad;
});

check('uniform sets match: GLSL vs voxel.js uniform object', () => {
  const inGlsl = new Set(glslUniforms);
  const inJs = new Set(UNIFORM_KEYS);
  const bad = [];
  for (const u of [...inGlsl].sort()) {
    if (!inJs.has(u)) bad.push(`declared in GLSL but missing from the uniform object: ${u}`);
  }
  for (const u of [...inJs].sort()) {
    if (!inGlsl.has(u)) bad.push(`in the uniform object but never declared in GLSL: ${u}`);
  }
  return bad;
});

// ── 8. extras beyond the required list ───────────────────────────────────────
// Not structural coherence, but the two ordering hazards that would compile
// cleanly and then render wrong, which is worse than not compiling.

check("EXTRA: 'precision highp int' precedes the PYR_OFF const array", () => {
  const prec = CODE.search(/\bprecision[ \t]+highp[ \t]+int[ \t]*;/);
  const arr = CODE.search(/\bconst[ \t]+int[ \t]+PYR_OFF[ \t]*\[/);
  if (prec === -1) return ["no 'precision highp int;' anywhere: the fragment default is mediump (+/-32767) and PYR_OFF overflows it"];
  if (arr === -1) return ['no PYR_OFF const array found; shaderDefines() has changed shape'];
  return prec < arr ? [] : [`PYR_OFF declared at line ${lineOf(CODE, arr)} before 'precision highp int;' at line ${lineOf(CODE, prec)}`];
});

check('EXTRA: every injected #define is used, and every used constant is defined', () => {
  const defined = new Set();
  let m;
  const DEF_RE = /^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)/gm;
  while ((m = DEF_RE.exec(SRC)) !== null) defined.add(m[1]);
  const bad = [];
  for (const name of ['N', 'NF', 'LMAX', 'PYR_W', 'PAL_LEN']) {
    if (!defined.has(name)) bad.push(`contract #define missing: ${name}`);
  }
  // Anything ALL_CAPS that is used but neither #defined nor declared as a const.
  const USE_RE = /\b([A-Z][A-Z0-9_]{1,})\b/g;
  const constNames = new Set();
  const CONST_RE = /\bconst[ \t]+[A-Za-z_]\w*[ \t]+([A-Za-z_]\w*)/g;
  while ((m = CONST_RE.exec(CODE)) !== null) constNames.add(m[1]);
  const seenUndef = new Set();
  while ((m = USE_RE.exec(CODE)) !== null) {
    const name = m[1];
    if (defined.has(name) || constNames.has(name) || seenUndef.has(name)) continue;
    seenUndef.add(name);
    bad.push(`line ${lineOf(CODE, m.index)}: '${name}' looks like a constant but is neither #defined nor const-declared`);
  }
  return bad;
});

check('EXTRA: vertex shader brackets balance and declare position', () => {
  const v = stripComments(VERTEX_GLSL);
  const bad = [];
  let depth = 0;
  for (const ch of v) { if (ch === '{') depth++; else if (ch === '}') depth--; }
  if (depth !== 0) bad.push(`unbalanced braces (depth ${depth})`);
  if (!/\bin[ \t]+vec3[ \t]+position[ \t]*;/.test(v)) {
    bad.push('no `in vec3 position;`: a RawShaderMaterial gets no attribute declarations from three.js');
  }
  if (/^\s*#\s*version\b/m.test(VERTEX_GLSL)) bad.push('#version directive present');
  return bad;
});

// ── report ───────────────────────────────────────────────────────────────────

console.log('');
console.log(`fragment source: ${SRC.split('\n').length} lines, ${SRC.length} bytes, `
  + `${decls.length} functions, ${glslUniforms.length} uniforms`);
console.log('caveat: this is a text lint, not a compiler. It does no type, scope, swizzle,');
console.log('        precision-range or link checking and never touches a GL context.');
console.log('        Passing here does not mean the shader compiles on a real driver.');

if (failures.length) {
  console.log('');
  console.log(`${failures.length} check(s) failed: ${failures.join('; ')}`);
  process.exit(1);
}

console.log('');
console.log(`${checkNo}/${checkNo} checks passed.`);
process.exit(0);
