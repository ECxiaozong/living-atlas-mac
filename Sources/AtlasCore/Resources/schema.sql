-- Living Atlas reference migration v1. Authoring date: 2026-11-17.
-- Executable SQLite contract, not a deployed application database.
-- One database per workspace. UI / API identity = (workspace_id, object_id).
-- Requires SQLite foreign keys and JSON functions. Derived FTS is in search_index.sql.
-- UUID and RFC3339 calendar validity, state transitions, authorization, scope,
-- region cycles, asset filesystem durability and batch dependency closure are
-- validated by CommandService; this schema does not pretend to enforce them all.
PRAGMA foreign_keys = ON;
PRAGMA recursive_triggers = ON;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 5000;

BEGIN;

CREATE TABLE schema_meta (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
  application_id TEXT NOT NULL DEFAULT 'living-atlas',
  created_at TEXT NOT NULL
);
INSERT INTO schema_meta VALUES (1, 1, 'living-atlas', '2026-11-17T00:00:00.000Z');

CREATE TABLE workspace (
  id TEXT NOT NULL PRIMARY KEY,
  singleton INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (singleton = 1),
  title TEXT NOT NULL,
  origin_workspace_id TEXT,
  policy_revision INTEGER NOT NULL DEFAULT 1 CHECK (policy_revision >= 1),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE asset (
  sha256 TEXT NOT NULL PRIMARY KEY
    CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
  media_type TEXT NOT NULL,
  relative_path TEXT NOT NULL UNIQUE
    CHECK (relative_path <> '' AND substr(relative_path,1,1) <> '/'),
  status TEXT NOT NULL DEFAULT 'ready' CHECK (status IN ('ready','missing')),
  created_at TEXT NOT NULL
);

CREATE TABLE content_node (
  id TEXT NOT NULL PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN
    ('question','answer','note','excerpt','interpretation','case','idea','concept','summary')),
  title TEXT NOT NULL DEFAULT '',
  current_version_id TEXT,
  content_revision INTEGER NOT NULL DEFAULT 1 CHECK (content_revision >= 1),
  metadata_revision INTEGER NOT NULL DEFAULT 1 CHECK (metadata_revision >= 1),
  created_at TEXT NOT NULL,
  deleted_at TEXT,
  FOREIGN KEY (id,current_version_id) REFERENCES content_version(node_id,id)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE content_version (
  id TEXT NOT NULL PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES content_node(id) ON DELETE RESTRICT,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
  body_markdown TEXT NOT NULL,
  plain_text TEXT NOT NULL,
  body_sha256 TEXT NOT NULL CHECK (length(body_sha256)=64 AND body_sha256 NOT GLOB '*[^0-9a-f]*'),
  origin_kind TEXT NOT NULL CHECK (origin_kind IN ('user','ai','import')),
  completion TEXT NOT NULL DEFAULT 'complete' CHECK (completion IN ('complete','partial')),
  actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user','ai','cli','system','importer')),
  created_at TEXT NOT NULL,
  supersedes_version_id TEXT,
  UNIQUE (node_id,id),
  UNIQUE (node_id,ordinal),
  FOREIGN KEY (node_id,supersedes_version_id) REFERENCES content_version(node_id,id)
);

CREATE TABLE inquiry_turn (
  id TEXT NOT NULL PRIMARY KEY,
  question_node_id TEXT NOT NULL REFERENCES content_node(id),
  question_version_id TEXT NOT NULL,
  answer_node_id TEXT NOT NULL UNIQUE REFERENCES content_node(id),
  supersedes_turn_id TEXT REFERENCES inquiry_turn(id),
  created_at TEXT NOT NULL,
  CHECK (question_node_id <> answer_node_id),
  CHECK (supersedes_turn_id IS NULL OR supersedes_turn_id <> id),
  UNIQUE (id,answer_node_id),
  FOREIGN KEY (question_node_id,question_version_id) REFERENCES content_version(node_id,id)
);
CREATE TRIGGER inquiry_turn_kinds BEFORE INSERT ON inquiry_turn BEGIN
  SELECT CASE WHEN (SELECT kind FROM content_node WHERE id=NEW.question_node_id) <> 'question'
    THEN RAISE(ABORT,'turn question must be a question node') END;
  SELECT CASE WHEN (SELECT kind FROM content_node WHERE id=NEW.answer_node_id) <> 'answer'
    THEN RAISE(ABORT,'turn answer must be an answer node') END;
END;
CREATE TRIGGER content_node_turn_kind_update BEFORE UPDATE OF kind ON content_node BEGIN
  SELECT CASE WHEN NEW.kind <> 'question' AND EXISTS
    (SELECT 1 FROM inquiry_turn WHERE question_node_id=NEW.id)
    THEN RAISE(ABORT,'referenced turn question must remain a question node') END;
  SELECT CASE WHEN NEW.kind <> 'answer' AND EXISTS
    (SELECT 1 FROM inquiry_turn WHERE answer_node_id=NEW.id)
    THEN RAISE(ABORT,'referenced turn answer must remain an answer node') END;
END;

CREATE TABLE generation_run (
  id TEXT NOT NULL PRIMARY KEY,
  turn_id TEXT NOT NULL,
  answer_node_id TEXT NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  retry_of_run_id TEXT REFERENCES generation_run(id),
  status TEXT NOT NULL CHECK (status IN
    ('queued','preparing','streaming','completed','cancelled','failed','interrupted')),
  output_completeness TEXT NOT NULL DEFAULT 'none' CHECK (output_completeness IN ('none','partial','complete')),
  terminal_reason TEXT,
  stage TEXT NOT NULL DEFAULT 'created',
  provider_id TEXT,
  model_id TEXT,
  config_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(config_json)),
  material_manifest_json TEXT CHECK (material_manifest_json IS NULL OR json_valid(material_manifest_json)),
  answer_version_id TEXT,
  policy_revision_at_start INTEGER CHECK (policy_revision_at_start >= 1),
  started_at TEXT,
  ended_at TEXT,
  usage_json TEXT CHECK (usage_json IS NULL OR json_valid(usage_json)),
  error_code TEXT,
  FOREIGN KEY (turn_id,answer_node_id) REFERENCES inquiry_turn(id,answer_node_id),
  FOREIGN KEY (answer_node_id,answer_version_id) REFERENCES content_version(node_id,id),
  CHECK (status<>'completed' OR (output_completeness IN ('partial','complete') AND answer_version_id IS NOT NULL)),
  CHECK (output_completeness<>'none' OR answer_version_id IS NULL),
  CHECK (retry_of_run_id IS NULL OR retry_of_run_id<>id)
);

CREATE TABLE document (
  id TEXT NOT NULL PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('pdf','markdown','web_snapshot')),
  title TEXT NOT NULL DEFAULT '',
  source_only INTEGER NOT NULL DEFAULT 0 CHECK (source_only IN (0,1)),
  current_version_id TEXT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at TEXT NOT NULL,
  deleted_at TEXT,
  FOREIGN KEY (id,current_version_id) REFERENCES document_version(document_id,id)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE document_version (
  id TEXT NOT NULL PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES document(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
  original_asset_sha256 TEXT REFERENCES asset(sha256),
  markdown_text TEXT,
  plain_text TEXT,
  text_sha256 TEXT CHECK (text_sha256 IS NULL OR
    (length(text_sha256)=64 AND text_sha256 NOT GLOB '*[^0-9a-f]*')),
  renderer_version TEXT,
  source_metadata_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(source_metadata_json)),
  source_url TEXT,
  fetched_at TEXT,
  extraction_status TEXT NOT NULL DEFAULT 'not_applicable'
    CHECK (extraction_status IN ('not_applicable','complete','partial','link_only','failed')),
  created_at TEXT NOT NULL,
  UNIQUE (document_id,id),
  UNIQUE (document_id,ordinal),
  CHECK (original_asset_sha256 IS NOT NULL OR markdown_text IS NOT NULL OR
    (source_url IS NOT NULL AND extraction_status IN ('complete','partial','link_only','failed')))
);
CREATE TRIGGER web_snapshot_version_contract BEFORE INSERT ON document_version
WHEN (SELECT kind FROM document WHERE id=NEW.document_id)='web_snapshot' BEGIN
  SELECT CASE WHEN NEW.source_url IS NULL OR trim(NEW.source_url)='' OR NEW.extraction_status='not_applicable'
    THEN RAISE(ABORT,'web snapshot requires URL and extraction status') END;
  SELECT CASE WHEN NEW.extraction_status IN ('complete','partial') AND
    (NEW.fetched_at IS NULL OR
      (coalesce(length(trim(NEW.plain_text)),0)=0 AND NEW.original_asset_sha256 IS NULL))
    THEN RAISE(ABORT,'read web snapshot requires capture time and actual content') END;
  SELECT CASE WHEN NEW.extraction_status IN ('link_only','failed') AND
    (NEW.original_asset_sha256 IS NOT NULL OR NEW.markdown_text IS NOT NULL OR NEW.plain_text IS NOT NULL)
    THEN RAISE(ABORT,'unread web link must not claim captured body') END;
END;

CREATE TABLE document_block (
  id TEXT NOT NULL PRIMARY KEY,
  document_version_id TEXT NOT NULL REFERENCES document_version(id),
  lineage_block_id TEXT NOT NULL,
  block_kind TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  source_range_json TEXT NOT NULL CHECK (json_valid(source_range_json)),
  plain_text TEXT NOT NULL,
  text_sha256 TEXT NOT NULL CHECK (length(text_sha256)=64 AND text_sha256 NOT GLOB '*[^0-9a-f]*'),
  UNIQUE (document_version_id,ordinal),
  UNIQUE (document_version_id,id)
);

CREATE TABLE document_asset (
  document_version_id TEXT NOT NULL REFERENCES document_version(id),
  asset_sha256 TEXT NOT NULL REFERENCES asset(sha256),
  role TEXT NOT NULL,
  original_reference TEXT,
  PRIMARY KEY (document_version_id,asset_sha256,role)
);

CREATE TABLE import_archive (
  id TEXT NOT NULL PRIMARY KEY,
  raw_asset_sha256 TEXT REFERENCES asset(sha256),
  raw_text TEXT,
  provider_kind TEXT NOT NULL CHECK (provider_kind IN ('chatgpt','plain_text','other')),
  adapter_version TEXT NOT NULL,
  imported_at TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('parsed','partial','failed')),
  diagnostics_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(diagnostics_json)),
  deleted_at TEXT,
  CHECK ((raw_asset_sha256 IS NOT NULL) + (raw_text IS NOT NULL) = 1)
);

CREATE TABLE import_conversation (
  id TEXT NOT NULL PRIMARY KEY,
  source_namespace TEXT NOT NULL,
  external_conversation_id TEXT,
  title TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX import_conversation_source_unique
  ON import_conversation(source_namespace,external_conversation_id)
  WHERE external_conversation_id IS NOT NULL;

CREATE TABLE archive_conversation (
  archive_id TEXT NOT NULL REFERENCES import_archive(id),
  conversation_id TEXT NOT NULL REFERENCES import_conversation(id),
  raw_locator_json TEXT NOT NULL CHECK (json_valid(raw_locator_json)),
  PRIMARY KEY (archive_id,conversation_id)
);

CREATE TABLE import_message (
  id TEXT NOT NULL PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES import_conversation(id),
  external_message_id TEXT,
  source_order INTEGER NOT NULL CHECK (source_order >= 0),
  current_version_id TEXT,
  FOREIGN KEY (id,current_version_id) REFERENCES import_message_version(message_id,id)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX import_message_source_unique
  ON import_message(conversation_id,external_message_id) WHERE external_message_id IS NOT NULL;

CREATE TABLE import_message_version (
  id TEXT NOT NULL PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES import_message(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
  source_archive_id TEXT NOT NULL REFERENCES import_archive(id),
  raw_locator_json TEXT NOT NULL CHECK (json_valid(raw_locator_json)),
  role TEXT CHECK (role IS NULL OR role IN ('user','assistant','system','developer','tool','unknown')),
  original_timestamp TEXT,
  body_text TEXT NOT NULL,
  parts_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(parts_json)),
  source_parent_external_id TEXT,
  content_sha256 TEXT NOT NULL CHECK (length(content_sha256)=64 AND content_sha256 NOT GLOB '*[^0-9a-f]*'),
  created_at TEXT NOT NULL,
  UNIQUE (message_id,id),
  UNIQUE (message_id,ordinal)
);

-- Forward references to annotation_version and relation_version are intentional.
CREATE TABLE reference_snapshot (
  id TEXT NOT NULL PRIMARY KEY,
  source_kind TEXT NOT NULL CHECK (source_kind IN ('content','document','message','relation','annotation')),
  content_version_id TEXT REFERENCES content_version(id),
  document_version_id TEXT REFERENCES document_version(id),
  message_version_id TEXT REFERENCES import_message_version(id),
  relation_version_id TEXT REFERENCES relation_version(id),
  annotation_version_id TEXT REFERENCES annotation_version(id),
  quote_snapshot TEXT,
  source_state_at_capture TEXT NOT NULL DEFAULT 'available'
    CHECK (source_state_at_capture IN ('available','historical','unavailable','deleted')),
  created_at TEXT NOT NULL,
  CHECK ((content_version_id IS NOT NULL)+(document_version_id IS NOT NULL)+
    (message_version_id IS NOT NULL)+(relation_version_id IS NOT NULL)+(annotation_version_id IS NOT NULL)=1),
  CHECK ((source_kind='content' AND content_version_id IS NOT NULL) OR
    (source_kind='document' AND document_version_id IS NOT NULL) OR
    (source_kind='message' AND message_version_id IS NOT NULL) OR
    (source_kind='relation' AND relation_version_id IS NOT NULL) OR
    (source_kind='annotation' AND annotation_version_id IS NOT NULL))
);

CREATE TABLE source_anchor (
  id TEXT NOT NULL PRIMARY KEY,
  reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  segment_order INTEGER NOT NULL CHECK (segment_order >= 0),
  document_block_id TEXT REFERENCES document_block(id),
  page_index INTEGER CHECK (page_index >= 0),
  selector_type TEXT NOT NULL CHECK (selector_type IN ('text','pdf_rects','page','block','whole')),
  offset_unit TEXT CHECK (offset_unit IS NULL OR offset_unit='unicode_code_points'),
  start_offset INTEGER CHECK (start_offset >= 0),
  end_offset INTEGER,
  prefix TEXT,
  suffix TEXT,
  geometry_json TEXT CHECK (geometry_json IS NULL OR json_valid(geometry_json)),
  text_sha256 TEXT,
  UNIQUE (reference_id,segment_order),
  CHECK ((start_offset IS NULL AND end_offset IS NULL) OR
    (start_offset IS NOT NULL AND end_offset IS NOT NULL AND end_offset >= start_offset)),
  CHECK (start_offset IS NULL OR offset_unit IS NOT NULL)
);

-- Live resolution is derived/current state; immutable snapshots are never rewritten.
CREATE TABLE anchor_resolution (
  anchor_id TEXT NOT NULL PRIMARY KEY REFERENCES source_anchor(id),
  state TEXT NOT NULL CHECK (state IN ('exact','migrated','needs_reanchor','unavailable','historical')),
  current_document_version_id TEXT REFERENCES document_version(id),
  resolved_selector_json TEXT CHECK (resolved_selector_json IS NULL OR json_valid(resolved_selector_json)),
  checked_at TEXT NOT NULL
);

CREATE TABLE inquiry_reference (
  turn_id TEXT NOT NULL REFERENCES inquiry_turn(id),
  reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  role TEXT NOT NULL CHECK (role IN ('actual_trigger','explicit_reference','path_context')),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  PRIMARY KEY (turn_id,reference_id,role),
  UNIQUE (turn_id,role,ordinal)
);
CREATE TABLE node_origin (
  content_version_id TEXT NOT NULL REFERENCES content_version(id),
  reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  origin_role TEXT NOT NULL CHECK (origin_role IN ('verbatim','excerpt','synthesis','interpretation')),
  PRIMARY KEY (content_version_id,reference_id,origin_role)
);

CREATE TABLE annotation_surface (
  id TEXT NOT NULL PRIMARY KEY,
  document_version_id TEXT NOT NULL REFERENCES document_version(id),
  kind TEXT NOT NULL CHECK (kind IN ('pdf_page','markdown_snapshot')),
  page_index INTEGER CHECK (page_index >= 0),
  width REAL NOT NULL CHECK (width > 0 AND width < 1.0e9),
  height REAL NOT NULL CHECK (height > 0 AND height < 1.0e9),
  rotation_degrees INTEGER NOT NULL DEFAULT 0 CHECK (rotation_degrees IN (0,90,180,270)),
  coordinate_origin TEXT NOT NULL CHECK (coordinate_origin IN ('pdf_page','top_left')),
  snapshot_asset_sha256 TEXT REFERENCES asset(sha256),
  layout_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(layout_json)),
  created_at TEXT NOT NULL,
  CHECK ((kind='pdf_page' AND page_index IS NOT NULL AND coordinate_origin='pdf_page') OR
    (kind='markdown_snapshot' AND page_index IS NULL AND coordinate_origin='top_left' AND snapshot_asset_sha256 IS NOT NULL))
);

CREATE TABLE annotation (
  id TEXT NOT NULL PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES document(id),
  current_version_id TEXT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at TEXT NOT NULL,
  deleted_at TEXT,
  FOREIGN KEY (id,current_version_id) REFERENCES annotation_version(annotation_id,id)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE annotation_version (
  id TEXT NOT NULL PRIMARY KEY,
  annotation_id TEXT NOT NULL REFERENCES annotation(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 1),
  source_reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  surface_id TEXT REFERENCES annotation_surface(id),
  kind TEXT NOT NULL CHECK (kind IN ('highlight','underline','text','ink')),
  text TEXT,
  style_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(style_json)),
  created_at TEXT NOT NULL,
  UNIQUE (annotation_id,id),
  UNIQUE (annotation_id,ordinal),
  CHECK (kind <> 'ink' OR surface_id IS NOT NULL)
);

CREATE TABLE ink_stroke (
  id TEXT NOT NULL PRIMARY KEY,
  annotation_version_id TEXT NOT NULL REFERENCES annotation_version(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  tool TEXT NOT NULL CHECK (tool IN ('pen','highlighter')),
  color_token TEXT NOT NULL,
  base_width REAL NOT NULL CHECK (base_width > 0 AND base_width < 10000),
  points_json TEXT NOT NULL CHECK (json_valid(points_json) AND json_type(points_json)='array' AND json_array_length(points_json)>=1),
  created_at TEXT NOT NULL,
  UNIQUE (annotation_version_id,ordinal)
);
CREATE TRIGGER ink_stroke_kind BEFORE INSERT ON ink_stroke BEGIN
  SELECT CASE WHEN (SELECT kind FROM annotation_version WHERE id=NEW.annotation_version_id) <> 'ink'
    THEN RAISE(ABORT,'stroke requires an ink annotation version') END;
END;

CREATE TABLE topic (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE topic_membership (
  id TEXT NOT NULL PRIMARY KEY,
  topic_id TEXT NOT NULL REFERENCES topic(id),
  target_kind TEXT NOT NULL CHECK (target_kind IN ('turn','content','document')),
  turn_id TEXT REFERENCES inquiry_turn(id),
  content_id TEXT REFERENCES content_node(id),
  document_id TEXT REFERENCES document(id),
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  CHECK ((turn_id IS NOT NULL)+(content_id IS NOT NULL)+(document_id IS NOT NULL)=1),
  CHECK ((target_kind='turn' AND turn_id IS NOT NULL) OR
    (target_kind='content' AND content_id IS NOT NULL) OR
    (target_kind='document' AND document_id IS NOT NULL))
);
CREATE UNIQUE INDEX membership_turn_unique ON topic_membership(topic_id,turn_id) WHERE turn_id IS NOT NULL;
CREATE UNIQUE INDEX membership_content_unique ON topic_membership(topic_id,content_id) WHERE content_id IS NOT NULL;
CREATE UNIQUE INDEX membership_document_unique ON topic_membership(topic_id,document_id) WHERE document_id IS NOT NULL;

CREATE TABLE canvas_view (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  camera_x REAL NOT NULL DEFAULT 0 CHECK (abs(camera_x)<1.0e12),
  camera_y REAL NOT NULL DEFAULT 0 CHECK (abs(camera_y)<1.0e12),
  zoom REAL NOT NULL DEFAULT 1 CHECK (zoom>0 AND zoom<=100),
  ui_state_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(ui_state_json)),
  state_revision INTEGER NOT NULL DEFAULT 1 CHECK (state_revision>=1)
);

CREATE TABLE region (
  id TEXT NOT NULL PRIMARY KEY,
  view_id TEXT NOT NULL REFERENCES canvas_view(id),
  topic_id TEXT REFERENCES topic(id),
  parent_region_id TEXT,
  x REAL NOT NULL CHECK (abs(x)<1.0e12),
  y REAL NOT NULL CHECK (abs(y)<1.0e12),
  width REAL NOT NULL CHECK (width>0 AND width<1.0e12),
  height REAL NOT NULL CHECK (height>0 AND height<1.0e12),
  collapsed INTEGER NOT NULL DEFAULT 0 CHECK (collapsed IN (0,1)),
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision>=1),
  UNIQUE (view_id,id),
  CHECK (parent_region_id IS NULL OR parent_region_id<>id),
  FOREIGN KEY (view_id,parent_region_id) REFERENCES region(view_id,id)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE placement (
  id TEXT NOT NULL PRIMARY KEY,
  view_id TEXT NOT NULL REFERENCES canvas_view(id),
  target_kind TEXT NOT NULL CHECK (target_kind IN ('turn','content','document')),
  turn_id TEXT REFERENCES inquiry_turn(id),
  content_id TEXT REFERENCES content_node(id),
  document_id TEXT REFERENCES document(id),
  parent_region_id TEXT,
  x REAL NOT NULL CHECK (abs(x)<1.0e12),
  y REAL NOT NULL CHECK (abs(y)<1.0e12),
  width REAL NOT NULL CHECK (width>0 AND width<1.0e12),
  height REAL NOT NULL CHECK (height>0 AND height<1.0e12),
  display_mode TEXT NOT NULL CHECK (display_mode IN ('overview','reading')),
  reader_state_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(reader_state_json)),
  layout_revision INTEGER NOT NULL DEFAULT 1 CHECK (layout_revision>=1),
  CHECK ((turn_id IS NOT NULL)+(content_id IS NOT NULL)+(document_id IS NOT NULL)=1),
  CHECK ((target_kind='turn' AND turn_id IS NOT NULL) OR
    (target_kind='content' AND content_id IS NOT NULL) OR
    (target_kind='document' AND document_id IS NOT NULL)),
  FOREIGN KEY (view_id,parent_region_id) REFERENCES region(view_id,id)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX placement_view_rect ON placement(view_id,x,y);

CREATE TABLE semantic_relation (
  id TEXT NOT NULL PRIMARY KEY,
  current_version_id TEXT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision>=1),
  created_at TEXT NOT NULL,
  deleted_at TEXT,
  FOREIGN KEY (id,current_version_id) REFERENCES relation_version(relation_id,id)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE relation_version (
  id TEXT NOT NULL PRIMARY KEY,
  relation_id TEXT NOT NULL REFERENCES semantic_relation(id),
  ordinal INTEGER NOT NULL CHECK (ordinal>=1),
  from_reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  to_reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  relation_type TEXT NOT NULL CHECK (relation_type IN
    ('supports','critiques','depends_on','reinterprets','compares','analogous_to','related_to')),
  direction TEXT NOT NULL CHECK (direction IN ('directed','undirected')),
  epistemic_kind TEXT NOT NULL CHECK (epistemic_kind IN ('direct_source','synthesis','exploratory')),
  explanation TEXT NOT NULL,
  actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user','ai','cli','system','importer')),
  created_at TEXT NOT NULL,
  UNIQUE (relation_id,id),
  UNIQUE (relation_id,ordinal)
);

CREATE TABLE relation_evidence (
  relation_version_id TEXT NOT NULL REFERENCES relation_version(id),
  reference_id TEXT NOT NULL REFERENCES reference_snapshot(id),
  evidence_role TEXT NOT NULL CHECK (evidence_role IN ('source','context','counterpoint')),
  PRIMARY KEY (relation_version_id,reference_id,evidence_role)
);

CREATE TABLE change_batch (
  id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('draft','reviewable','applying','applied','cancelled','failed','stale','rolled_back')),
  actor_kind TEXT NOT NULL CHECK (actor_kind IN ('user','ai','cli','system','importer')),
  read_scope_json TEXT NOT NULL CHECK (json_valid(read_scope_json)),
  write_scope_json TEXT NOT NULL CHECK (json_valid(write_scope_json)),
  base_revisions_json TEXT NOT NULL CHECK (json_valid(base_revisions_json)),
  policy_revision_at_plan INTEGER NOT NULL CHECK (policy_revision_at_plan>=1),
  summary TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  applied_at TEXT,
  rollback_of_batch_id TEXT REFERENCES change_batch(id),
  CHECK (rollback_of_batch_id IS NULL OR rollback_of_batch_id<>id)
);

CREATE TABLE change_operation (
  id TEXT NOT NULL PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES change_batch(id),
  ordinal INTEGER NOT NULL CHECK (ordinal>=0),
  operation_type TEXT NOT NULL,
  target_kind TEXT NOT NULL,
  target_id TEXT NOT NULL,
  facet TEXT NOT NULL CHECK (facet IN ('content','metadata','layout','membership','relation','document','annotation','lifecycle')),
  expected_revision INTEGER NOT NULL CHECK (expected_revision>=0),
  before_json TEXT CHECK (before_json IS NULL OR json_valid(before_json)),
  after_json TEXT CHECK (after_json IS NULL OR json_valid(after_json)),
  dependencies_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(dependencies_json)),
  UNIQUE (batch_id,ordinal)
);

CREATE TABLE command_receipt (
  request_id TEXT NOT NULL PRIMARY KEY,
  command_type TEXT NOT NULL,
  payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256)=64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*'),
  result_json TEXT NOT NULL CHECK (json_valid(result_json)),
  committed_at TEXT NOT NULL
);

CREATE TABLE index_outbox (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_kind TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  version_id TEXT,
  operation TEXT NOT NULL CHECK (operation IN ('upsert','delete','rebuild')),
  created_at TEXT NOT NULL,
  processed_at TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count>=0),
  last_error_code TEXT
);
CREATE INDEX index_outbox_pending ON index_outbox(sequence) WHERE processed_at IS NULL;

CREATE TABLE draft (
  id TEXT NOT NULL PRIMARY KEY,
  owner_kind TEXT NOT NULL CHECK (owner_kind IN ('content','document','generation')),
  content_id TEXT REFERENCES content_node(id),
  document_id TEXT REFERENCES document(id),
  generation_run_id TEXT REFERENCES generation_run(id),
  base_content_version_id TEXT REFERENCES content_version(id),
  base_document_version_id TEXT REFERENCES document_version(id),
  edit_serial INTEGER NOT NULL CHECK (edit_serial>=0),
  body_text TEXT NOT NULL,
  saved_at TEXT NOT NULL,
  CHECK ((content_id IS NOT NULL)+(document_id IS NOT NULL)+(generation_run_id IS NOT NULL)=1),
  CHECK ((owner_kind='content' AND content_id IS NOT NULL AND base_document_version_id IS NULL) OR
    (owner_kind='document' AND document_id IS NOT NULL AND base_content_version_id IS NULL) OR
    (owner_kind='generation' AND generation_run_id IS NOT NULL AND base_document_version_id IS NULL)),
  FOREIGN KEY (content_id,base_content_version_id) REFERENCES content_version(node_id,id),
  FOREIGN KEY (document_id,base_document_version_id) REFERENCES document_version(document_id,id)
);
CREATE UNIQUE INDEX draft_content_unique ON draft(content_id) WHERE content_id IS NOT NULL;
CREATE UNIQUE INDEX draft_document_unique ON draft(document_id) WHERE document_id IS NOT NULL;
CREATE UNIQUE INDEX draft_generation_unique ON draft(generation_run_id) WHERE generation_run_id IS NOT NULL;

CREATE TABLE workspace_settings (
  key TEXT NOT NULL PRIMARY KEY,
  value_json TEXT NOT NULL CHECK (json_valid(value_json)),
  revision INTEGER NOT NULL CHECK (revision>=1),
  updated_at TEXT NOT NULL
);

-- Immutable historical facts: normal commands append new records.
-- Whole-Atlas permanent purge is a separate managed-directory lifecycle action;
-- per-object exhaustive erasure is not claimed by this migration.
CREATE TRIGGER content_version_no_update BEFORE UPDATE ON content_version BEGIN SELECT RAISE(ABORT,'immutable content_version'); END;
CREATE TRIGGER content_version_no_delete BEFORE DELETE ON content_version BEGIN SELECT RAISE(ABORT,'immutable content_version'); END;
CREATE TRIGGER document_version_no_update BEFORE UPDATE ON document_version BEGIN SELECT RAISE(ABORT,'immutable document_version'); END;
CREATE TRIGGER document_version_no_delete BEFORE DELETE ON document_version BEGIN SELECT RAISE(ABORT,'immutable document_version'); END;
CREATE TRIGGER import_message_version_no_update BEFORE UPDATE ON import_message_version BEGIN SELECT RAISE(ABORT,'immutable import_message_version'); END;
CREATE TRIGGER import_message_version_no_delete BEFORE DELETE ON import_message_version BEGIN SELECT RAISE(ABORT,'immutable import_message_version'); END;
CREATE TRIGGER reference_snapshot_no_update BEFORE UPDATE ON reference_snapshot BEGIN SELECT RAISE(ABORT,'immutable reference_snapshot'); END;
CREATE TRIGGER reference_snapshot_no_delete BEFORE DELETE ON reference_snapshot BEGIN SELECT RAISE(ABORT,'immutable reference_snapshot'); END;
CREATE TRIGGER source_anchor_no_update BEFORE UPDATE ON source_anchor BEGIN SELECT RAISE(ABORT,'immutable source_anchor'); END;
CREATE TRIGGER source_anchor_no_delete BEFORE DELETE ON source_anchor BEGIN SELECT RAISE(ABORT,'immutable source_anchor'); END;
CREATE TRIGGER inquiry_turn_no_update BEFORE UPDATE ON inquiry_turn BEGIN SELECT RAISE(ABORT,'immutable inquiry_turn'); END;
CREATE TRIGGER inquiry_turn_no_delete BEFORE DELETE ON inquiry_turn BEGIN SELECT RAISE(ABORT,'immutable inquiry_turn'); END;
CREATE TRIGGER inquiry_reference_no_update BEFORE UPDATE ON inquiry_reference BEGIN SELECT RAISE(ABORT,'immutable inquiry_reference'); END;
CREATE TRIGGER inquiry_reference_no_delete BEFORE DELETE ON inquiry_reference BEGIN SELECT RAISE(ABORT,'immutable inquiry_reference'); END;
CREATE TRIGGER annotation_surface_no_update BEFORE UPDATE ON annotation_surface BEGIN SELECT RAISE(ABORT,'immutable annotation_surface'); END;
CREATE TRIGGER annotation_surface_no_delete BEFORE DELETE ON annotation_surface BEGIN SELECT RAISE(ABORT,'immutable annotation_surface'); END;
CREATE TRIGGER annotation_version_no_update BEFORE UPDATE ON annotation_version BEGIN SELECT RAISE(ABORT,'immutable annotation_version'); END;
CREATE TRIGGER annotation_version_no_delete BEFORE DELETE ON annotation_version BEGIN SELECT RAISE(ABORT,'immutable annotation_version'); END;
CREATE TRIGGER ink_stroke_no_update BEFORE UPDATE ON ink_stroke BEGIN SELECT RAISE(ABORT,'immutable ink_stroke'); END;
CREATE TRIGGER ink_stroke_no_delete BEFORE DELETE ON ink_stroke BEGIN SELECT RAISE(ABORT,'immutable ink_stroke'); END;
CREATE TRIGGER relation_version_no_update BEFORE UPDATE ON relation_version BEGIN SELECT RAISE(ABORT,'immutable relation_version'); END;
CREATE TRIGGER relation_version_no_delete BEFORE DELETE ON relation_version BEGIN SELECT RAISE(ABORT,'immutable relation_version'); END;
CREATE TRIGGER command_receipt_no_update BEFORE UPDATE ON command_receipt BEGIN SELECT RAISE(ABORT,'immutable command_receipt'); END;
CREATE TRIGGER command_receipt_no_delete BEFORE DELETE ON command_receipt BEGIN SELECT RAISE(ABORT,'immutable command_receipt'); END;

COMMIT;
