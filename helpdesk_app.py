"""
IT Helpdesk - small web software (Flask + MySQL + optional MongoDB)
Run:  pip install flask pymysql pymongo   ->   python helpdesk_app.py   ->  http://127.0.0.1:5000
Connects as agent_aarav (role_agent) -> writes ONLY via stored procedures, all queries parameterised.
"""
from flask import Flask, request, redirect, render_template_string, flash
import pymysql

try:
    from pymongo import MongoClient
    mongo = MongoClient("mongodb://localhost:27017", serverSelectionTimeoutMS=1200).helpdesk_nosql
except Exception:
    mongo = None

app = Flask(__name__)
app.secret_key = "dev-key"
DB = dict(host="localhost", user="agent_aarav", password="Agent@1234", database="helpdesk_db",
          cursorclass=pymysql.cursors.DictCursor)
STATUS = {1: "New", 2: "Assigned", 3: "In Progress", 4: "Escalated", 5: "Resolved", 6: "Closed"}
PRIO = {1: "Critical", 2: "High", 3: "Medium", 4: "Low"}
CATS = {6: "Laptop", 7: "Printer", 8: "VPN", 9: "Wi-Fi", 10: "Password", 11: "Malware/Phishing", 12: "Application"}
CODES = ["Fixed", "Workaround", "Replaced Hardware", "User Training", "Config Change"]


def run(sql, args=(), write=False):
    c = pymysql.connect(**DB)
    try:
        with c.cursor() as cur:
            cur.execute(sql, args)
            rows = cur.fetchall()
        if write:
            c.commit()
        return rows
    finally:
        c.close()


def action(fn, ok_msg):
    try:
        out = fn()
        flash(ok_msg if out is None else f"{ok_msg} {out}", "ok")
    except Exception as e:
        flash(str(e.args[-1] if e.args else e), "err")


BASE = """
<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>IT Helpdesk</title>
<style>
:root{--bg:#f4f6fa;--card:#fff;--tx:#1d2733;--pri:#1f3a5f;--bd:#e1e5ea}
@media(prefers-color-scheme:dark){:root{--bg:#12161c;--card:#1c232c;--tx:#e6ebf1;--pri:#4a79b5;--bd:#2b3441}}
body{font-family:system-ui,Segoe UI,Arial;margin:0;background:var(--bg);color:var(--tx)}
nav{background:var(--pri);padding:12px 24px}nav a{color:#fff;margin-right:18px;text-decoration:none;font-weight:600}
main{padding:20px 24px;max-width:1200px;margin:auto}
.card{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:14px;margin-bottom:16px}
.stats{display:flex;gap:12px;flex-wrap:wrap}.stat{flex:1;min-width:110px;text-align:center}.stat b{font-size:26px;display:block}
table{border-collapse:collapse;width:100%}th,td{padding:8px;border-bottom:1px solid var(--bd);text-align:left;font-size:14px}
th{background:var(--pri);color:#fff}input,select,button,textarea{padding:6px;margin:3px;border-radius:5px;border:1px solid var(--bd);background:var(--card);color:var(--tx)}
button{background:var(--pri);color:#fff;border:0;cursor:pointer}.ok{color:#0a8a4a;font-weight:600}.err{color:#d33;font-weight:600}
.tag{padding:2px 8px;border-radius:10px;background:var(--bd);font-size:12px}a{color:var(--pri)}
</style>
<nav><a href="/">Dashboard</a><a href="/sla">SLA breaches</a><a href="/workload">Workload</a></nav>
<main>{% for c,m in get_flashed_messages(with_categories=true) %}<p class="{{c}}">{{m}}</p>{% endfor %}
{% block body %}{% endblock %}</main>
"""

HOME = BASE.replace("{% block body %}{% endblock %}", """
<div class="card stats">{% for k,v in stats %}<div class="stat"><b>{{v}}</b>{{k}}</div>{% endfor %}</div>
<div class="card"><b>New ticket</b>
<form method="post" action="/new">Reporter ID <input name="reporter" value="14" size="3">
Title <input name="title" required>
Category <select name="category">{% for k,v in cats.items() %}<option value="{{k}}">{{v}}</option>{% endfor %}</select>
Priority <select name="priority">{% for k,v in prio.items() %}<option value="{{k}}" {{'selected' if k==3}}>{{v}}</option>{% endfor %}</select>
<button>Create</button></form></div>
<div class="card"><form method="get">Search title: <input name="q" value="{{q}}"><button>Go</button></form>
<table><tr><th>ID</th><th>Ticket</th><th>Title</th><th>Priority</th><th>Status</th><th>Technician</th><th>SLA due</th></tr>
{% for r in rows %}<tr><td>{{r.incident_id}}</td><td><a href="/ticket/{{r.incident_id}}">{{r.ticket_no}}</a></td><td>{{r.title}}</td>
<td><span class="tag">{{r.priority_name}}</span></td><td>{{r.status_name}}</td><td>{{r.technician or '-'}}</td>
<td>{{r.resolution_due}}</td></tr>{% endfor %}</table></div>""")

TICKET = BASE.replace("{% block body %}{% endblock %}", """
<div class="card"><h3>{{t.ticket_no}} - {{t.title}}</h3>
<p>Status: <b>{{status[t.status_id]}}</b> | Priority: <b>{{prio[t.priority_id]}}</b> | Technician ID: <b>{{t.assigned_tech_id or '-'}}</b>
| Created: {{t.created_at}} | Resolved: {{t.resolved_at or '-'}}</p><p>{{t.description}}</p>
{% if t.status_id < 5 %}
<form method="post" action="/assign" style="display:inline"><input type="hidden" name="incident" value="{{t.incident_id}}">
Tech ID <input name="tech" size="3" required><button>Assign</button></form>
<form method="post" action="/escalate" style="display:inline"><input type="hidden" name="incident" value="{{t.incident_id}}">
<input name="reason" placeholder="Reason" required><button>Escalate</button></form>
{% if t.assigned_tech_id %}<form method="post" action="/resolve"><input type="hidden" name="incident" value="{{t.incident_id}}">
<input name="text" placeholder="Resolution notes" size="40" required>
<select name="code">{% for c in codes %}<option>{{c}}</option>{% endfor %}</select><button>Resolve</button></form>{% endif %}
{% endif %}</div>
<div class="card"><b>History (MySQL)</b><table><tr><th>When</th><th>From</th><th>To</th><th>Tech</th><th>Note</th></tr>
{% for h in hist %}<tr><td>{{h.changed_at}}</td><td>{{status.get(h.old_status_id,'-')}}</td><td>{{status[h.new_status_id]}}</td>
<td>{{h.new_tech_id or '-'}}</td><td>{{h.change_note}}</td></tr>{% endfor %}</table></div>
<div class="card"><b>Activity feed (MongoDB)</b>{% if events %}<table><tr><th>Type</th><th>By</th><th>Detail</th><th>Time</th></tr>
{% for e in events %}<tr><td>{{e.get('type')}}</td><td>{{e.get('by')}}</td><td>{{e.get('text') or e.get('filename') or e.get('tool','')}}</td><td>{{e.get('ts')}}</td></tr>{% endfor %}</table>
{% else %}<p>No activity (or MongoDB not running).</p>{% endif %}</div>""")

TABLE = BASE.replace("{% block body %}{% endblock %}", """
<div class="card"><h3>{{title}}</h3><table><tr>{% for c in cols %}<th>{{c}}</th>{% endfor %}</tr>
{% for r in rows %}<tr>{% for c in cols %}<td>{{r[c]}}</td>{% endfor %}</tr>{% endfor %}</table></div>""")


@app.route("/")
def home():
    q = request.args.get("q", "")
    rows = run("""SELECT incident_id, ticket_no, title, priority_name, status_name, technician, resolution_due
                  FROM v_open_incidents WHERE title LIKE %s ORDER BY incident_id DESC LIMIT 100""", (f"%{q}%",))
    counts = {r["status_id"]: r["n"] for r in run("SELECT status_id, COUNT(*) n FROM incident GROUP BY status_id")}
    stats = [(STATUS[k], counts.get(k, 0)) for k in STATUS]
    return render_template_string(HOME, rows=rows, stats=stats, q=q, cats=CATS, prio=PRIO)


@app.route("/ticket/<int:iid>")
def ticket(iid):
    t = run("SELECT * FROM incident WHERE incident_id=%s", (iid,))
    if not t:
        flash("Ticket not found", "err")
        return redirect("/")
    hist = run("SELECT * FROM incident_history WHERE incident_id=%s ORDER BY history_id", (iid,))
    doc = mongo.incident_activity.find_one({"incident_id": iid}, {"_id": 0}) if mongo is not None else None
    return render_template_string(TICKET, t=t[0], hist=hist, events=(doc or {}).get("events", []),
                                  status=STATUS, prio=PRIO, codes=CODES)


@app.post("/new")
def new():
    def go():
        c = pymysql.connect(**DB)
        try:
            with c.cursor() as cur:
                cur.execute("CALL sp_create_incident(%s,%s,%s,%s,%s,@t)",
                            (int(request.form["reporter"]), request.form["title"], "Created from web app",
                             int(request.form["category"]), int(request.form["priority"])))
                cur.execute("SELECT @t AS t")
                t = cur.fetchone()["t"]
            c.commit()
            return t
        finally:
            c.close()
    action(go, "Ticket created:")
    return redirect("/")


@app.post("/assign")
def assign():
    iid = int(request.form["incident"])
    action(lambda: run("CALL sp_assign_incident(%s,%s,%s)", (iid, int(request.form["tech"]), 1), write=True),
           "Assigned (SLA/escalation rules applied).")
    return redirect(f"/ticket/{iid}")


@app.post("/resolve")
def resolve():
    iid = int(request.form["incident"])
    def go():
        tech = run("SELECT assigned_tech_id FROM incident WHERE incident_id=%s", (iid,))[0]["assigned_tech_id"]
        run("CALL sp_resolve_incident(%s,%s,%s,%s,%s)", (iid, tech, request.form["text"], request.form["code"], 1), write=True)
    action(go, "Incident resolved.")
    return redirect(f"/ticket/{iid}")


@app.post("/escalate")
def escalate():
    iid = int(request.form["incident"])
    action(lambda: run("CALL sp_escalate_incident(%s,%s)", (iid, request.form["reason"]), write=True), "Escalated to Tier-2.")
    return redirect(f"/ticket/{iid}")


@app.route("/sla")
def sla():
    rows = run("SELECT ticket_no, priority_name, resolution_due, resolved_at, minutes_over_sla FROM v_sla_breaches ORDER BY minutes_over_sla DESC LIMIT 100")
    return render_template_string(TABLE, title="SLA breaches", rows=rows,
                                  cols=["ticket_no", "priority_name", "resolution_due", "resolved_at", "minutes_over_sla"])


@app.route("/workload")
def workload():
    rows = run("SELECT * FROM v_technician_workload ORDER BY open_tickets DESC")
    return render_template_string(TABLE, title="Technician workload", rows=rows,
                                  cols=["tech_id", "full_name", "team_name", "open_tickets", "resolved_tickets"])


if __name__ == "__main__":
    app.run(debug=True)
