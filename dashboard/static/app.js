/* ============================================================
   BeamMP Server Admin — app logic
   Vanilla JS. No frameworks, no external deps.
   ============================================================ */
(function () {
  'use strict';

  /* ---------- tiny DOM helper ---------- */
  function $(id) { return document.getElementById(id); }

  var el = {
    // login
    loginScreen: $('login-screen'),
    loginForm: $('login-form'),
    loginPassword: $('login-password'),
    loginError: $('login-error'),
    loginBtn: $('login-btn'),

    // shell
    app: $('app'),
    headerServerName: $('header-server-name'),
    headerOnline: $('header-online'),
    btnLogout: $('btn-logout'),
    errorBanner: $('error-banner'),
    errorText: $('error-banner-text'),
    errorClose: $('error-banner-close'),
    restartBanner: $('restart-banner'),

    // status
    statusBadge: $('status-badge'),
    statusText: $('status-text'),
    statusName: $('status-name'),
    statusDescription: $('status-description'),
    statusMap: $('status-map'),
    statusPlayers: $('status-players'),
    statusUptime: $('status-uptime'),
    statusVersion: $('status-version'),
    playerTableBody: $('player-table-body'),
    statusLogLines: $('status-log-lines'),
    btnRestart: $('btn-restart'),

    // console
    consoleStatus: $('console-status'),
    consoleStatusText: $('console-status-text'),
    consoleLog: $('console-log'),
    consoleForm: $('console-form'),
    consoleInput: $('console-input'),
    consoleSend: $('console-send'),

    // mods
    modsTableBody: $('mods-table-body'),
    modsFile: $('mods-file'),
    btnUpload: $('btn-upload'),
    uploadProgress: $('upload-progress'),

    // config
    configForm: $('config-form'),
    configMessage: $('config-message'),
    configRestartBtn: $('config-restart-btn'),
    cfgName: $('cfg-name'),
    cfgDescription: $('cfg-description'),
    cfgTags: $('cfg-tags'),
    cfgMaxPlayers: $('cfg-maxPlayers'),
    cfgMaxCars: $('cfg-maxCars'),
    cfgMap: $('cfg-map'),
    cfgMapCustom: $('cfg-map-custom'),
    cfgPrivate: $('cfg-private'),
    cfgAllowGuests: $('cfg-allowGuests'),
    cfgLogChat: $('cfg-logChat'),
    saveConfigBtn: $('save-config-btn')
  };

  /* ---------- helpers ---------- */

  var ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) { return ESC[c]; });
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function stripAnsi(s) {
    return String(s).replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '');
  }

  function fmtSize(bytes) {
    var n = Number(bytes);
    if (bytes == null || !isFinite(n) || n < 0) return '\u2014';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(2) + ' MB';
  }

  function fmtTime(s) {
    if (!s) return '\u2014';
    var t = Date.parse(s);
    if (isNaN(t)) return String(s);
    return new Date(t).toLocaleString();
  }

  function fmtUptime(sec) {
    if (sec == null) return '\u2014';
    var s = Math.floor(sec);
    var d = Math.floor(s / 86400); s -= d * 86400;
    var h = Math.floor(s / 3600);  s -= h * 3600;
    var m = Math.floor(s / 60);    s -= m * 60;
    if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
    if (h > 0) return h + 'h ' + m + 'm ' + s + 's';
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
  }

  /* ---------- state ---------- */
  var authFailed = false;   // true while login screen is showing
  var refreshPaused = false; // true during server restart
  var statusTimer = null;
  var logTimer = null;
  var errorTimer = null;

  /* ---------- API client ---------- */

  // Every request funnels through here so 401 anywhere flips to login.
  function api(path, options) {
    return fetch(path, options).then(function (res) {
      if (res.status === 401) {
        var msg = 'Session expired \u2014 please sign in.';
        return res.json().then(function (data) {
          if (data && data.error) msg = data.error;
          showLogin(msg);
          var err = new Error(msg);
          err.kind = 'auth';
          throw err;
        });
      }
      return res.json().then(function (data) {
        if (!res.ok) {
          var e = new Error((data && data.error) ? data.error : ('Request failed (HTTP ' + res.status + ')'));
          e.kind = 'http';
          e.status = res.status;
          throw e;
        }
        return data;
      });
    }).catch(function (err) {
      if (err && err.kind) throw err;
      var e = new Error('Cannot reach server. Is it running?');
      e.kind = 'network';
      throw e;
    });
  }

  /* ---------- error banner ---------- */

  function showError(msg) {
    el.errorText.textContent = msg;
    el.errorBanner.classList.remove('hidden');
    clearTimeout(errorTimer);
    errorTimer = setTimeout(hideError, 6000);
  }

  function hideError() {
    el.errorBanner.classList.add('hidden');
  }

  el.errorClose.addEventListener('click', hideError);

  /* ---------- login / logout ---------- */

  function showLogin(message) {
    authFailed = true;
    stopPolling();
    el.loginScreen.classList.remove('hidden');
    el.app.classList.add('hidden');
    if (message) {
      el.loginError.textContent = message;
      el.loginError.classList.remove('hidden');
    }
    el.loginPassword.focus();
  }

  function showApp() {
    authFailed = false;
    el.loginScreen.classList.add('hidden');
    el.app.classList.remove('hidden');
    el.loginError.classList.add('hidden');
    el.loginPassword.value = '';
    loadAll();
    startPolling();
  }

  el.loginForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var pw = el.loginPassword.value;
    el.loginBtn.disabled = true;
    el.loginBtn.textContent = 'Signing in\u2026';
    el.loginError.classList.add('hidden');
    api('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: pw })
    }).then(function () {
      showApp();
    }).catch(function (err) {
      if (err.kind !== 'auth') {
        el.loginError.textContent = err.message || 'Invalid password.';
        el.loginError.classList.remove('hidden');
      }
    }).then(function () {
      el.loginBtn.disabled = false;
      el.loginBtn.textContent = 'Sign in';
    });
  });

  el.btnLogout.addEventListener('click', function () {
    api('/api/logout', { method: 'POST' }).catch(function () { /* log out locally regardless */ });
    showLogin();
  });

  /* ---------- polling ---------- */

  function startPolling() {
    stopPolling();
    refreshStatus();
    refreshConsoleLog();
    statusTimer = setInterval(function () {
      if (!refreshPaused) refreshStatus();
    }, 5000);
    logTimer = setInterval(function () {
      if (!refreshPaused) refreshConsoleLog();
    }, 3000);
  }

  function stopPolling() {
    clearInterval(statusTimer);
    clearInterval(logTimer);
    statusTimer = null;
    logTimer = null;
  }

  function loadAll() {
    refreshStatus();
    refreshConsoleLog();
    loadMods();
    loadConfig();
  }

  /* ---------- status ---------- */

  function setOnlineIndicator(on) {
    el.statusBadge.classList.toggle('online', on);
    el.statusBadge.classList.toggle('offline', !on);
    el.statusText.textContent = on ? 'ONLINE' : 'OFFLINE';
    el.headerOnline.classList.toggle('online', on);
    el.headerOnline.classList.toggle('offline', !on);
    el.consoleStatus.classList.toggle('online', on);
    el.consoleStatus.classList.toggle('offline', !on);
    el.consoleStatusText.textContent = on ? 'ONLINE' : 'OFFLINE';
  }

  function refreshStatus() {
    api('/api/status').then(function (data) {
      renderStatus(data);
    }).catch(function (err) {
      if (err.kind === 'auth') return; // login screen already shown
      showError(err.message);
      setOnlineIndicator(false);
    });
  }

  function renderStatus(data) {
    setOnlineIndicator(!!data.online);
    el.headerServerName.textContent = data.name || '\u2014';
    el.statusName.textContent = data.name || '\u2014';
    el.statusDescription.textContent = data.description || '\u2014';
    el.statusMap.textContent = data.map || '\u2014';
    el.statusPlayers.textContent =
      (data.playerCount == null ? '?' : data.playerCount) + ' / ' +
      (data.maxPlayers == null ? '?' : data.maxPlayers);
    el.statusUptime.textContent = fmtUptime(data.uptimeSec);
    el.statusVersion.textContent = data.version || '\u2014';
    renderPlayers(data.players || []);
    renderLog(el.statusLogLines, data.logLines, 20);
  }

  function renderPlayers(players) {
    if (!players.length) {
      el.playerTableBody.innerHTML = '<tr class="empty-row"><td colspan="3">No players online.</td></tr>';
      return;
    }
    el.playerTableBody.innerHTML = players.map(function (p) {
      return '<tr>' +
        '<td class="mono">' + esc(p.name) + '</td>' +
        '<td class="mono muted">' + esc(p.id) + '</td>' +
        '<td class="mono muted">' + esc(fmtTime(p.joinTime)) + '</td>' +
        '</tr>';
    }).join('');
  }

  function renderLog(container, lines, max) {
    var list = (lines || []).slice(-(max == null ? Infinity : max));
    if (!list.length) {
      container.innerHTML = '<div class="log-line log-empty">\u2014 no log output \u2014</div>';
      return;
    }
    container.innerHTML = list.map(function (line) {
      return '<div class="log-line">' + esc(stripAnsi(line)) + '</div>';
    }).join('');
    container.scrollTop = container.scrollHeight;
  }

  /* ---------- console ---------- */

  function refreshConsoleLog() {
    api('/api/status').then(function (data) {
      setOnlineIndicator(!!data.online);
      renderLog(el.consoleLog, data.logLines);
    }).catch(function (err) {
      if (err.kind === 'auth') return;
      showError(err.message);
      setOnlineIndicator(false);
    });
  }

  el.consoleForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var cmd = el.consoleInput.value.trim();
    if (!cmd) return;
    el.consoleSend.disabled = true;
    api('/api/console', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: cmd })
    }).then(function () {
      el.consoleInput.value = '';
      refreshConsoleLog();
    }).catch(function (err) {
      if (err.kind !== 'auth') showError(err.message);
    }).then(function () {
      el.consoleSend.disabled = false;
      el.consoleInput.focus();
    });
  });

  /* ---------- restart ---------- */

  el.btnRestart.addEventListener('click', doRestart);
  el.configRestartBtn.addEventListener('click', doRestart);

  function doRestart() {
    if (!confirm('Restart the server? Players will be disconnected for ~15\u201330 seconds.')) return;
    api('/api/restart', { method: 'POST' }).then(function () {
      refreshPaused = true;
      el.restartBanner.classList.remove('hidden');
      el.btnRestart.disabled = true;
      setOnlineIndicator(false);
      pollDuringRestart();
    }).catch(function (err) {
      if (err.kind !== 'auth') showError(err.message);
    });
  }

  function pollDuringRestart() {
    var attempts = 0;
    (function tick() {
      if (authFailed) return;
      attempts += 1;
      sleep(2000).then(function () {
        return fetch('/api/status');
      }).then(function (res) {
        if (authFailed) return;
        if (res.status === 401) { showLogin(); return; }
        if (res.ok) {
          refreshPaused = false;
          el.restartBanner.classList.add('hidden');
          el.btnRestart.disabled = false;
          refreshStatus();
          refreshConsoleLog();
          return;
        }
        // still down — keep polling (up to ~60s)
        if (attempts < 30) tick();
        else finishRestartWait(false);
      }).catch(function () {
        if (authFailed) return;
        if (attempts < 30) tick();
        else finishRestartWait(false);
      });
    })();
  }

  function finishRestartWait(ok) {
    refreshPaused = false;
    el.restartBanner.classList.add('hidden');
    el.btnRestart.disabled = false;
    if (!ok) showError('Server did not come back in time. It may still be starting up.');
  }

  /* ---------- mods ---------- */

  function loadMods() {
    api('/api/mods').then(function (data) {
      renderMods(data.mods || []);
    }).catch(function (err) {
      if (err.kind !== 'auth') showError(err.message);
    });
  }

  function renderMods(mods) {
    if (!mods.length) {
      el.modsTableBody.innerHTML = '<tr class="empty-row"><td colspan="4">No mods installed.</td></tr>';
      return;
    }
    el.modsTableBody.innerHTML = mods.map(function (m) {
      return '<tr>' +
        '<td class="mono">' + esc(m.name) + '</td>' +
        '<td class="mono muted">' + fmtSize(m.size) + '</td>' +
        '<td class="mono muted">' + esc(fmtTime(m.modified)) + '</td>' +
        '<td class="row-actions">' +
        '<button type="button" class="btn btn-danger btn-sm" data-del="' + esc(m.name) + '">Delete</button>' +
        '</td>' +
        '</tr>';
    }).join('');
  }

  el.modsTableBody.addEventListener('click', function (e) {
    var btn = e.target.closest('button[data-del]');
    if (!btn) return;
    deleteMod(btn.getAttribute('data-del'));
  });

  function deleteMod(name) {
    if (!confirm('Delete mod "' + name + '"?')) return;
    api('/api/mods?name=' + encodeURIComponent(name), { method: 'DELETE' }).then(function () {
      loadMods();
    }).catch(function (err) {
      if (err.kind !== 'auth') showError(err.message);
    });
  }

  el.btnUpload.addEventListener('click', function () {
    var file = el.modsFile.files[0];
    if (!file) {
      showError('Choose a .zip file first.');
      return;
    }
    uploadMod(file);
  });

  function uploadMod(file) {
    var fd = new FormData();
    fd.append('file', file);
    el.btnUpload.disabled = true;
    el.modsFile.disabled = true;
    el.uploadProgress.textContent = 'Uploading 0%';

    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/mods');
    xhr.upload.onprogress = function (e) {
      if (e.lengthComputable) {
        el.uploadProgress.textContent = 'Uploading ' + Math.round((e.loaded / e.total) * 100) + '%';
      }
    };
    xhr.onload = function () {
      el.btnUpload.disabled = false;
      el.modsFile.disabled = false;
      if (xhr.status === 401) { showLogin(); return; }
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (err) { /* ignore */ }
      if (xhr.status >= 200 && xhr.status < 300) {
        var name = (data && data.name) ? data.name : file.name;
        el.uploadProgress.textContent = 'Uploaded ' + name + ' \u2014 done.';
        el.modsFile.value = '';
        loadMods();
      } else {
        el.uploadProgress.textContent = 'Upload failed: ' + ((data && data.error) || ('HTTP ' + xhr.status));
      }
    };
    xhr.onerror = function () {
      el.btnUpload.disabled = false;
      el.modsFile.disabled = false;
      el.uploadProgress.textContent = 'Upload failed: cannot reach server.';
    };
    xhr.send(fd);
  }

  /* ---------- config ---------- */

  function loadConfig() {
    api('/api/config').then(function (cfg) {
      fillConfig(cfg);
      return api('/api/maps');
    }).then(function (mapsData) {
      renderMapOptions(mapsData.maps || []);
      // re-apply select match after options exist
      var cfgMap = el.cfgMapCustom.value;
      var matches = Array.prototype.some.call(el.cfgMap.options, function (o) { return o.value === cfgMap; });
      el.cfgMap.value = matches ? cfgMap : '';
    }).catch(function (err) {
      if (err.kind !== 'auth') showError(err.message);
    });
  }

  function renderMapOptions(maps) {
    el.cfgMap.innerHTML = '<option value="">Custom map\u2026</option>' +
      maps.map(function (m) {
        return '<option value="' + esc(m.path) + '">' + esc(m.label) + '</option>';
      }).join('');
  }

  function fillConfig(cfg) {
    el.cfgName.value = cfg.name || '';
    el.cfgDescription.value = cfg.description || '';
    el.cfgTags.value = cfg.tags || '';
    el.cfgMaxPlayers.value = (cfg.maxPlayers == null) ? '' : cfg.maxPlayers;
    el.cfgMaxCars.value = (cfg.maxCars == null) ? '' : cfg.maxCars;
    el.cfgMapCustom.value = cfg.map || '';
    el.cfgMap.value = '';
    el.cfgPrivate.checked = !!cfg.private;
    el.cfgAllowGuests.checked = !!cfg.allowGuests;
    el.cfgLogChat.checked = !!cfg.logChat;
  }

  el.cfgMap.addEventListener('change', function () {
    if (el.cfgMap.value) el.cfgMapCustom.value = el.cfgMap.value;
  });

  el.configForm.addEventListener('submit', function (e) {
    e.preventDefault();
    var body = {
      name: el.cfgName.value.trim(),
      description: el.cfgDescription.value.trim(),
      tags: el.cfgTags.value.trim(),
      maxPlayers: parseInt(el.cfgMaxPlayers.value, 10) || 0,
      maxCars: parseInt(el.cfgMaxCars.value, 10) || 0,
      map: el.cfgMapCustom.value.trim(),
      private: el.cfgPrivate.checked,
      allowGuests: el.cfgAllowGuests.checked,
      logChat: el.cfgLogChat.checked
    };
    el.saveConfigBtn.disabled = true;
    el.saveConfigBtn.textContent = 'Saving\u2026';
    api('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }).then(function () {
      el.configMessage.classList.remove('hidden');
    }).catch(function (err) {
      if (err.kind !== 'auth') showError(err.message);
    }).then(function () {
      el.saveConfigBtn.disabled = false;
      el.saveConfigBtn.textContent = 'Save config';
    });
  });

  /* ---------- tabs ---------- */

  function switchTab(name) {
    var tabs = document.querySelectorAll('.tab');
    var panels = document.querySelectorAll('.panel');
    for (var i = 0; i < tabs.length; i++) {
      tabs[i].classList.toggle('active', tabs[i].getAttribute('data-tab') === name);
    }
    for (var j = 0; j < panels.length; j++) {
      panels[j].classList.toggle('active', panels[j].id === 'panel-' + name);
    }
    // refresh tab content on demand
    if (name === 'mods') loadMods();
    if (name === 'config') loadConfig();
    if (name === 'status') refreshStatus();
    if (name === 'console') refreshConsoleLog();
  }

  var tabBtns = document.querySelectorAll('.tab');
  for (var k = 0; k < tabBtns.length; k++) {
    tabBtns[k].addEventListener('click', function () {
      switchTab(this.getAttribute('data-tab'));
    });
  }

  /* ---------- bootstrap ---------- */

  function bootstrap() {
    api('/api/status').then(function () {
      showApp();
    }).catch(function (err) {
      if (err.kind === 'auth') return; // login already shown
      // Server unreachable — still show the shell so the user sees an
      // OFFLINE dashboard and can retry / sign in later.
      showApp();
      showError(err.message);
    });
  }

  bootstrap();
})();
