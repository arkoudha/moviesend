'use strict';

let sessionToken = null;
let videos = [];
let selectedIds = new Set();
let downloadControllers = [];

// ─── Init ────────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  // Restore session from cookie
  const cookie = Object.fromEntries(
    document.cookie.split(';').map(c => c.trim().split('=').map(decodeURIComponent))
  );
  if (cookie.session) {
    sessionToken = cookie.session;
    showVideosPage();
  }

  document.getElementById('pin-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') authenticate();
  });
});

// ─── Auth ─────────────────────────────────────────────────────────────────────

async function authenticate() {
  const pin = document.getElementById('pin-input').value.trim().toUpperCase();
  const errEl = document.getElementById('auth-error');
  const btn   = document.getElementById('auth-btn');

  errEl.classList.add('hidden');
  if (pin.length !== 4) { showError(errEl, '4文字のPINを入力してください'); return; }

  btn.disabled = true;
  try {
    const res  = await fetch('/api/auth', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin })
    });
    const data = await res.json();
    if (data.success) {
      sessionToken = data.token;
      // Store in cookie (server also sets HttpOnly cookie; this is for JS access)
      document.cookie = `session=${data.token}; path=/; SameSite=Strict`;
      showVideosPage();
    } else {
      showError(errEl, 'PINが正しくありません');
      btn.disabled = false;
    }
  } catch {
    showError(errEl, '接続エラーが発生しました');
    btn.disabled = false;
  }
}

function showError(el, msg) {
  el.textContent = msg;
  el.classList.remove('hidden');
}

// ─── Videos page ─────────────────────────────────────────────────────────────

async function showVideosPage() {
  show('videos-page');
  hide('auth-page');
  hide('progress-page');
  await loadVideos();
}

async function loadVideos() {
  try {
    const res = await apiFetch('/api/videos');
    if (!res) return;
    const data = await res.json();
    videos = data.videos || [];
    renderVideoList();
  } catch (e) {
    console.error('loadVideos:', e);
  }
}

function renderVideoList() {
  const list  = document.getElementById('video-list');
  const count = document.getElementById('video-count');
  count.textContent = `${videos.length}件`;

  list.innerHTML = videos.map(v => `
    <div class="video-item" data-id="${esc(v.id)}" onclick="handleRowClick(event,'${esc(v.id)}')">
      <input type="checkbox" id="cb-${esc(v.id)}"
             ${selectedIds.has(v.id) ? 'checked' : ''}
             onclick="event.stopPropagation(); toggleSelect('${esc(v.id)}')">
      <div class="video-thumb" id="thumb-${esc(v.id)}">🎬</div>
      <div class="video-info">
        <div class="video-name">${esc(v.filename)}</div>
        <div class="video-meta">${fmtDur(v.duration)} · ${fmtSize(v.size)} · ${v.width}×${v.height}</div>
      </div>
    </div>
  `).join('');

  videos.forEach(loadThumbnail);
  updateDownloadBtn();
}

function handleRowClick(e, id) {
  if (e.target.tagName === 'INPUT') return;
  toggleSelect(id);
}

function loadThumbnail(v) {
  const el = document.getElementById(`thumb-${v.id}`);
  if (!el) return;
  const img = new Image();
  img.onload = () => { el.innerHTML = ''; el.appendChild(img); };
  img.src = `/api/videos/${encodeURIComponent(v.id)}/thumbnail?token=${sessionToken}`;
}

function toggleSelect(id) {
  selectedIds.has(id) ? selectedIds.delete(id) : selectedIds.add(id);
  const cb = document.getElementById(`cb-${id}`);
  if (cb) cb.checked = selectedIds.has(id);
  updateDownloadBtn();
  updateSelectAllCheckbox();
}

function toggleSelectAll() {
  const all = document.getElementById('select-all').checked;
  selectedIds = all ? new Set(videos.map(v => v.id)) : new Set();
  renderVideoList();
}

function updateSelectAllCheckbox() {
  const cb = document.getElementById('select-all');
  if (cb) cb.checked = selectedIds.size === videos.length && videos.length > 0;
}

function updateDownloadBtn() {
  const btn = document.getElementById('download-btn');
  btn.disabled = selectedIds.size === 0;
  btn.textContent = selectedIds.size > 0 ? `${selectedIds.size}件ダウンロード` : 'ダウンロード';
}

// ─── Download ─────────────────────────────────────────────────────────────────

function downloadSelected() {
  const queue = videos.filter(v => selectedIds.has(v.id));
  if (!queue.length) return;
  show('progress-page');
  hide('videos-page');
  startQueue(queue);
}

async function startQueue(queue) {
  downloadControllers = [];
  const list = document.getElementById('progress-list');
  list.innerHTML = queue.map(v => `
    <div class="progress-item">
      <div class="progress-name">${esc(v.filename)}</div>
      <div class="progress-bar-bg">
        <div class="progress-bar-fill" id="bar-${esc(v.id)}" style="width:0%"></div>
      </div>
      <div class="progress-meta">
        <span id="bytes-${esc(v.id)}">待機中…</span>
        <span id="speed-${esc(v.id)}"></span>
      </div>
    </div>
  `).join('');

  for (const v of queue) {
    await downloadOne(v);
  }
}

async function downloadOne(v) {
  const bar    = document.getElementById(`bar-${v.id}`);
  const bytesEl= document.getElementById(`bytes-${v.id}`);
  const speedEl= document.getElementById(`speed-${v.id}`);

  bytesEl.textContent = 'ダウンロード中…';

  const ctrl = new AbortController();
  downloadControllers.push(ctrl);

  try {
    const res = await apiFetch(
      `/api/videos/${encodeURIComponent(v.id)}/download`,
      { signal: ctrl.signal }
    );
    if (!res) { bytesEl.textContent = 'エラー'; return; }

    const total    = parseInt(res.headers.get('Content-Length') || '0', 10);
    const reader   = res.body.getReader();
    const chunks   = [];
    let received   = 0;
    let tStart     = Date.now();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
      const elapsed = (Date.now() - tStart) / 1000 || 0.001;
      const speed   = received / elapsed;
      if (total > 0) {
        bar.style.width = `${(received / total * 100).toFixed(1)}%`;
        bytesEl.textContent = `${fmtSize(received)} / ${fmtSize(total)}`;
      } else {
        // chunked encoding: no total size known
        bytesEl.textContent = `${fmtSize(received)} 受信中…`;
      }
      speedEl.textContent = `${fmtSize(speed)}/s`;
    }

    // Trigger browser Save-As dialog
    const blob = new Blob(chunks);
    const url  = URL.createObjectURL(blob);
    const a    = Object.assign(document.createElement('a'), { href: url, download: v.filename });
    a.click();
    URL.revokeObjectURL(url);

    bar.style.width = '100%';
    bar.classList.add('done');
    bytesEl.textContent = '完了 ✓';
    speedEl.textContent = '';
  } catch (e) {
    if (e.name !== 'AbortError') bytesEl.textContent = 'エラー: ' + e.message;
  }
}

function cancelDownload() {
  downloadControllers.forEach(c => c.abort());
  downloadControllers = [];
  showVideosPage();
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function apiFetch(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: { 'X-Session-Token': sessionToken, ...(opts.headers || {}) }
  });
  if (res.status === 403) { sessionExpired(); return null; }
  return res;
}

function sessionExpired() {
  sessionToken = null;
  document.cookie = 'session=; Max-Age=0; path=/';
  show('auth-page');
  hide('videos-page');
  hide('progress-page');
  document.getElementById('auth-error').textContent = 'セッションが切れました。再度PINを入力してください';
  document.getElementById('auth-error').classList.remove('hidden');
}

function show(id) { document.getElementById(id).classList.remove('hidden'); }
function hide(id) { document.getElementById(id).classList.add('hidden'); }

function esc(str) {
  return String(str)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function fmtDur(s) {
  s = Math.round(s);
  return s < 60 ? `${s}秒` : `${Math.floor(s/60)}分${s%60}秒`;
}

function fmtSize(b) {
  if (b < 1e6) return `${(b/1e3).toFixed(0)} KB`;
  if (b < 1e9) return `${(b/1e6).toFixed(0)} MB`;
  return `${(b/1e9).toFixed(1)} GB`;
}
