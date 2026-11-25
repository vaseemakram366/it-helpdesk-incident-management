// =====================================================================
// File 09 : CO4 NoSQL EXTENSION - MongoDB (run in mongosh or MongoDB Compass > _MONGOSH)
//   mongosh < 09_mongodb_extension.js        (or paste block by block and screenshot)
// WHY MongoDB?  Core ticket data (status, SLA, assignment) needs ACID + joins -> stays in MySQL.
// Ticket *conversation/activity* is semi-structured: every ticket has different events
// (comments, attachments, chat transcripts, remote-session logs) -> flexible documents.
// Link between the two worlds: incident_id / ticket_no.
// =====================================================================
use helpdesk_nosql;
db.incident_activity.drop();
db.kb_articles.drop();

// ---------------- 1. CREATE (insertMany) ----------------
db.incident_activity.insertMany([
  { incident_id: 1, ticket_no: "INC-2026-00001", priority: "Critical", category: "Network", tags: ["vpn","outage"],
    events: [
      { type: "comment",    by: "agent_aarav", text: "Checking VPN gateway logs",          ts: ISODate("2026-11-10T09:05:00Z") },
      { type: "attachment", by: "pooja.gupta14", filename: "vpn_error.png", size_kb: 245,   ts: ISODate("2026-11-10T09:07:00Z") },
      { type: "comment",    by: "agent_aarav", text: "Gateway memory at 98%, restarting",   ts: ISODate("2026-11-10T09:20:00Z") } ] },
  { incident_id: 2, ticket_no: "INC-2026-00002", priority: "High", category: "Hardware", tags: ["laptop","battery"],
    events: [
      { type: "comment", by: "agent_priya", text: "Battery health 41%", ts: ISODate("2026-11-09T11:00:00Z") },
      { type: "remote_session", by: "agent_priya", duration_min: 18, tool: "AnyDesk", ts: ISODate("2026-11-09T11:30:00Z") } ] },
  { incident_id: 3, ticket_no: "INC-2026-00003", priority: "Medium", category: "Software", tags: ["erp","timeout"],
    events: [
      { type: "chat", by: "user", transcript: ["ERP is slow", "Which report?", "Month-end sales"], ts: ISODate("2026-11-08T14:00:00Z") },
      { type: "comment", by: "agent_karan", text: "Linked to Problem #5", ts: ISODate("2026-11-08T14:10:00Z") },
      { type: "attachment", by: "agent_karan", filename: "slow_query.sql", size_kb: 4, ts: ISODate("2026-11-08T14:12:00Z") } ] },
  { incident_id: 4, ticket_no: "INC-2026-00004", priority: "Low", category: "Access", tags: ["password"],
    events: [ { type: "comment", by: "agent_meera", text: "Password reset link sent", ts: ISODate("2026-11-07T10:00:00Z") } ] },
  { incident_id: 5, ticket_no: "INC-2026-00005", priority: "High", category: "Network", tags: ["wifi","floor3"],
    events: [
      { type: "comment", by: "agent_arjun", text: "AP-3F-02 rebooting", ts: ISODate("2026-11-06T08:00:00Z") },
      { type: "comment", by: "agent_arjun", text: "Firmware upgrade scheduled", ts: ISODate("2026-11-06T08:30:00Z") } ] },
  { incident_id: 6, ticket_no: "INC-2026-00006", priority: "Critical", category: "Security", tags: ["phishing","email"],
    events: [
      { type: "comment", by: "agent_diya", text: "Sender domain blocked", ts: ISODate("2026-11-05T07:00:00Z") },
      { type: "attachment", by: "pooja.gupta14", filename: "phish.eml", size_kb: 33, ts: ISODate("2026-11-05T06:50:00Z") } ] }
]);

db.kb_articles.insertMany([
  { kb_id: "KB-001", title: "Fix VPN disconnects",            tags: ["vpn"],      steps: ["Update client","Restart gateway","Check MTU"], helpful_votes: 42 },
  { kb_id: "KB-002", title: "Replace swollen laptop battery", tags: ["battery"],  steps: ["Power off","Remove battery","Raise asset replacement"], helpful_votes: 17 },
  { kb_id: "KB-003", title: "Reset a locked account",         tags: ["password"], steps: ["Verify identity","Unlock in AD","Force reset"], helpful_votes: 65 }
]);

// ---------------- 2. READ ----------------
db.incident_activity.find({ priority: "Critical" }, { _id: 0, ticket_no: 1, category: 1 });
db.incident_activity.find({ "events.type": "attachment" }, { _id: 0, ticket_no: 1 });
db.incident_activity.find({ tags: { $in: ["vpn", "wifi"] } }).count();

// ---------------- 3. UPDATE ----------------
db.incident_activity.updateOne({ incident_id: 1 },
  { $push: { events: { type: "comment", by: "agent_aarav", text: "Issue resolved after gateway restart", ts: new Date() } },
    $addToSet: { tags: "resolved" } });
db.incident_activity.updateMany({ priority: "Low" }, { $set: { reviewed: true } });
db.incident_activity.findOne({ incident_id: 1 });

// ---------------- 4. DELETE ----------------
db.incident_activity.deleteOne({ incident_id: 4 });
db.incident_activity.countDocuments();     // 5

// ---------------- 5. INDEXES ----------------
db.incident_activity.createIndex({ incident_id: 1 }, { unique: true });
db.incident_activity.createIndex({ tags: 1 });                    // multikey index
db.incident_activity.createIndex({ priority: 1, category: 1 });   // compound
db.incident_activity.getIndexes();
db.incident_activity.find({ incident_id: 3 }).explain("executionStats").executionStats.totalDocsExamined;  // 1 (index used)

// ---------------- 6. AGGREGATION PIPELINES ----------------
// 6.1 events per type (flatten the array)
db.incident_activity.aggregate([
  { $unwind: "$events" },
  { $group: { _id: "$events.type", total: { $sum: 1 } } },
  { $sort: { total: -1 } }
]);

// 6.2 average number of events per priority
db.incident_activity.aggregate([
  { $project: { priority: 1, n_events: { $size: "$events" } } },
  { $group: { _id: "$priority", avg_events: { $avg: "$n_events" }, tickets: { $sum: 1 } } },
  { $sort: { avg_events: -1 } }
]);

// 6.3 most common tags
db.incident_activity.aggregate([
  { $unwind: "$tags" },
  { $group: { _id: "$tags", count: { $sum: 1 } } },
  { $sort: { count: -1 } }, { $limit: 5 }
]);

// 6.4 total attachment size per ticket
db.incident_activity.aggregate([
  { $unwind: "$events" },
  { $match: { "events.type": "attachment" } },
  { $group: { _id: "$ticket_no", total_kb: { $sum: "$events.size_kb" }, files: { $push: "$events.filename" } } }
]);

// 6.5 $lookup (join): suggest knowledge-base articles for each ticket by matching tags
db.incident_activity.aggregate([
  { $lookup: { from: "kb_articles", localField: "tags", foreignField: "tags", as: "suggested_kb" } },
  { $match: { "suggested_kb.0": { $exists: true } } },
  { $project: { _id: 0, ticket_no: 1, suggested: "$suggested_kb.title" } }
]);

// ---------------- 7. SQL vs NoSQL comparison (put in report) ----------------
// MySQL  : incident, SLA, assignment, escalation  -> ACID, FK, CHECK, triggers, complex joins/analytics
// MongoDB: activity feed, chat/remote-session logs, attachments metadata, KB docs -> schema-less, nested arrays,
//          fast append ($push), no joins needed for display, horizontal scaling (sharding) for big logs.
// Optional cloud: MongoDB Atlas free tier (M0) -> replace connection string; or MySQL on AWS RDS / Azure / Aiven.
