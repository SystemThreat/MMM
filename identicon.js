// Tetromino identicon for an xCoin identity, the xCoin mark: a 12×12
// board tiled with the seven tetrominoes in their seven colours, seeded by
// HMAC-SHA256(identity, 'xcoin-identicon-v1') through xorshift128. The seed is the xid1…
// form of the key, so every address form of the same key draws the same mark. Pure SVG, no
// script, no popup; the caller decides the display size.
const SHAPES = {
  I: [[0, 0], [1, 0], [2, 0], [3, 0]],
  O: [[0, 0], [1, 0], [0, 1], [1, 1]],
  T: [[1, 0], [0, 1], [1, 1], [2, 1]],
  S: [[1, 0], [2, 0], [0, 1], [1, 1]],
  Z: [[0, 0], [1, 0], [1, 1], [2, 1]],
  J: [[0, 0], [0, 1], [1, 1], [2, 1]],
  L: [[2, 0], [0, 1], [1, 1], [2, 1]],
};
const COLORS = { I: '#ff0000', O: '#ff8000', T: '#ffff00', S: '#00ff00', Z: '#0000ff', J: '#4b0082', L: '#8b00ff' };

function allOrientations() {
  const out = [];
  for (const [name, coords] of Object.entries(SHAPES)) {
    const seen = new Set();
    let cur = coords;
    for (let rot = 0; rot < 4; rot++) {
      const r = cur.map(([x, y]) => [y, -x]);
      const mx = Math.min(...r.map(p => p[0])), my = Math.min(...r.map(p => p[1]));
      const n = r.map(([x, y]) => [x - mx, y - my]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
      const k = JSON.stringify(n);
      if (!seen.has(k)) { seen.add(k); out.push({ name, coords: n }); }
      cur = r;
    }
  }
  return out;
}
const ALL = allOrientations();

class RNG {
  constructor(bytes) {
    this.s = new Uint32Array(4);
    for (let i = 0; i < 4; i++) {
      const o = i * 4;
      this.s[i] = ((bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]) >>> 0;
      if (this.s[i] === 0) this.s[i] = 0x9E3779B9 + i;
    }
  }
  next() {
    let t = this.s[3]; t ^= t << 11; t ^= t >>> 8;
    this.s[3] = this.s[2]; this.s[2] = this.s[1]; this.s[1] = this.s[0];
    const s0 = this.s[0]; t ^= s0; t ^= s0 >>> 19; this.s[0] = t;
    return (t >>> 0) / 0x100000000;
  }
  nextInt(max) { return Math.floor(this.next() * max); }
  shuffle(arr) {
    const a = [...arr];
    for (let i = a.length - 1; i > 0; i--) { const j = this.nextInt(i + 1); [a[i], a[j]] = [a[j], a[i]]; }
    return a;
  }
}

async function hmacSha256(key, data) {
  const enc = new TextEncoder();
  const ck = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', ck, enc.encode(data)));
}

// tiling v2 (2026-09-24: all marks changed pre-mainnet). The old greedy
// scanline tiler could strand single cells; this backtracker always returns a
// perfect tiling — 36 pieces of exactly 4 cells covering all 144. At each step
// it fills the first empty cell in scan order, trying the RNG-shuffled anchored
// orientations, pruning any hole whose area is not a multiple of 4. The
// same-name-orthogonal-adjacency rule is a preference: three budgeted attempts
// enforce it, and only if all three exhaust does a final unbounded pass relax
// it (the documented last resort). The 4-cell rule is never relaxed.
const ANCHORED = ALL.map(({ name, coords }) => {
  let [ax, ay] = coords[0];
  for (const [x, y] of coords) if (y < ay || (y === ay && x < ax)) { ax = x; ay = y; }
  return { name, coords, ax, ay };
});
const TILE_ATTEMPTS = 3, TILE_BUDGET = 2500;

function solvePieces(N, rng, enforceAdj, budget) {
  const board = Array.from({ length: N }, () => Array(N).fill(null));
  const pieces = [];
  let steps = 0, dead = false;

  const regionsOk = () => {
    const seen = new Uint8Array(N * N);
    for (let i = 0; i < N * N; i++) {
      if (board[(i / N) | 0][i % N] !== null || seen[i]) continue;
      const stack = [i]; seen[i] = 1; let size = 0;
      while (stack.length) {
        const u = stack.pop(); size++;
        const ur = (u / N) | 0, uc = u % N;
        for (const [dr, dc] of [[0, 1], [1, 0], [0, -1], [-1, 0]]) {
          const nr = ur + dr, nc = uc + dc;
          if (nr >= 0 && nr < N && nc >= 0 && nc < N && board[nr][nc] === null) {
            const v = nr * N + nc;
            if (!seen[v]) { seen[v] = 1; stack.push(v); }
          }
        }
      }
      if (size % 4) return false;
    }
    return true;
  };

  const solve = () => {
    if (dead) return false;
    let k = -1;
    for (let i = 0; i < N * N; i++) if (board[(i / N) | 0][i % N] === null) { k = i; break; }
    if (k < 0) return true;
    const r = (k / N) | 0, c = k % N;
    const cands = [];
    for (const { name, coords, ax, ay } of ANCHORED) {
      let ok = true;
      const cells = [];
      for (const [dx, dy] of coords) {
        const rr = r + dy - ay, cc = c + dx - ax;
        if (rr < 0 || rr >= N || cc < 0 || cc >= N || board[rr][cc] !== null) { ok = false; break; }
        cells.push([rr, cc]);
      }
      if (!ok) continue;
      if (enforceAdj) {
        const cellSet = new Set(cells.map(([rr, cc]) => rr * N + cc));
        for (const [rr, cc] of cells) {
          for (const [dr, dc] of [[0, 1], [1, 0], [0, -1], [-1, 0]]) {
            const nr = rr + dr, nc = cc + dc;
            if (nr >= 0 && nr < N && nc >= 0 && nc < N && board[nr][nc] === name && !cellSet.has(nr * N + nc)) { ok = false; break; }
          }
          if (!ok) break;
        }
      }
      if (ok) cands.push({ name, cells });
    }
    for (const { name, cells } of rng.shuffle(cands)) {
      steps++;
      if (steps > budget) { dead = true; return false; }
      for (const [rr, cc] of cells) board[rr][cc] = name;
      pieces.push({ name, cells });
      if (regionsOk() && solve()) return true;
      pieces.pop();
      for (const [rr, cc] of cells) board[rr][cc] = null;
      if (dead) return false;
    }
    return false;
  };

  return solve() && !dead ? pieces : null;
}

function tilePieces(N, rng) {
  for (let attempt = 0; attempt < TILE_ATTEMPTS; attempt++) {
    const p = solvePieces(N, rng, true, TILE_BUDGET);
    if (p) return p;
  }
  return solvePieces(N, rng, false, Infinity);
}

function tile(N, rng) {
  const board = Array.from({ length: N }, () => Array(N).fill(null));
  for (const { name, cells } of tilePieces(N, rng)) for (const [rr, cc] of cells) board[rr][cc] = name;
  return board;
}

// The tiling as pieces — for tests that verify the mark is a perfect tiling.
async function identiconPieces(identity) {
  const rng = new RNG(await hmacSha256(identity, 'xcoin-identicon-v1'));
  return tilePieces(12, rng);
}

async function identiconSvg(identity, size = 240) {
  if (!identity) return '';
  const N = 12;
  const rng = new RNG(await hmacSha256(identity, 'xcoin-identicon-v1'));
  const board = tile(N, rng);
  let rects = '';
  for (let r = 0; r < N; r++) for (let c = 0; c < N; c++) {
    if (board[r][c]) rects += `<rect x="${c}" y="${r}" width="1" height="1" fill="${COLORS[board[r][c]]}"/>`;
  }
  return `<svg class="identicon" width="${size}" height="${size}" viewBox="0 0 ${N} ${N}" role="img" aria-label="identicon" shape-rendering="crispEdges"><rect width="${N}" height="${N}" fill="#0b0f1a"/>${rects}</svg>`;
}
