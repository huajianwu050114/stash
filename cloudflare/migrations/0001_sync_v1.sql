CREATE TABLE remote_entities (
  entity_type TEXT NOT NULL CHECK (entity_type IN ('item', 'channel', 'attachment')),
  entity_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  last_mutation_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (entity_type, entity_id)
);

CREATE TABLE change_log (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  operation TEXT NOT NULL,
  mutation_id TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  created_at TEXT NOT NULL
);

CREATE TABLE applied_mutations (
  mutation_id TEXT PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  change_sequence INTEGER NOT NULL UNIQUE,
  applied_at TEXT NOT NULL,
  FOREIGN KEY (change_sequence) REFERENCES change_log(sequence)
);

CREATE INDEX change_log_sequence_idx ON change_log(sequence);
CREATE INDEX remote_entities_operation_idx
  ON remote_entities(entity_type, operation);
