import os
import sys
import platform
import time
import datetime
import uuid
import random
import logging
import math
import hashlib
from flask import Flask, request, jsonify, render_template_string, redirect

application = Flask(__name__)

# Configure structured logging to stdout (picked up by EB/CloudWatch)
logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s - %(message)s'
)
logger = logging.getLogger('eb-demo')

# ── In-memory state ──────────────────────────────────────────────
kv_store = {}
request_log = []
metrics = {
    'total_requests': 0,
    'errors_triggered': 0,
    'tasks_run': 0,
    'load_tests_run': 0,
    'cpu_burns': 0,
    'total_response_time_ms': 0,
}
start_time = time.time()


# ── Request tracking middleware ──────────────────────────────────
@application.before_request
def before():
    request._start = time.time()
    metrics['total_requests'] += 1


@application.after_request
def after(response):
    elapsed = (time.time() - getattr(request, '_start', time.time())) * 1000
    metrics['total_response_time_ms'] += elapsed
    entry = {
        'id': str(uuid.uuid4())[:8],
        'method': request.method,
        'path': request.path,
        'status': response.status_code,
        'ms': round(elapsed, 1),
        'ip': request.remote_addr,
        'time': datetime.datetime.now(datetime.timezone.utc).strftime('%H:%M:%S'),
    }
    request_log.append(entry)
    if len(request_log) > 200:
        request_log.pop(0)
    logger.info('%(method)s %(path)s %(status)s %(ms).1fms', entry)
    return response


# ── Layout ───────────────────────────────────────────────────────
LAYOUT = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ title }} — EB Demo</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,sans-serif;background:#f4f6f9;color:#333}
    nav{background:#232f3e;padding:.8rem 1.5rem;display:flex;gap:1.2rem;align-items:center;flex-wrap:wrap}
    nav a{color:#f9f9f9;text-decoration:none;font-size:.9rem}
    nav a:hover{text-decoration:underline}
    nav .brand{font-weight:700;font-size:1.05rem;margin-right:auto}
    .container{max-width:960px;margin:1.5rem auto;padding:0 1rem}
    .card{background:#fff;border-radius:8px;padding:1.25rem;margin-bottom:1.25rem;box-shadow:0 1px 3px rgba(0,0,0,.1)}
    .card h2{margin-bottom:.8rem;font-size:1.1rem}
    table{width:100%;border-collapse:collapse}
    th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #eee;font-size:.85rem}
    th{background:#f9fafb;font-weight:600}
    .badge{display:inline-block;padding:.15rem .5rem;border-radius:4px;font-size:.75rem;font-weight:600}
    .bg{background:#d4edda;color:#155724}.bb{background:#d1ecf1;color:#0c5460}
    .br{background:#f8d7da;color:#721c24}.by{background:#fff3cd;color:#856404}
    .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:.8rem;margin-bottom:1rem}
    .stat{background:#fff;border-radius:8px;padding:1rem;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.08)}
    .stat .num{font-size:1.8rem;font-weight:700;color:#232f3e}
    .stat .label{font-size:.8rem;color:#666;margin-top:.2rem}
    .btn{display:inline-block;padding:.5rem 1rem;border:none;border-radius:4px;font-size:.85rem;
         cursor:pointer;text-decoration:none;color:#fff;margin:.25rem}
    .btn-blue{background:#0073bb}.btn-red{background:#d13212}.btn-green{background:#1b7742}
    .btn-orange{background:#ec7211}.btn-gray{background:#545b64}
    .btn:hover{opacity:.85}
    code{background:#eee;padding:.1rem .35rem;border-radius:3px;font-size:.8rem}
    .actions{display:flex;flex-wrap:wrap;gap:.4rem;margin:.5rem 0}
    input,select{padding:.4rem .6rem;border:1px solid #ccc;border-radius:4px;font-size:.85rem}
    #output{background:#1a1a2e;color:#0f0;padding:1rem;border-radius:6px;font-family:monospace;
            font-size:.8rem;max-height:300px;overflow-y:auto;white-space:pre-wrap;margin-top:.8rem}
  </style>
</head>
<body>
  <nav>
    <span class="brand">EB Demo</span>
    <a href="/">Dashboard</a>
    <a href="/actions">Actions</a>
    <a href="/store">Store</a>
    <a href="/logs">Logs</a>
    <a href="/system">System</a>
    <a href="/health">Health</a>
  </nav>
  <div class="container">{{ content }}</div>
</body>
</html>
'''


def render(title, content):
    return render_template_string(LAYOUT, title=title, content=content)


# ── Dashboard ────────────────────────────────────────────────────
@application.route('/')
def index():
    up = int(time.time() - start_time)
    h, r = divmod(up, 3600)
    m, s = divmod(r, 60)
    avg_ms = round(metrics['total_response_time_ms'] / max(metrics['total_requests'], 1), 1)
    env = os.environ.get('ENV_TYPE', 'unknown')
    content = f'''
    <div class="grid">
      <div class="stat"><div class="num">{metrics["total_requests"]}</div><div class="label">Total Requests</div></div>
      <div class="stat"><div class="num">{avg_ms}ms</div><div class="label">Avg Response</div></div>
      <div class="stat"><div class="num">{metrics["errors_triggered"]}</div><div class="label">Errors Triggered</div></div>
      <div class="stat"><div class="num">{metrics["tasks_run"]}</div><div class="label">Tasks Run</div></div>
      <div class="stat"><div class="num">{len(kv_store)}</div><div class="label">KV Entries</div></div>
      <div class="stat"><div class="num">{h}h {m}m {s}s</div><div class="label">Uptime</div></div>
    </div>
    <div class="card">
      <h2>Environment: <span class="badge {"bg" if env=="enhanced" else "bb"}">{env}</span></h2>
      <p style="margin-top:.5rem;font-size:.85rem">
        Quick links:
        <a class="btn btn-blue" href="/actions">Generate Traffic</a>
        <a class="btn btn-orange" href="/store">Key-Value Store</a>
        <a class="btn btn-gray" href="/logs">View Logs</a>
      </p>
    </div>
    '''
    return render('Dashboard', content)


# ── Actions page (the fun part) ─────────────────────────────────
@application.route('/actions')
def actions_page():
    content = '''
    <div class="card">
      <h2>Traffic Generator</h2>
      <p style="font-size:.85rem;margin-bottom:.8rem">Click buttons to generate real HTTP requests, logs, and metrics.</p>
      <div class="actions">
        <button class="btn btn-blue" onclick="fire('/api/action/ping',10)">Ping x10</button>
        <button class="btn btn-blue" onclick="fire('/api/action/ping',50)">Ping x50</button>
        <button class="btn btn-green" onclick="fire('/api/action/compute',5)">Compute x5</button>
        <button class="btn btn-green" onclick="fire('/api/action/compute',20)">Compute x20</button>
        <button class="btn btn-orange" onclick="fire('/api/action/random-data',10)">Random Data x10</button>
        <button class="btn btn-red" onclick="fire('/api/action/error',5)">Errors x5</button>
        <button class="btn btn-red" onclick="fire('/api/action/error',20)">Errors x20</button>
        <button class="btn btn-gray" onclick="fire('/api/action/slow',3)">Slow Requests x3</button>
      </div>
      <div id="output">Ready. Click a button to start generating traffic...</div>
    </div>
    <div class="card">
      <h2>Individual Actions</h2>
      <div class="actions">
        <a class="btn btn-blue" href="/api/action/ping">Single Ping</a>
        <a class="btn btn-green" href="/api/action/compute">Single Compute</a>
        <a class="btn btn-orange" href="/api/action/random-data">Random Data</a>
        <a class="btn btn-red" href="/api/action/error">Trigger Error</a>
        <a class="btn btn-gray" href="/api/action/slow">Slow Request</a>
        <a class="btn btn-red" href="/api/action/warn">Warning Log</a>
        <a class="btn btn-red" href="/api/action/crash">Unhandled Exception</a>
      </div>
    </div>
    <script>
    const out = document.getElementById('output');
    function log(msg) { out.textContent += '\\n' + msg; out.scrollTop = out.scrollHeight; }
    async function fire(url, n) {
      out.textContent = 'Firing ' + n + ' requests to ' + url + '...';
      let ok = 0, fail = 0;
      const start = Date.now();
      const promises = [];
      for (let i = 0; i < n; i++) {
        promises.push(
          fetch(url).then(r => {
            if (r.ok) ok++; else fail++;
            return r.json().catch(() => ({}));
          }).then(d => log('#' + (ok+fail) + ' ' + (d.status||d.error||'done') + ' ' + (d.ms||'') + 'ms'))
            .catch(() => { fail++; log('#' + (ok+fail) + ' network error'); })
        );
        if (i % 10 === 9) await new Promise(r => setTimeout(r, 50));
      }
      await Promise.all(promises);
      log('\\nDone: ' + ok + ' ok, ' + fail + ' failed, ' + (Date.now()-start) + 'ms total');
    }
    </script>
    '''
    return render('Actions', content)


# ── Action API endpoints ─────────────────────────────────────────
@application.route('/api/action/ping')
def action_ping():
    logger.info('PING from %s', request.remote_addr)
    return jsonify({'status': 'pong', 'ms': 0, 'ts': time.time()})


@application.route('/api/action/compute')
def action_compute():
    metrics['tasks_run'] += 1
    t0 = time.time()
    # Do some actual CPU work
    n = random.randint(100000, 500000)
    result = sum(math.sqrt(i) * math.sin(i) for i in range(n))
    h = hashlib.sha256(str(result).encode()).hexdigest()[:16]
    elapsed = round((time.time() - t0) * 1000, 1)
    logger.info('COMPUTE iterations=%d result_hash=%s elapsed=%.1fms', n, h, elapsed)
    return jsonify({'status': 'computed', 'iterations': n, 'hash': h, 'ms': elapsed})


@application.route('/api/action/random-data')
def action_random_data():
    metrics['tasks_run'] += 1
    key = f'auto-{uuid.uuid4().hex[:6]}'
    value = ''.join(random.choices('abcdefghijklmnopqrstuvwxyz0123456789', k=random.randint(8, 64)))
    kv_store[key] = value
    logger.info('RANDOM_DATA key=%s value_len=%d store_size=%d', key, len(value), len(kv_store))
    return jsonify({'status': 'stored', 'key': key, 'value': value, 'store_size': len(kv_store)})


@application.route('/api/action/error')
def action_error():
    metrics['errors_triggered'] += 1
    code = random.choice([400, 403, 404, 409, 422, 500, 502, 503])
    msgs = {
        400: 'Bad request simulation', 403: 'Forbidden simulation',
        404: 'Not found simulation', 409: 'Conflict simulation',
        422: 'Validation failed simulation', 500: 'Internal server error simulation',
        502: 'Bad gateway simulation', 503: 'Service unavailable simulation',
    }
    logger.error('ERROR_SIMULATED code=%d msg=%s errors_total=%d', code, msgs[code], metrics['errors_triggered'])
    return jsonify({'error': msgs[code], 'code': code, 'errors_total': metrics['errors_triggered']}), code


@application.route('/api/action/slow')
def action_slow():
    metrics['tasks_run'] += 1
    delay = round(random.uniform(1.0, 3.0), 2)
    logger.warning('SLOW_REQUEST delay=%.2fs', delay)
    time.sleep(delay)
    logger.info('SLOW_REQUEST completed after %.2fs', delay)
    return jsonify({'status': 'slow_done', 'delay_seconds': delay, 'ms': delay * 1000})


@application.route('/api/action/warn')
def action_warn():
    warnings = [
        'Memory usage approaching threshold',
        'Response time degradation detected',
        'Connection pool nearing capacity',
        'Disk usage above 80 percent',
        'Request queue backing up',
    ]
    msg = random.choice(warnings)
    logger.warning('APP_WARNING msg="%s"', msg)
    return jsonify({'status': 'warning_logged', 'warning': msg})


@application.route('/api/action/crash')
def action_crash():
    metrics['errors_triggered'] += 1
    logger.critical('UNHANDLED_EXCEPTION about to raise')
    raise RuntimeError('Simulated unhandled exception for log generation')


# ── Error handler ────────────────────────────────────────────────
@application.errorhandler(Exception)
def handle_exception(e):
    logger.exception('Unhandled exception: %s', e)
    return jsonify({'error': str(e), 'type': type(e).__name__}), 500


# ── Logs viewer ──────────────────────────────────────────────────
@application.route('/logs')
def logs_page():
    rows = ''.join(
        f'<tr><td>{r["time"]}</td>'
        f'<td><span class="badge bb">{r["method"]}</span></td>'
        f'<td><code>{r["path"]}</code></td>'
        f'<td><span class="badge {"bg" if r["status"]<400 else "br"}">{r["status"]}</span></td>'
        f'<td>{r["ms"]}ms</td><td>{r["ip"]}</td></tr>'
        for r in reversed(request_log)
    )
    content = f'''
    <div class="card">
      <h2>Request Log <span class="badge bg">{len(request_log)} entries</span></h2>
      <p style="font-size:.8rem;margin-bottom:.8rem;color:#666">Auto-refreshes every 3 seconds. Max 200 entries kept.</p>
      <table>
        <tr><th>Time</th><th>Method</th><th>Path</th><th>Status</th><th>Latency</th><th>IP</th></tr>
        {rows}
      </table>
    </div>
    <script>setTimeout(() => location.reload(), 3000);</script>
    '''
    return render('Logs', content)


# ── Metrics endpoint (JSON) ──────────────────────────────────────
@application.route('/metrics')
def metrics_endpoint():
    up = int(time.time() - start_time)
    status_counts = {}
    for r in request_log:
        s = str(r['status'])
        status_counts[s] = status_counts.get(s, 0) + 1
    path_counts = {}
    for r in request_log:
        path_counts[r['path']] = path_counts.get(r['path'], 0) + 1
    top_paths = sorted(path_counts.items(), key=lambda x: -x[1])[:10]
    return jsonify({
        'uptime_seconds': up,
        'totals': metrics,
        'avg_response_ms': round(metrics['total_response_time_ms'] / max(metrics['total_requests'], 1), 1),
        'status_codes': status_counts,
        'top_paths': dict(top_paths),
        'kv_store_size': len(kv_store),
        'request_log_size': len(request_log),
    })


# ── KV Store ─────────────────────────────────────────────────────
@application.route('/store')
def store_ui():
    rows = ''.join(
        f'<tr><td><code>{k}</code></td><td>{v}</td></tr>' for k, v in sorted(kv_store.items())
    ) or '<tr><td colspan="2">No entries yet. Use Actions page to generate some.</td></tr>'
    content = f'''
    <div class="card">
      <h2>Key-Value Store <span class="badge bg">{len(kv_store)} entries</span></h2>
      <form method="POST" action="/api/store">
        <input name="key" placeholder="Key" required aria-label="Key">
        <input name="value" placeholder="Value" required aria-label="Value">
        <button class="btn btn-blue" type="submit">Add</button>
      </form>
      <table><tr><th>Key</th><th>Value</th></tr>{rows}</table>
    </div>
    '''
    return render('Store', content)


@application.route('/api/store', methods=['GET', 'POST', 'DELETE'])
def api_store():
    if request.method == 'GET':
        key = request.args.get('key')
        if key:
            if key in kv_store:
                return jsonify({'key': key, 'value': kv_store[key]})
            return jsonify({'error': 'Key not found'}), 404
        return jsonify(kv_store)
    if request.method == 'POST':
        data = request.form if request.form else request.get_json(silent=True) or {}
        key = data.get('key')
        value = data.get('value')
        if not key or value is None:
            return jsonify({'error': 'key and value required'}), 400
        kv_store[key] = value
        logger.info('KV_STORE_SET key=%s store_size=%d', key, len(kv_store))
        if request.form:
            return redirect('/store')
        return jsonify({'key': key, 'value': value}), 201
    if request.method == 'DELETE':
        data = request.get_json(silent=True) or {}
        key = data.get('key') or request.args.get('key')
        if not key:
            return jsonify({'error': 'key required'}), 400
        if key in kv_store:
            del kv_store[key]
            logger.info('KV_STORE_DELETE key=%s store_size=%d', key, len(kv_store))
            return jsonify({'deleted': key})
        return jsonify({'error': 'Key not found'}), 404


# ── System info ──────────────────────────────────────────────────
@application.route('/system')
def system_info():
    env_vars = {k: v for k, v in sorted(os.environ.items()) if not k.startswith('AWS_SECRET')}
    env_rows = ''.join(f'<tr><td><code>{k}</code></td><td>{v}</td></tr>' for k, v in env_vars.items())
    content = f'''
    <div class="card">
      <h2>System</h2>
      <table>
        <tr><th>Hostname</th><td>{platform.node()}</td></tr>
        <tr><th>Platform</th><td>{platform.platform()}</td></tr>
        <tr><th>Python</th><td>{platform.python_version()}</td></tr>
        <tr><th>Arch</th><td>{platform.machine()}</td></tr>
        <tr><th>PID</th><td>{os.getpid()}</td></tr>
      </table>
    </div>
    <div class="card">
      <h2>Environment Variables</h2>
      <table><tr><th>Key</th><th>Value</th></tr>{env_rows}</table>
    </div>
    '''
    return render('System', content)


# ── Health ───────────────────────────────────────────────────────
@application.route('/health')
def health():
    return jsonify({
        'status': 'healthy',
        'uptime_seconds': int(time.time() - start_time),
        'total_requests': metrics['total_requests'],
        'errors_triggered': metrics['errors_triggered'],
    })


if __name__ == '__main__':
    application.run(host='0.0.0.0', port=8080)
