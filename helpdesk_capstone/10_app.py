"""
IT Helpdesk web app (application integration for CO4)
  pip install flask pymysql pymongo
  python 10_app.py   ->  http://127.0.0.1:5000
Security: every query is parameterised; the app connects with a LOW-privilege account (agent_aarav / role_agent),
so even a successful injection could not DROP or DELETE data. Writes go through stored procedures only.
"""
from flask import Flask, request, redirect, render_template_string, flash
import pymysql

try:
    from pymongo import MongoClient
    mongo = MongoClient("mongodb://localhost:27017", serverSelectionTimeoutMS=1500).helpdesk_nosql
except Exception:          # MongoDB optional
    mongo = None

app = Flask(__name__)
app.secret_key = "change-me"

DB = dict(host="localhost", user="agent_aarav", password="Agent@1234", database="helpdesk_db",
          cursorclass=pymysql.cursors.DictCursor, autocommit=False)


def conn():
    return pymysql.connect(**DB)


PAGE = """
<!doctype html><title>IT Helpdesk</title>
<style>body{font-family:Segoe UI,Arial;margin:30px;background:#f5f7fa}table{border-collapse:collapse;width:100%;background:#fff}
th,td{padding:8px 10px;border-bottom:1px solid #e1e5ea;text-align:left}th{background:#1f3a5f;color:#fff}
.box{background:#fff;padding:14px;margin-bottom:16px;border-radius:6px}.msg{color:#0a6;font-weight:600}.err{color:#c00;font-weight:600}
input,select,button{padding:6px;margin:3px}a{color:#1f3a5f}</style>
<h2>IT Helpdesk &amp; Incident Management</h2>
<p><a href="/">Open incidents</a> | <a href="/sla">SLA breaches</a> | <a href="/workload">Technician workload</a></p>
{% for cat,m in get_flashed_messages(with_categories=true) %}<p class="{{cat}}">{{m}}</p>{% endfor %}
{{ body|safe }}
"""

TABLE = """
<table><tr>{% for c in cols %}<th>{{c}}</th>{% endfor %}</tr>
{% for r in rows %}<tr>{% for c in cols %}<td>{{r[c]}}</td>{% endfor %}</tr>{% endfor %}</table>
"""


def render(body_tpl, **ctx):
    body = render_template_string(body_tpl, **ctx)
    return render_template_string(PAGE, body=body)


@app.route("/")
def home():
    q = request.args.get("q", "")
    with conn() as c, c.cursor() as cur:
        # parameterised LIKE -> injection-safe
        cur.execute("""SELECT incident_id, ticket_no, title, priority_name, status_name, technician, resolution_due
                       FROM v_open_incidents WHERE title LIKE %s ORDER BY incident_id DESC LIMIT 50""", (f"%{q}%",))
        rows = cur.fetchall()
    form = """<div class="box"><form method="get">Search: <input name="q" value="{{q}}"><button>Go</button></form></div>
    <div class="box"><form method="post" action="/new"><b>New ticket</b>
    Reporter ID <input name="reporter" size="3" value="14"> Title <input name="title" required>
    Category <select name="category"><option value="6">Laptop</option><option value="7">Printer</option><option value="8">VPN</option>
    <option value="9">Wi-Fi</option><option value="10">Password</option><option value="12">Application</option></select>
    Priority <select name="priority"><option value="1">Critical</option><option value="2">High</option>
    <option value="3" selected>Medium</option><option value="4">Low</option></select><button>Create</button></form></div>
    <div class="box"><form method="post" action="/assign"><b>Assign</b> Incident ID <input name="incident" size="4">
    Technician ID <input name="tech" size="3"><button>Assign</button></form></div>"""
    cols = ["incident_id", "ticket_no", "title", "priority_name", "status_name", "technician", "resolution_due"]
    return render(form + TABLE + '<p><a href="/activity/1">Sample MongoDB activity feed (incident 1)</a></p>', q=q, cols=cols, rows=rows)


@app.post("/new")
def new_ticket():
    try:
        with conn() as c, c.cursor() as cur:
            cur.execute("CALL sp_create_incident(%s,%s,%s,%s,%s,@t)",
                        (int(request.form["reporter"]), request.form["title"], "Created from web app",
                         int(request.form["category"]), int(request.form["priority"])))
            cur.execute("SELECT @t AS t")
            flash(f"Ticket created: {cur.fetchone()['t']}", "msg")
            c.commit()
    except Exception as e:
        flash(f"Could not create ticket: {e.args[-1] if e.args else e}", "err")
    return redirect("/")


@app.post("/assign")
def assign():
    try:
        with conn() as c, c.cursor() as cur:
            cur.execute("CALL sp_assign_incident(%s,%s,%s)",
                        (int(request.form["incident"]), int(request.form["tech"]), 1))
            c.commit()
            flash("Incident assigned (history, SLA and escalation rules applied)", "msg")
    except Exception as e:           # e.g. 'Incident already assigned to another technician'
        flash(f"Assignment failed: {e.args[-1] if e.args else e}", "err")
    return redirect("/")


@app.route("/sla")
def sla():
    with conn() as c, c.cursor() as cur:
        cur.execute("SELECT ticket_no, priority_name, resolution_due, resolved_at, minutes_over_sla FROM v_sla_breaches ORDER BY minutes_over_sla DESC LIMIT 50")
        rows = cur.fetchall()
    return render("<h3>SLA breaches</h3>" + TABLE, cols=["ticket_no", "priority_name", "resolution_due", "resolved_at", "minutes_over_sla"], rows=rows)


@app.route("/workload")
def workload():
    with conn() as c, c.cursor() as cur:
        cur.execute("SELECT * FROM v_technician_workload ORDER BY open_tickets DESC")
        rows = cur.fetchall()
    return render("<h3>Technician workload</h3>" + TABLE, cols=["tech_id", "full_name", "team_name", "open_tickets", "resolved_tickets"], rows=rows)


@app.route("/activity/<int:incident_id>")
def activity(incident_id):
    """Semi-structured activity feed comes from MongoDB; core ticket data from MySQL."""
    doc = mongo.incident_activity.find_one({"incident_id": incident_id}, {"_id": 0}) if mongo is not None else None
    rows = [{"type": e.get("type"), "by": e.get("by"), "detail": e.get("text") or e.get("filename") or e.get("tool", ""), "ts": e.get("ts")}
            for e in (doc or {}).get("events", [])]
    return render("<h3>Activity (MongoDB) for incident {{i}}</h3>" + TABLE, i=incident_id, cols=["type", "by", "detail", "ts"], rows=rows)


if __name__ == "__main__":
    app.run(debug=True)
