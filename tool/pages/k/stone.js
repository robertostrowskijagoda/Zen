// The pebble of the pebble page, drawn in a <canvas>: a stone shaped from
// the card's shape preset and seed (a squashed superellipsoid with a few
// soft bumps, resting on its flatter side), in its two colours and
// material, with the painted top (the card's 16 x 16 thumbnail, smoothed)
// and a soft shadow. WebGL lights it and turns it slowly; the pointer, a
// drag or the phone's tilt turns it too, for every visitor: the owner's
// decision is that animations ignore prefers-reduced-motion. Without WebGL a
// flat drawing of the same stone. It need not match the app's mesh exactly.
//
//   var stone = ZenStone.show(canvas, {shape, seed, material, main: [r, g, b],
//                                      second: [r, g, b], thumbnail});
(function (root) {
  "use strict";

  // A small seeded random generator (mulberry32): the same stone for the
  // same card.
  function random(seed) {
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // The proportions of the stone: six families by the shape preset, each
  // varied by the seed.
  function form(look) {
    var r = random((look.seed ^ Math.imul((look.shape | 0) + 1, 0x9E3779B1)) >>> 0);
    function between(a, b) { return a + (b - a) * r(); }
    var f;
    switch ((look.shape | 0) % 6) {
      case 0: f = { sx: 1, sz: between(0.86, 0.98), sy: between(0.5, 0.62), e: between(0.86, 0.96), taper: 0 }; break; // round
      case 1: f = { sx: 1, sz: between(0.66, 0.78), sy: between(0.42, 0.54), e: between(0.86, 0.98), taper: 0 }; break; // oval
      case 2: f = { sx: 1, sz: between(0.8, 0.92), sy: between(0.28, 0.36), e: between(0.8, 0.92), taper: 0 }; break; // flat
      case 3: f = { sx: 1, sz: between(0.7, 0.8), sy: between(0.46, 0.56), e: between(0.88, 0.98), taper: between(0.16, 0.26) }; break; // egg
      case 4: f = { sx: 1, sz: between(0.82, 0.94), sy: between(0.56, 0.68), e: between(0.66, 0.78), taper: 0 }; break; // chunky
      default: f = { sx: 1, sz: between(0.52, 0.62), sy: between(0.36, 0.46), e: between(0.82, 0.92), taper: between(0, 0.1) }; // long
    }
    // Flat, as people paint pebbles (the app's kPebbleMaxHeight).
    f.sy = Math.min(f.sy * 0.62, 0.4);
    f.ey = between(0.62, 0.8);
    f.bumps = [];
    for (var i = 0; i < 4; i++) {
      var u = between(-1, 1), a = between(0, Math.PI * 2), s = Math.sqrt(1 - u * u);
      f.bumps.push({ w: [s * Math.cos(a), u, s * Math.sin(a)], k: between(1.2, 2.6), amp: between(0.015, 0.04), ph: between(0, 6.28) });
    }
    return f;
  }

  function signedPow(v, e) { return (v < 0 ? -1 : 1) * Math.pow(Math.abs(v), e); }

  // The stone as triangles: positions, normals, indices, and its extent.
  function mesh(f) {
    var NR = 36, NS = 64;
    var pos = [];
    function vertex(phi, theta) {
      var cp = Math.cos(phi), sinp = Math.sin(phi), ct = Math.cos(theta), st = Math.sin(theta);
      var dir = [cp * ct, sinp, cp * st];
      var x = signedPow(cp, f.e) * signedPow(ct, f.e);
      var y = signedPow(sinp, f.ey);
      var z = signedPow(cp, f.e) * signedPow(st, f.e);
      if (y < 0) { y *= 0.8; }
      var bump = 1;
      for (var i = 0; i < f.bumps.length; i++) {
        var b = f.bumps[i];
        bump += b.amp * Math.sin(b.k * (dir[0] * b.w[0] + dir[1] * b.w[1] + dir[2] * b.w[2]) * 1.6 + b.ph);
      }
      z *= 1 + f.taper * x;
      pos.push(x * f.sx * bump, y * f.sy * bump, z * f.sz * bump);
    }
    vertex(Math.PI / 2, 0);
    for (var i = 1; i < NR; i++) {
      for (var j = 0; j < NS; j++) { vertex(Math.PI / 2 - i * Math.PI / NR, j * 2 * Math.PI / NS); }
    }
    vertex(-Math.PI / 2, 0);
    var idx = [];
    var last = 1 + (NR - 1) * NS;
    for (j = 0; j < NS; j++) {
      var jn = (j + 1) % NS;
      idx.push(0, 1 + j, 1 + jn);
      var bottom = 1 + (NR - 2) * NS;
      idx.push(last, bottom + jn, bottom + j);
    }
    for (i = 0; i < NR - 2; i++) {
      var a = 1 + i * NS, b2 = a + NS;
      for (j = 0; j < NS; j++) {
        jn = (j + 1) % NS;
        idx.push(a + j, b2 + j, b2 + jn, a + j, b2 + jn, a + jn);
      }
    }
    // Centred on its footprint, a radius of 1 across.
    var n = pos.length / 3, min = [1e9, 1e9, 1e9], max = [-1e9, -1e9, -1e9], k;
    for (i = 0; i < n; i++) {
      for (k = 0; k < 3; k++) {
        min[k] = Math.min(min[k], pos[3 * i + k]);
        max[k] = Math.max(max[k], pos[3 * i + k]);
      }
    }
    var cx = (min[0] + max[0]) / 2, cz = (min[2] + max[2]) / 2;
    var scale = 2 / Math.max(max[0] - min[0], max[2] - min[2]);
    for (i = 0; i < n; i++) {
      pos[3 * i] = (pos[3 * i] - cx) * scale;
      pos[3 * i + 1] *= scale;
      pos[3 * i + 2] = (pos[3 * i + 2] - cz) * scale;
    }
    // Smooth normals: each face's, turned outwards, summed at its corners.
    var nor = new Float32Array(n * 3);
    for (i = 0; i < idx.length; i += 3) {
      var p = idx[i] * 3, q = idx[i + 1] * 3, s = idx[i + 2] * 3;
      var ux = pos[q] - pos[p], uy = pos[q + 1] - pos[p + 1], uz = pos[q + 2] - pos[p + 2];
      var vx = pos[s] - pos[p], vy = pos[s + 1] - pos[p + 1], vz = pos[s + 2] - pos[p + 2];
      var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      if (nx * (pos[p] + pos[q] + pos[s]) + ny * (pos[p + 1] + pos[q + 1] + pos[s + 1]) +
          nz * (pos[p + 2] + pos[q + 2] + pos[s + 2]) < 0) {
        nx = -nx; ny = -ny; nz = -nz;
      }
      for (k = 0; k < 3; k++) {
        var at = idx[i + k] * 3;
        nor[at] += nx; nor[at + 1] += ny; nor[at + 2] += nz;
      }
    }
    for (i = 0; i < n; i++) {
      var len = Math.hypot(nor[3 * i], nor[3 * i + 1], nor[3 * i + 2]) || 1;
      nor[3 * i] /= len; nor[3 * i + 1] /= len; nor[3 * i + 2] /= len;
    }
    return {
      pos: new Float32Array(pos), nor: nor, idx: new Uint16Array(idx),
      box: [(min[0] - cx) * scale, (min[2] - cz) * scale, (max[0] - cx) * scale, (max[2] - cz) * scale],
      bottom: min[1] * scale, top: max[1] * scale
    };
  }

  // The material presets come in four looks: speckled granite, a mottled
  // river stone, sea glass and gloss paint.
  function material(id) {
    switch ((id | 0) % 4) {
      case 0: return { speck: 1, band: 0.35, gloss: 0.25, shine: 18 };
      case 1: return { speck: 0.15, band: 1, gloss: 0.35, shine: 24 };
      case 2: return { speck: 0, band: 0.5, gloss: 0.9, shine: 60 };
      default: return { speck: 0, band: 0.12, gloss: 0.75, shine: 40 };
    }
  }

  // --- 4 x 4 matrices, column by column -------------------------------------
  function mul(a, b) {
    var o = new Float32Array(16);
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        var s = 0;
        for (var k = 0; k < 4; k++) { s += a[k * 4 + r] * b[c * 4 + k]; }
        o[c * 4 + r] = s;
      }
    }
    return o;
  }
  function perspective(fovy, aspect, near, far) {
    var f = 1 / Math.tan(fovy / 2), nf = 1 / (near - far);
    return new Float32Array([f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) * nf, -1, 0, 0, 2 * far * near * nf, 0]);
  }
  function lookAt(eye, at) {
    var z = [eye[0] - at[0], eye[1] - at[1], eye[2] - at[2]];
    var zl = Math.hypot(z[0], z[1], z[2]);
    z = [z[0] / zl, z[1] / zl, z[2] / zl];
    var x = [z[2], 0, -z[0]];
    var xl = Math.hypot(x[0], x[1], x[2]);
    x = [x[0] / xl, x[1] / xl, x[2] / xl];
    var y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]];
    function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
    return new Float32Array([x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0,
      -dot(x, eye), -dot(y, eye), -dot(z, eye), 1]);
  }
  function rotX(a) { var c = Math.cos(a), s = Math.sin(a); return new Float32Array([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]); }
  function rotY(a) { var c = Math.cos(a), s = Math.sin(a); return new Float32Array([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]); }
  function rotZ(a) { var c = Math.cos(a), s = Math.sin(a); return new Float32Array([c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]); }

  var STONE_VS = [
    "attribute vec3 aPos;",
    "attribute vec3 aNor;",
    "uniform mat4 uModel;",
    "uniform mat4 uViewProj;",
    "uniform mat3 uNormal;",
    "varying vec3 vObj;",
    "varying vec3 vNorObj;",
    "varying vec3 vNor;",
    "varying vec3 vPos;",
    "void main() {",
    "  vObj = aPos;",
    "  vNorObj = aNor;",
    "  vec4 w = uModel * vec4(aPos, 1.0);",
    "  vPos = w.xyz;",
    "  vNor = uNormal * aNor;",
    "  gl_Position = uViewProj * w;",
    "}"
  ].join("\n");

  var STONE_FS = [
    "#ifdef GL_FRAGMENT_PRECISION_HIGH",
    "precision highp float;",
    "#else",
    "precision mediump float;",
    "#endif",
    "uniform vec3 uMain;",
    "uniform vec3 uSecond;",
    "uniform vec4 uMat;", // speck, band, gloss, shine
    "uniform vec4 uBox;", // min x, min z, 1 / width, 1 / depth
    "uniform float uHasThumb;",
    "uniform sampler2D uThumb;",
    "uniform vec3 uLight;",
    "uniform vec3 uEye;",
    "varying vec3 vObj;",
    "varying vec3 vNorObj;",
    "varying vec3 vNor;",
    "varying vec3 vPos;",
    "float hash(vec3 p) {",
    "  p = fract(p * 0.3183099 + 0.1);",
    "  p *= 17.0;",
    "  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));",
    "}",
    "float noise(vec3 x) {",
    "  vec3 i = floor(x);",
    "  vec3 f = fract(x);",
    "  f = f * f * (3.0 - 2.0 * f);",
    "  return mix(mix(mix(hash(i), hash(i + vec3(1.0, 0.0, 0.0)), f.x),",
    "                 mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),",
    "             mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),",
    "                 mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);",
    "}",
    "vec3 lin(vec3 c) { return pow(c, vec3(2.2)); }",
    "void main() {",
    "  vec3 base = lin(uMain);",
    "  vec3 alt = lin(uSecond);",
    "  float m = noise(vObj * 2.6) * 0.65 + noise(vObj * 6.0 + 3.1) * 0.35;",
    "  vec3 c = mix(base, alt, smoothstep(0.52, 0.82, m) * uMat.y * 0.85);",
    "  c *= 0.9 + 0.2 * noise(vObj * 14.0);",
    "  c = mix(c, alt, step(0.8, noise(vObj * 42.0)) * uMat.x);",
    "  c = mix(c, vec3(0.92), step(0.86, noise(vObj * 47.0 + 7.0)) * uMat.x * 0.6);",
    "  vec2 uv = vec2((vObj.x - uBox.x) * uBox.z, (vObj.z - uBox.y) * uBox.w);",
    "  vec4 paint = texture2D(uThumb, uv);",
    "  float top = smoothstep(0.08, 0.5, normalize(vNorObj).y) * uHasThumb;",
    "  float painted = paint.a * top;",
    "  c = mix(c, lin(paint.rgb), painted);",
    "  vec3 n = normalize(vNor);",
    "  vec3 l = normalize(uLight);",
    "  vec3 v = normalize(uEye - vPos);",
    "  vec3 h = normalize(l + v);",
    "  float wrap = clamp((dot(n, l) + 0.3) / 1.3, 0.0, 1.0);",
    "  float sky = 0.55 + 0.45 * n.y;",
    "  float under = 0.62 + 0.38 * smoothstep(-0.9, 0.3, normalize(vNorObj).y);",
    "  float gloss = mix(uMat.z, 0.6, painted);",
    "  float spec = pow(max(dot(n, h), 0.0), mix(uMat.w, 36.0, painted)) * gloss;",
    "  float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);",
    "  vec3 col = c * (0.3 * sky + 0.95 * wrap) * under + vec3(spec) * 0.7 + rim * 0.12 * (c + 0.2);",
    "  gl_FragColor = vec4(pow(col, vec3(1.0 / 2.2)), 1.0);",
    "}"
  ].join("\n");

  var SHADOW_VS = [
    "attribute vec2 aXY;",
    "uniform mat4 uViewProj;",
    "uniform vec3 uAt;",
    "uniform vec2 uSize;",
    "varying vec2 vUV;",
    "void main() {",
    "  vUV = aXY;",
    "  gl_Position = uViewProj * vec4(uAt + vec3(aXY.x * uSize.x, 0.0, aXY.y * uSize.y), 1.0);",
    "}"
  ].join("\n");

  var SHADOW_FS = [
    "precision mediump float;",
    "uniform float uStrength;",
    "varying vec2 vUV;",
    "void main() {",
    "  float d = length(vUV);",
    "  float a = pow(1.0 - smoothstep(0.0, 1.0, d), 1.6) * uStrength;",
    "  gl_FragColor = vec4(0.0, 0.0, 0.0, a);",
    "}"
  ].join("\n");

  function program(gl, vs, fs) {
    function shader(type, src) {
      var s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { throw new Error(gl.getShaderInfoLog(s) || "shader"); }
      return s;
    }
    var p = gl.createProgram();
    gl.attachShader(p, shader(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, shader(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { throw new Error(gl.getProgramInfoLog(p) || "program"); }
    return p;
  }

  // The thumbnail as RGBA: colour 0 transparent (with the main colour
  // underneath, so the smoothed edges do not darken).
  function thumbPixels(look) {
    var t = look.thumbnail, data = new Uint8Array(16 * 16 * 4);
    for (var i = 0; i < 256; i++) {
      var c = t.pixels[i], rgb = c ? t.palette[c] : look.main;
      data[4 * i] = rgb[0]; data[4 * i + 1] = rgb[1]; data[4 * i + 2] = rgb[2];
      data[4 * i + 3] = c ? 255 : 0;
    }
    return data;
  }

  // The thumbnail [side] pixels across, smoothed but crisp: between two
  // pixels the colour turns over half a pixel, not the whole one, so
  // a painted dot stays a round dot instead of a blur.
  var PAINT = 128;
  function paintPixels(look) {
    var src = thumbPixels(look), out = new Uint8Array(PAINT * PAINT * 4);
    function ease(f) { f = Math.max(0, Math.min(1, (f - 0.25) / 0.5)); return f * f * (3 - 2 * f); }
    for (var y = 0; y < PAINT; y++) {
      var fy = (y + 0.5) * 16 / PAINT - 0.5, y0 = Math.floor(fy), wy = ease(fy - y0);
      var ya = Math.max(0, y0), yb = Math.min(15, y0 + 1);
      for (var x = 0; x < PAINT; x++) {
        var fx = (x + 0.5) * 16 / PAINT - 0.5, x0 = Math.floor(fx), wx = ease(fx - x0);
        var xa = Math.max(0, x0), xb = Math.min(15, x0 + 1);
        for (var k = 0; k < 4; k++) {
          var top = src[(ya * 16 + xa) * 4 + k] * (1 - wx) + src[(ya * 16 + xb) * 4 + k] * wx;
          var bottom = src[(yb * 16 + xa) * 4 + k] * (1 - wx) + src[(yb * 16 + xb) * 4 + k] * wx;
          out[(y * PAINT + x) * 4 + k] = Math.round(top * (1 - wy) + bottom * wy);
        }
      }
    }
    return out;
  }

  var LIGHT = [-0.55, 1.0, 0.65];

  function webgl(canvas, look, shape) {
    var gl = canvas.getContext("webgl", { antialias: true, alpha: true, premultipliedAlpha: true }) ||
      canvas.getContext("experimental-webgl");
    if (!gl) { return null; }
    var stone = program(gl, STONE_VS, STONE_FS);
    var shadow = program(gl, SHADOW_VS, SHADOW_FS);
    function buffer(target, data) {
      var b = gl.createBuffer();
      gl.bindBuffer(target, b);
      gl.bufferData(target, data, gl.STATIC_DRAW);
      return b;
    }
    var posBuf = buffer(gl.ARRAY_BUFFER, shape.pos);
    var norBuf = buffer(gl.ARRAY_BUFFER, shape.nor);
    var idxBuf = buffer(gl.ELEMENT_ARRAY_BUFFER, shape.idx);
    var quadBuf = buffer(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]));
    var tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    if (look.thumbnail) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, PAINT, PAINT, 0, gl.RGBA, gl.UNSIGNED_BYTE, paintPixels(look));
    } else {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
    }
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    var u = {}, s = {};
    ["uModel", "uViewProj", "uNormal", "uMain", "uSecond", "uMat", "uBox", "uHasThumb", "uThumb", "uLight", "uEye"]
      .forEach(function (n) { u[n] = gl.getUniformLocation(stone, n); });
    ["uViewProj", "uAt", "uSize", "uStrength"].forEach(function (n) { s[n] = gl.getUniformLocation(shadow, n); });
    var aPos = gl.getAttribLocation(stone, "aPos"), aNor = gl.getAttribLocation(stone, "aNor");
    var aXY = gl.getAttribLocation(shadow, "aXY");
    var mat = material(look.material);
    var box = shape.box;
    var eye = [0, 2.3, 3.6];
    var dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;

    return function draw(yaw, tiltX, tiltZ) {
      var w = canvas.width, h = canvas.height;
      gl.viewport(0, 0, w, h);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      var viewProj = mul(perspective(0.52, w / h, 0.5, 20), lookAt(eye, [0, -0.08, 0]));
      var model = mul(rotX(tiltX), mul(rotZ(tiltZ), rotY(yaw)));

      gl.useProgram(shadow);
      gl.disable(gl.DEPTH_TEST);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.bindBuffer(gl.ARRAY_BUFFER, quadBuf);
      gl.enableVertexAttribArray(aXY);
      gl.vertexAttribPointer(aXY, 2, gl.FLOAT, false, 0, 0);
      gl.uniformMatrix4fv(s.uViewProj, false, viewProj);
      gl.uniform3f(s.uAt, 0.12, shape.bottom - 0.03, -0.06);
      gl.uniform2f(s.uSize, 1.32, 1.12);
      gl.uniform1f(s.uStrength, dark ? 0.75 : 0.42);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      gl.disableVertexAttribArray(aXY);

      gl.useProgram(stone);
      gl.disable(gl.BLEND);
      gl.enable(gl.DEPTH_TEST);
      gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
      gl.enableVertexAttribArray(aPos);
      gl.vertexAttribPointer(aPos, 3, gl.FLOAT, false, 0, 0);
      gl.bindBuffer(gl.ARRAY_BUFFER, norBuf);
      gl.enableVertexAttribArray(aNor);
      gl.vertexAttribPointer(aNor, 3, gl.FLOAT, false, 0, 0);
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idxBuf);
      gl.uniformMatrix4fv(u.uModel, false, model);
      gl.uniformMatrix4fv(u.uViewProj, false, viewProj);
      gl.uniformMatrix3fv(u.uNormal, false, new Float32Array([
        model[0], model[1], model[2], model[4], model[5], model[6], model[8], model[9], model[10]]));
      gl.uniform3f(u.uMain, look.main[0] / 255, look.main[1] / 255, look.main[2] / 255);
      gl.uniform3f(u.uSecond, look.second[0] / 255, look.second[1] / 255, look.second[2] / 255);
      gl.uniform4f(u.uMat, mat.speck, mat.band, mat.gloss, mat.shine);
      gl.uniform4f(u.uBox, box[0], box[1], 1 / (box[2] - box[0]), 1 / (box[3] - box[1]));
      gl.uniform1f(u.uHasThumb, look.thumbnail ? 1 : 0);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(u.uThumb, 0);
      gl.uniform3f(u.uLight, LIGHT[0], LIGHT[1], LIGHT[2]);
      gl.uniform3f(u.uEye, eye[0], eye[1], eye[2]);
      gl.drawElements(gl.TRIANGLES, shape.idx.length, gl.UNSIGNED_SHORT, 0);
      gl.disableVertexAttribArray(aPos);
      gl.disableVertexAttribArray(aNor);
    };
  }

  // Without WebGL: the stone seen from above, lit from the top left.
  function flat(canvas, look, f) {
    var ctx = canvas.getContext("2d");
    if (!ctx) { return function () {}; }
    function rgb(c, k) {
      return "rgb(" + Math.round(Math.min(255, c[0] * k)) + "," + Math.round(Math.min(255, c[1] * k)) + "," +
        Math.round(Math.min(255, c[2] * k)) + ")";
    }
    var paint = null;
    if (look.thumbnail) {
      paint = document.createElement("canvas");
      paint.width = paint.height = PAINT;
      var pc = paint.getContext("2d");
      var img = pc.createImageData(PAINT, PAINT);
      img.data.set(paintPixels(look));
      pc.putImageData(img, 0, 0);
    }
    return function draw() {
      var w = canvas.width, h = canvas.height;
      ctx.clearRect(0, 0, w, h);
      var cx = w / 2, cy = h * 0.47, rx = w * 0.36, ry = rx * (0.5 + 0.35 * f.sz);
      ctx.save();
      ctx.fillStyle = "rgba(0,0,0,.22)";
      ctx.beginPath();
      ctx.ellipse(cx + rx * 0.08, cy + ry * 0.62, rx * 1.02, ry * 0.7, 0, 0, Math.PI * 2);
      ctx.filter = "blur(" + Math.round(w / 40) + "px)";
      ctx.fill();
      ctx.restore();
      ctx.save();
      ctx.beginPath();
      ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2);
      ctx.clip();
      var g = ctx.createRadialGradient(cx - rx * 0.35, cy - ry * 0.45, rx * 0.1, cx, cy, rx * 1.15);
      g.addColorStop(0, rgb(look.main, 1.25));
      g.addColorStop(0.55, rgb(look.main, 1));
      g.addColorStop(1, rgb(look.main, 0.55));
      ctx.fillStyle = g;
      ctx.fillRect(cx - rx, cy - ry, 2 * rx, 2 * ry);
      if (paint) {
        ctx.imageSmoothingEnabled = true;
        ctx.imageSmoothingQuality = "high";
        ctx.globalAlpha = 0.95;
        ctx.drawImage(paint, cx - rx, cy - ry, 2 * rx, 2 * ry);
        ctx.globalAlpha = 1;
      }
      var shade = ctx.createRadialGradient(cx - rx * 0.3, cy - ry * 0.4, rx * 0.2, cx, cy, rx * 1.05);
      shade.addColorStop(0, "rgba(255,255,255,.28)");
      shade.addColorStop(0.6, "rgba(255,255,255,0)");
      shade.addColorStop(1, "rgba(0,0,0,.35)");
      ctx.fillStyle = shade;
      ctx.fillRect(cx - rx, cy - ry, 2 * rx, 2 * ry);
      ctx.restore();
    };
  }

  function show(canvas, look) {
    // The owner's decision: animations run for every visitor, whatever the system says about reduced motion (prefers-reduced-motion).
    var f = form(look);
    var draw = null;
    try { draw = webgl(canvas, look, mesh(f)); } catch (e) { draw = null; }
    var turning = !!draw;
    if (!draw) { draw = flat(canvas, look, f); }

    var yaw = -0.55, dragYaw = 0, dragTilt = 0;
    var follow = [0, 0], aim = [0, 0], tilt0 = null;
    var visible = true, frame = 0, last = 0, clock = 0;
    var moving = turning;

    function size() {
      var ratio = Math.min(window.devicePixelRatio || 1, 2);
      var box = canvas.getBoundingClientRect();
      var w = Math.max(1, Math.round(box.width * ratio)), h = Math.max(1, Math.round(box.height * ratio));
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    }
    function render(now) {
      frame = 0;
      var dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
      last = now;
      clock += dt;
      var k = 1 - Math.exp(-dt * 3.5);
      follow[0] += (aim[0] - follow[0]) * k;
      follow[1] += (aim[1] - follow[1]) * k;
      var autoYaw = moving ? clock * Math.PI * 2 / 48 : 0;
      var swayX = moving ? 0.07 * Math.sin(clock * 0.55) : 0;
      var swayZ = moving ? 0.05 * Math.sin(clock * 0.41 + 1) : 0;
      draw(yaw + autoYaw + dragYaw - follow[0] * 0.5,
        swayX + dragTilt + follow[1] * 0.32,
        swayZ - follow[0] * 0.22);
      if (moving && visible) { frame = requestAnimationFrame(render); }
      else { last = 0; }
    }
    function again() { if (!frame && visible) { frame = requestAnimationFrame(render); } }

    size();
    again();
    window.addEventListener("resize", function () { size(); again(); });

    if (turning) {
      // A drag turns the stone (sideways; the page still scrolls up and
      // down); a mouse over it leans it towards the pointer.
      var dragging = null;
      canvas.addEventListener("pointerdown", function (e) {
        dragging = { x: e.clientX, y: e.clientY, yaw: dragYaw, tilt: dragTilt };
        if (canvas.setPointerCapture) { try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* fine */ } }
      });
      canvas.addEventListener("pointermove", function (e) {
        var box = canvas.getBoundingClientRect();
        if (dragging) {
          dragYaw = dragging.yaw + (e.clientX - dragging.x) * 0.012;
          dragTilt = Math.max(-0.5, Math.min(0.5, dragging.tilt + (e.clientY - dragging.y) * 0.006));
          again();
        } else if (e.pointerType === "mouse") {
          aim = [Math.max(-1, Math.min(1, (e.clientX - box.left) / box.width * 2 - 1)),
            Math.max(-1, Math.min(1, (e.clientY - box.top) / box.height * 2 - 1))];
          again();
        }
      });
      function release() { dragging = null; }
      canvas.addEventListener("pointerup", release);
      canvas.addEventListener("pointercancel", release);
      canvas.addEventListener("pointerleave", function (e) {
        if (e.pointerType === "mouse") { aim = [0, 0]; again(); }
      });
      // The phone's tilt, from where it was first held.
      window.addEventListener("deviceorientation", function (e) {
        if (e.beta === null || e.gamma === null) { return; }
        if (!tilt0) { tilt0 = [e.beta, e.gamma]; }
        aim = [Math.max(-1, Math.min(1, (e.gamma - tilt0[1]) / 30)),
          Math.max(-1, Math.min(1, (e.beta - tilt0[0]) / 30))];
        again();
      });
      if ("IntersectionObserver" in window) {
        new IntersectionObserver(function (entries) {
          visible = entries[0].isIntersecting;
          again();
        }).observe(canvas);
      }
    }
    return { webgl: turning };
  }

  root.ZenStone = { show: show, form: form };
})(this);
